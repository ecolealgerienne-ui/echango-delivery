import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../database/prisma.service';
import { AuditService } from '../common/audit/audit.service';
import { NotificationsService } from '../notifications/notifications.service';
import { COLLECTION_DISCREPANCY_REASONS } from './cash.constants';

// Réexporté pour les appelants historiques ; la déclaration vit dans
// `cash.constants.ts`, sans dépendance, pour que les DTO n'aient pas à
// importer ce service.
export { COLLECTION_DISCREPANCY_REASONS };


export interface DeclareCollectionInput {
  collectedAmount: number;
  discrepancyReason?: string;
  notes?: string;
}

/**
 * Registre de caisse du paiement à la livraison.
 *
 * ── Le modèle retenu, en une phrase ─────────────────────────────────────────
 *
 * Le transporteur encaisse et **conserve** les espèces ; l'application tient le
 * compte de ce qu'il doit à chaque commerçant ; la remise est physique, entre
 * eux, et se confirme des deux côtés. **Echango ne touche jamais l'argent.**
 * (Voie B de `docs/specs_paiement_livraison.md` §6.)
 *
 * Ce choix n'est pas une facilité : détenir des fonds pour compte de tiers
 * engage un statut réglementaire, et un réseau de transporteurs indépendants
 * sans dépôt n'a de toute façon aucun endroit où déposer. Ce que nous apportons
 * est un registre, pas un coffre.
 *
 * ── Aucun solde n'est stocké ────────────────────────────────────────────────
 *
 * La dette se calcule : somme des encaissements moins somme des remises
 * confirmées. Un compteur incrémenté à chaque écriture dérive au premier échec
 * partiel, et plus rien ne dit alors laquelle des deux valeurs est la bonne.
 * Recalculer coûte une agrégation ; se tromper coûte la confiance dans le
 * registre, qui est ici le seul produit.
 *
 * ── Ce que ce service ne décide pas ─────────────────────────────────────────
 *
 * Qui supporte la perte en cas d'écart ou de non-remise. C'est une règle métier
 * non tranchée (§9 du document), et l'encoder ici la trancherait par défaut.
 */
@Injectable()
export class CashService {
  private readonly logger = new Logger(CashService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly configService: ConfigService,
    private readonly audit: AuditService,
    private readonly notifications: NotificationsService,
  ) {}

  get currency(): string {
    return this.configService.get('CURRENCY') || 'DZD';
  }

  /**
   * Taux de commission d'Echango sur la rémunération d'une course.
   *
   * ── Ce qu'il prélève, et sur quoi ───────────────────────────────────────────
   *
   * Sur la **rémunération du transporteur**, jamais sur le montant encaissé :
   * ce dernier appartient au commerçant et ne fait que transiter. Prélever
   * dessus reviendrait à taxer la marchandise de quelqu'un d'autre.
   *
   * ⚠️ 20 % par défaut est un **ordre de grandeur** aligné sur le secteur
   * (Uber, Stuart, Yassir : 25-30 %), volontairement plus bas pour un réseau
   * qui démarre et doit attirer des transporteurs. Ce n'est pas un arbitrage.
   */
  private commissionRate(): number {
    const configured = Number(this.configService.get('COMMISSION_RATE'));
    return Number.isFinite(configured) && configured >= 0 && configured < 1
      ? configured
      : 0.2;
  }

  /**
   * Plafond de dette d'un transporteur envers un commerçant.
   *
   * ── Pourquoi ce plafond est le garde-fou principal ──────────────────────────
   *
   * Un transporteur intégré borne son risque par des agences et un dépôt
   * quotidien. Nous n'avons ni l'un ni l'autre : le seul instrument disponible
   * est de **cesser de proposer des courses encaissées à quelqu'un qui doit
   * déjà trop**. C'est le mécanisme de DoorDash, transposé — et c'est une
   * capacité purement logicielle qui remplace une contrainte physique.
   *
   * ⚠️ La valeur par défaut est un **repli, pas une décision** : 20 000 est un
   * ordre de grandeur, pas un arbitrage. À fixer au pilote, avec de vrais
   * paniers (`specs_paiement_livraison.md` §9.3).
   */
  private debtCeiling(): number {
    const configured = Number(this.configService.get('COD_DEBT_CEILING'));
    return Number.isFinite(configured) && configured > 0 ? configured : 20000;
  }

  /**
   * Position nette entre un transporteur et un commerçant.
   *
   * ── Pourquoi elle est signée ────────────────────────────────────────────────
   *
   * **Positive** : le transporteur détient des espèces du commerçant.
   * **Négative** : le commerçant lui doit une rémunération que l'encaissement
   * n'a pas couverte — course sans encaissement, ou client qui n'a payé qu'une
   * partie. Les deux situations sont normales, et une dette bornée à zéro
   * effacerait la seconde : le transporteur aurait travaillé sans que rien ne
   * l'enregistre.
   *
   *     position = encaissé − retenu sur l'encaissement
   *                − rémunérations non retenues
   *                − remises confirmées (transporteur → commerçant)
   *                + versements confirmés (commerçant → transporteur)
   *
   * Ce qui se simplifie, sur une course encaissée couvrant la rémunération, en
   * l'énoncé attendu : `dette = perçu − rémunération`. Et il vaut que les frais
   * de livraison soient inclus ou non dans le montant à encaisser — c'est ce
   * qui rend `codIncludesDelivery` purement informatif.
   *
   * Les remises **non confirmées ne comptent pas** : tant que la seconde partie
   * n'a rien confirmé, une remise est une affirmation, pas un fait.
   */
  async debtBetween(driverId: string, merchantId: string): Promise<number> {
    const [collected, earned, out, back] = await Promise.all([
      this.prisma.cashCollection.aggregate({
        where: { driverId, merchantId },
        _sum: { collectedAmount: true },
      }),
      this.prisma.driverEarning.aggregate({
        where: { driverId, merchantId },
        _sum: { grossAmount: true },
      }),
      this.prisma.cashRemittance.aggregate({
        where: {
          driverId,
          merchantId,
          direction: 'driver_to_merchant',
          confirmedAt: { not: null },
        },
        _sum: { amount: true },
      }),
      this.prisma.cashRemittance.aggregate({
        where: {
          driverId,
          merchantId,
          direction: 'merchant_to_driver',
          confirmedAt: { not: null },
        },
        _sum: { amount: true },
      }),
    ]);

    const total =
      Number(collected._sum.collectedAmount ?? 0) -
      Number(earned._sum.grossAmount ?? 0) -
      Number(out._sum.amount ?? 0) +
      Number(back._sum.amount ?? 0);

    // Arrondi au centime : les flottants accumulent un résidu sur des sommes
    // d'argent, et une dette affichée « 0.000000001 » n'est jamais soldée.
    return Math.round(total * 100) / 100;
  }

  /**
   * Commission cumulée qu'un transporteur doit à Echango.
   *
   * ⚠️ **Son recouvrement n'est pas construit**, et c'est assumé : facturer un
   * transporteur est un acte de gestion, pas une fonctionnalité de
   * l'application. Ce qui ne se rattrape pas, en revanche, c'est le calcul — le
   * taux changera, les prix aussi, et une commission recalculée plus tard sur
   * d'autres paramètres ne serait plus celle qui était due. On l'enregistre
   * donc dès le premier jour, comme les entrées de tarification.
   */
  async platformCommissionOwed(driverId: string): Promise<number> {
    const result = await this.prisma.driverEarning.aggregate({
      where: { driverId },
      _sum: { commissionAmount: true },
    });
    return Math.round(Number(result._sum.commissionAmount ?? 0) * 100) / 100;
  }

  /**
   * Enregistre la rémunération d'une course et la commission qui s'y applique.
   *
   * ── La retenue est plafonnée à ce qui a été perçu ───────────────────────────
   *
   * Le transporteur se paie sur les espèces qu'il tient, mais **on ne se paie
   * pas sur de l'argent qu'on n'a pas** : sur une course sans encaissement, ou
   * dont le client n'a payé que 300 sur 500, la retenue est bornée en
   * conséquence. Le reliquat reste dû par le commerçant — c'est ce que la
   * position négative exprime, et ce qu'un versement en sens inverse règle.
   */
  async recordEarning(
    driverId: string,
    merchantId: string,
    fleetbaseOrderUuid: string,
    grossAmount: number,
    collectedAmount: number,
  ) {
    const gross = Math.round(grossAmount * 100) / 100;
    if (gross <= 0) return null;

    const existing = await this.prisma.driverEarning.findUnique({
      where: { fleetbaseOrderUuid },
    });
    if (existing) return existing;

    const rate = this.commissionRate();
    const commission = Math.round(gross * rate * 100) / 100;
    const retained = Math.round(Math.min(gross, Math.max(collectedAmount, 0)) * 100) / 100;

    const earning = await this.prisma.driverEarning.create({
      data: {
        driverId,
        merchantId,
        fleetbaseOrderUuid,
        grossAmount: gross,
        commissionRate: rate,
        commissionAmount: commission,
        retainedFromCash: retained,
        currency: this.currency,
      },
    });

    this.logger.log(
      `Rémunération ${fleetbaseOrderUuid} : ${gross} ${this.currency} ` +
        `(commission ${commission}, retenu sur encaissement ${retained})`,
    );

    return earning;
  }

  /**
   * Ce transporteur peut-il encore prendre une course encaissée pour ce
   * commerçant ?
   *
   * Le montant de la course à venir est compté dans le calcul : autoriser une
   * course qui fera franchir le plafond vide le plafond de son sens.
   */
  async canTakeCashOrder(
    driverId: string,
    merchantId: string,
    amount: number,
  ): Promise<{ allowed: boolean; debt: number; ceiling: number }> {
    const debt = await this.debtBetween(driverId, merchantId);
    const ceiling = this.debtCeiling();
    return { allowed: debt + amount <= ceiling, debt, ceiling };
  }

  /**
   * Enregistre l'encaissement d'une livraison.
   *
   * ── Pourquoi c'est indissociable de la clôture ──────────────────────────────
   *
   * L'appelant est `completeOrder` : sur une commande encaissée, la livraison
   * ne peut pas être déclarée terminée sans dire ce qui a été perçu. En faire
   * une étape séparée et facultative garantirait qu'elle soit oubliée — et un
   * encaissement non déclaré est exactement ce que le registre existe pour
   * empêcher.
   *
   * `@unique` sur `fleetbaseOrderUuid` : une commande ne s'encaisse qu'une
   * fois. Un second appel est une erreur d'appelant, pas un cas métier.
   */
  async declareCollection(
    driverId: string,
    merchantId: string,
    fleetbaseOrderUuid: string,
    expectedAmount: number,
    input: DeclareCollectionInput,
  ) {
    const collected = Math.round(input.collectedAmount * 100) / 100;

    if (collected < 0) {
      throw new BadRequestException('Le montant encaissé ne peut pas être négatif');
    }

    if (collected > expectedAmount) {
      // Un transporteur qui perçoit plus que dû n'est pas un cas à absorber en
      // silence : soit le montant annoncé était faux, soit la déclaration l'est.
      // Les deux appellent une correction humaine.
      throw new BadRequestException(
        `Montant supérieur à ce qui était annoncé (${expectedAmount} ${this.currency}). ` +
          'Contactez Echango si le montant à encaisser était incorrect.',
      );
    }

    const differs = collected !== expectedAmount;
    if (differs && !input.discrepancyReason) {
      throw new BadRequestException(
        'Un écart entre le montant annoncé et le montant perçu exige un motif',
      );
    }

    const existing = await this.prisma.cashCollection.findUnique({
      where: { fleetbaseOrderUuid },
    });
    if (existing) {
      throw new BadRequestException('L\'encaissement de cette livraison a déjà été déclaré');
    }

    const collection = await this.prisma.cashCollection.create({
      data: {
        driverId,
        merchantId,
        fleetbaseOrderUuid,
        expectedAmount,
        collectedAmount: collected,
        // Le motif n'est conservé que s'il y a un écart : le garder sur une
        // ligne conforme laisserait croire à un incident lors d'une relecture.
        discrepancyReason: differs ? input.discrepancyReason : null,
        notes: input.notes,
        currency: this.currency,
      },
    });

    const debt = await this.debtBetween(driverId, merchantId);

    this.logger.log(
      `Encaissement ${fleetbaseOrderUuid} : ${collected}/${expectedAmount} ${this.currency}` +
        `${differs ? ` (écart : ${input.discrepancyReason})` : ''} — dette ${debt}`,
    );

    // Le commerçant est prévenu tout de suite. C'est son argent qui vient de
    // changer de mains, et l'écart est ce qu'il doit apprendre le plus vite —
    // pas au moment de la remise, quand la discussion sera plus difficile.
    await this.notifications.notifyOrderOwner(fleetbaseOrderUuid, {
      type: differs ? 'cash.discrepancy' : 'cash.collected',
      title: differs ? 'Encaissement partiel' : 'Paiement encaissé',
      body: differs
        ? `${collected} ${this.currency} perçus sur ${expectedAmount} attendus ` +
          `(${input.discrepancyReason?.replace(/_/g, ' ')}).`
        : `${collected} ${this.currency} encaissés par le transporteur.`,
    });

    return {
      id: collection.id,
      expectedAmount,
      collectedAmount: collected,
      currency: collection.currency,
      /** Dette totale du transporteur envers ce commerçant après l'opération. */
      debt,
    };
  }

  /**
   * Contreparties avec lesquelles un compte a une histoire.
   *
   * L'union des trois tables, et non les seuls encaissements : un transporteur
   * qui a livré sans encaisser n'apparaîtrait nulle part, alors que c'est
   * précisément le cas où le commerçant lui doit quelque chose.
   */
  private async counterparties(
    persona: 'driver' | 'merchant',
    actorId: string,
  ): Promise<string[]> {
    const field = persona === 'driver' ? 'merchantId' : 'driverId';
    const where = persona === 'driver' ? { driverId: actorId } : { merchantId: actorId };

    const [collections, earnings, remittances] = await Promise.all([
      this.prisma.cashCollection.groupBy({ by: [field as any], where }),
      this.prisma.driverEarning.groupBy({ by: [field as any], where }),
      this.prisma.cashRemittance.groupBy({ by: [field as any], where }),
    ]);

    const ids = new Set<string>();
    for (const row of [...collections, ...earnings, ...remittances]) {
      const value = (row as any)[field];
      if (value) ids.add(value);
    }
    return [...ids];
  }

  /**
   * Soldes du transporteur, un par commerçant.
   *
   * Chaque solde passe par `debtBetween()` plutôt que par une agrégation
   * parallèle : deux façons de calculer la même dette finiraient par en donner
   * deux valeurs, et sur de l'argent la divergence n'est pas un détail
   * d'affichage. Le coût est une requête par contrepartie — acceptable, et la
   * correction ne se négocie pas ici.
   *
   * La dette n'est pas une somme unique due à la plateforme mais une série de
   * dettes bilatérales, et c'est ainsi qu'elle se règle : un commerçant à la
   * fois, au prochain enlèvement.
   */
  async driverBalances(driverId: string) {
    const merchantIds = await this.counterparties('driver', driverId);
    const ceiling = this.debtCeiling();

    const merchants = await this.prisma.merchantAccount.findMany({
      where: { id: { in: merchantIds } },
      select: { id: true, businessName: true, phone: true, businessPhone: true },
    });
    const byId = new Map<string, any>(merchants.map((m: any) => [m.id, m]));

    const balances = await Promise.all(
      merchantIds.map(async (merchantId) => {
        const debt = await this.debtBetween(driverId, merchantId);
        const merchant = byId.get(merchantId);
        return {
          merchant_id: merchantId,
          merchant_name: merchant?.businessName ?? null,
          merchant_phone: merchant?.businessPhone ?? merchant?.phone ?? null,
          debt,
          blocked: debt >= ceiling,
        };
      }),
    );

    return {
      currency: this.currency,
      ceiling,
      /** Commission cumulée due à Echango. Son recouvrement n'est pas construit. */
      platform_commission: await this.platformCommissionOwed(driverId),
      // Les soldes nuls disparaissent, les négatifs restent : ils disent que le
      // commerçant doit quelque chose au transporteur, ce qui appelle une
      // action tout autant qu'une dette dans l'autre sens.
      balances: balances
        .filter((b) => b.debt !== 0)
        .sort((a, b) => b.debt - a.debt),
    };
  }

  /** Soldes du commerçant, un par transporteur. Symétrique du précédent. */
  async merchantBalances(merchantId: string) {
    const driverIds = await this.counterparties('merchant', merchantId);

    const drivers = await this.prisma.driverAccount.findMany({
      where: { id: { in: driverIds } },
      select: { id: true, firstName: true, lastName: true, phone: true },
    });
    const byId = new Map<string, any>(drivers.map((d: any) => [d.id, d]));

    const balances = await Promise.all(
      driverIds.map(async (driverId) => {
        const debt = await this.debtBetween(driverId, merchantId);
        const driver = byId.get(driverId);
        return {
          driver_id: driverId,
          driver_name:
            [driver?.firstName, driver?.lastName].filter(Boolean).join(' ') || null,
          driver_phone: driver?.phone ?? null,
          debt,
        };
      }),
    );

    return {
      currency: this.currency,
      balances: balances.filter((b) => b.debt !== 0).sort((a, b) => b.debt - a.debt),
    };
  }

  /**
   * Déclare une remise d'espèces.
   *
   * Déclarable par l'un ou l'autre : celui qui a son téléphone en main au
   * moment où l'argent change de mains n'est pas toujours le même. Le montant
   * est borné par la dette réelle — déclarer plus qu'on ne doit ne décrit aucun
   * geste possible, et créerait une dette négative que rien ne saurait lire.
   */
  async declareRemittance(
    declaredBy: 'driver' | 'merchant',
    driverId: string,
    merchantId: string,
    amount: number,
  ) {
    const rounded = Math.round(amount * 100) / 100;
    if (rounded <= 0) {
      throw new BadRequestException('Le montant remis doit être positif');
    }

    const debt = await this.debtBetween(driverId, merchantId);
    if (debt === 0) {
      throw new BadRequestException('Aucune somme due entre ces deux comptes');
    }

    // Le SENS est déduit de qui doit, pas de qui déclare. Laisser le déclarant
    // le choisir permettrait d'enregistrer un versement dans le mauvais sens et
    // de doubler une dette au lieu de l'éteindre — une erreur de saisie qui
    // coûterait de l'argent réel.
    const direction = debt > 0 ? 'driver_to_merchant' : 'merchant_to_driver';
    const outstanding = Math.abs(debt);

    if (rounded > outstanding) {
      throw new BadRequestException(
        `Montant supérieur à la somme due (${outstanding} ${this.currency})`,
      );
    }

    const remittance = await this.prisma.cashRemittance.create({
      data: {
        driverId,
        merchantId,
        amount: rounded,
        currency: this.currency,
        declaredBy,
        direction,
      },
    });

    // Le commerçant est prévenu quand c'est le transporteur qui déclare : sans
    // ça, la remise attendrait une confirmation que personne ne sait devoir
    // donner. Dans l'autre sens le transporteur n'a pas de journal de
    // notifications — la remise apparaît sur son écran de caisse.
    if (declaredBy === 'driver') {
      await this.notifications.notify({
        merchantId,
        type: 'cash.remittance_declared',
        title: direction === 'driver_to_merchant'
            ? 'Remise d\'espèces à confirmer'
            : 'Versement à confirmer',
        body: direction === 'driver_to_merchant'
            ? `Un transporteur déclare vous avoir remis ${rounded} ${this.currency}. ` +
              'Confirmez la réception pour solder le montant.'
            : `Un transporteur déclare avoir reçu ${rounded} ${this.currency} de votre part. ` +
              'Confirmez pour solder le montant.',
      });
    }

    this.logger.log(
      `Remise déclarée par ${declaredBy} : ${rounded} ${this.currency} (${driverId} → ${merchantId})`,
    );

    return this.projectRemittance(remittance);
  }

  /**
   * Confirme une remise. **Réservé à la partie qui ne l'a pas déclarée.**
   *
   * C'est toute la valeur du mécanisme : une remise confirmée par son propre
   * déclarant n'est pas une preuve mais une répétition, et elle éteindrait une
   * dette sur la seule parole de celui qui la doit.
   */
  async confirmRemittance(
    confirmedBy: 'driver' | 'merchant',
    actorId: string,
    remittanceId: string,
  ) {
    const remittance = await this.loadRemittanceFor(confirmedBy, actorId, remittanceId);

    if (remittance.confirmedAt) {
      throw new BadRequestException('Cette remise est déjà confirmée');
    }
    if (remittance.disputedAt) {
      throw new BadRequestException('Cette remise est contestée — contactez Echango');
    }
    if (remittance.declaredBy === confirmedBy) {
      this.audit.denied({
        actorType: confirmedBy === 'driver' ? 'transporteur' : 'merchant',
        actorId,
        action: 'cash.remittance.confirm',
        resourceType: 'CashRemittance',
        resourceId: remittanceId,
        reason: 'Tentative de confirmer sa propre déclaration',
      });
      throw new BadRequestException(
        'Une remise doit être confirmée par l\'autre partie',
      );
    }

    const updated = await this.prisma.cashRemittance.update({
      where: { id: remittanceId },
      data: { confirmedAt: new Date() },
    });

    this.logger.log(`Remise ${remittanceId} confirmée par ${confirmedBy}`);
    return this.projectRemittance(updated);
  }

  /**
   * Conteste une remise : « je n'ai jamais reçu cette somme ».
   *
   * Distinct d'une remise en attente. L'une appelle une vérification humaine,
   * l'autre seulement de la patience — et les confondre ferait passer un
   * désaccord réel pour un oubli.
   */
  async disputeRemittance(
    disputedBy: 'driver' | 'merchant',
    actorId: string,
    remittanceId: string,
    reason?: string,
  ) {
    const remittance = await this.loadRemittanceFor(disputedBy, actorId, remittanceId);

    if (remittance.confirmedAt) {
      throw new BadRequestException('Cette remise est déjà confirmée');
    }
    if (remittance.declaredBy === disputedBy) {
      throw new BadRequestException('Vous ne pouvez pas contester votre propre déclaration');
    }

    const updated = await this.prisma.cashRemittance.update({
      where: { id: remittanceId },
      data: { disputedAt: new Date(), disputeReason: reason },
    });

    this.audit.succeeded({
      actorType: disputedBy === 'driver' ? 'transporteur' : 'merchant',
      actorId,
      action: 'cash.remittance.dispute',
      resourceType: 'CashRemittance',
      resourceId: remittanceId,
      reason,
    });

    this.logger.warn(`Remise ${remittanceId} contestée par ${disputedBy} : ${reason ?? '—'}`);
    return this.projectRemittance(updated);
  }

  /**
   * Charge une remise en vérifiant qu'elle concerne bien l'appelant.
   *
   * Le filtre porte sur la colonne du persona, jamais sur le seul identifiant :
   * sans lui, n'importe qui confirmerait la remise d'autrui en changeant un
   * cuid — et confirmer, ici, efface une dette.
   */
  private async loadRemittanceFor(
    persona: 'driver' | 'merchant',
    actorId: string,
    remittanceId: string,
  ) {
    const remittance = await this.prisma.cashRemittance.findFirst({
      where: {
        id: remittanceId,
        ...(persona === 'driver' ? { driverId: actorId } : { merchantId: actorId }),
      },
    });

    if (!remittance) {
      this.audit.denied({
        actorType: persona === 'driver' ? 'transporteur' : 'merchant',
        actorId,
        action: 'cash.remittance.access',
        resourceType: 'CashRemittance',
        resourceId: remittanceId,
        reason: 'Remise inexistante ou concernant deux autres comptes',
      });
      throw new NotFoundException('Remise introuvable');
    }

    return remittance;
  }

  /** Remises d'un compte, en attente d'abord — ce sont elles qui appellent une action. */
  async listRemittances(persona: 'driver' | 'merchant', actorId: string) {
    const remittances = await this.prisma.cashRemittance.findMany({
      where: persona === 'driver' ? { driverId: actorId } : { merchantId: actorId },
      orderBy: [{ confirmedAt: 'asc' }, { declaredAt: 'desc' }],
      take: 100,
    });

    return { data: remittances.map((r: any) => this.projectRemittance(r)) };
  }

  /** Encaissements d'un compte, du plus récent au plus ancien. */
  async listCollections(persona: 'driver' | 'merchant', actorId: string) {
    const collections = await this.prisma.cashCollection.findMany({
      where: persona === 'driver' ? { driverId: actorId } : { merchantId: actorId },
      orderBy: { collectedAt: 'desc' },
      take: 100,
    });

    return {
      data: collections.map((c: any) => ({
        id: c.id,
        order_uuid: c.fleetbaseOrderUuid,
        expected_amount: c.expectedAmount,
        collected_amount: c.collectedAmount,
        discrepancy_reason: c.discrepancyReason,
        notes: c.notes,
        currency: c.currency,
        collected_at: c.collectedAt.toISOString(),
      })),
    };
  }

  private projectRemittance(r: any) {
    return {
      id: r.id,
      amount: r.amount,
      currency: r.currency,
      declared_by: r.declaredBy,
      direction: r.direction,
      declared_at: r.declaredAt.toISOString(),
      confirmed_at: r.confirmedAt?.toISOString() ?? null,
      disputed_at: r.disputedAt?.toISOString() ?? null,
      dispute_reason: r.disputeReason ?? null,
      driver_id: r.driverId,
      merchant_id: r.merchantId,
    };
  }
}
