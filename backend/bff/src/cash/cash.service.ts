import { Injectable, Logger } from '@nestjs/common';
import { badRequest, conflict, notFound } from '../common/errors/http-errors';
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
 * Une partie du registre.
 *
 * ── Pourquoi un couple typé, et pourquoi aux DEUX bouts ─────────────────────
 *
 * La chaîne compte deux maillons dès qu'une course porte un facilitateur : le
 * conducteur doit à son facilitateur, le facilitateur doit au commerçant
 * (`docs/specs_facilitateur.md` §7.1). Ne typer qu'un bout — l'autre restant
 * « le commerçant » — rendait le premier maillon **inexprimable** : une remise
 * conducteur → entreprise n'a aucun commerçant à nommer.
 *
 * Le calcul de dette, les remises et leur confirmation ne changent pas ; seule
 * l'identité des deux bouts devient variable.
 */
export type PartyType = 'driver' | 'fleet' | 'merchant';

export interface Party {
  type: PartyType;
  id: string;
}

export const driverParty = (id: string): Party => ({ type: 'driver', id });
export const fleetParty = (id: string): Party => ({ type: 'fleet', id });
export const merchantParty = (id: string): Party => ({ type: 'merchant', id });

const samePartyAs = (a: Party, b: Party) => a.type === b.type && a.id === b.id;

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
   * Ce qu'**une personne** peut détenir, toutes contreparties confondues.
   *
   * ── Pourquoi un second plafond, et pourquoi il n'est pas redondant ────────
   *
   * Le plafond ci-dessus borne **une relation**. Depuis que la
   * multi-appartenance existe (31/07/2026), un conducteur rattaché à trois
   * entreprises porte trois dettes distinctes — `driverCounterparty()` prend le
   * facilitateur de la course —, donc trois fois le plafond, dans la même poche.
   * Le garde-fou se contournait par le nombre d'adhésions.
   *
   * C'est le défaut déjà nommé dans `specs_flux_argent_quatre_acteurs.md` (« une
   * entreprise de dix conducteurs accumule dix fois le plafond »), pris par
   * l'autre bout.
   *
   * ⚠️ **Même valeur par défaut que le plafond par couple**, et c'est
   * intentionnel : un conducteur ne détient jamais plus que le plafond, quel que
   * soit le nombre d'entreprises pour lesquelles il roule. Un multi-rattaché
   * n'est ainsi ni avantagé ni pénalisé — il l'est seulement s'il détient
   * réellement plus. La variable existe séparément pour qu'on puisse desserrer
   * l'un sans l'autre au pilote.
   */
  private personDebtCeiling(): number {
    const configured = Number(this.configService.get('COD_DEBT_CEILING_PER_PERSON'));
    return Number.isFinite(configured) && configured > 0 ? configured : this.debtCeiling();
  }

  /**
   * Tout ce qu'une partie détient, toutes contreparties confondues.
   *
   * ⚠️ Les jambes **négatives ne compensent pas**. Si un commerçant doit 500 au
   * conducteur et que le conducteur doit 2000 à une entreprise, il a 2000 dans
   * la poche : les soustraire annoncerait 1500 et laisserait passer une course
   * de plus. Ce qu'on borne est ce qui est **détenu**, pas une position nette.
   */
  async totalHeldBy(actor: Party): Promise<number> {
    const parties = await this.counterpartiesOf(actor);
    const legs = await Promise.all(parties.map((p) => this.debtBetween(actor, p)));
    return legs.reduce((sum, leg) => sum + Math.max(0, leg), 0);
  }

  /**
   * Position nette entre **deux parties quelconques**.
   *
   * Trois couples existent réellement, et une seule formule les couvre :
   *
   *     conducteur → facilitateur   perçu − ce que le conducteur a gagné
   *     facilitateur → commerçant   perçu − la rémunération de la course
   *     conducteur → commerçant     idem, quand la course n'a pas de facilitateur
   *
   * Le troisième est le cas d'avant ce chantier, et il reste **bit pour bit**
   * celui d'avant : toutes les lignes existantes ont `facilitatorId` nul, donc
   * elles tombent dans ce couple-là et donnent le même nombre qu'hier. C'est ce
   * qui rend `scripts/test-parcours-argent.sh` probant.
   *
   * ⚠️ La **commission n'entre pas** dans la dette. Elle reste servie à part,
   * comme aujourd'hui. La fondre ici mélangerait « l'argent que je détiens pour
   * vous » et « ce que je vous dois » dans un seul nombre — la confusion exacte
   * que ce projet évite entre `price` et `cod_amount` — et changerait la valeur
   * lue par un contrôle qui n'a pas à bouger.
   */
  /**
   * Ordonne un couple dans le sens **canonique** de la chaîne.
   *
   * ── Le défaut que ceci répare ───────────────────────────────────────────
   *
   * La chaîne va toujours dans le même sens : `driver → fleet → merchant`.
   * `legScope()` ne connaît donc que ces trois couples-là, et rend `null` pour
   * `(merchant, driver)` — ce qui, faute d'orientation, faisait interroger
   * `balancesFor()` à l'envers **pour tout acteur qui n'est pas le conducteur**.
   *
   * Le commerçant lisait alors 0 au lieu de 1300 avant remise ; et une fois la
   * remise confirmée, il ne restait dans le calcul que les remises, avec le
   * signe inversé — donc **+1300 sur une dette pourtant éteinte**, à chaque
   * cycle. Pire, `declareRemittance` déduit le sens du versement de ce même
   * nombre : le commerçant pouvait déclarer un versement fantôme et
   * **ressusciter une dette soldée**.
   *
   * Un nombre plausible et faux — le seul mode de défaut qui compte ici.
   */
  private orient(a: Party, b: Party): { up: Party; down: Party; flipped: boolean } {
    const rank: Record<PartyType, number> = { driver: 0, fleet: 1, merchant: 2 };
    return rank[a.type] <= rank[b.type]
      ? { up: a, down: b, flipped: false }
      : { up: b, down: a, flipped: true };
  }

  async debtBetween(a: Party, b: Party): Promise<number> {
    if (samePartyAs(a, b)) return 0;

    // Orienté ici, et non chez les appelants : c'est la seule façon d'être sûr
    // qu'aucun ne l'oublie. La valeur rendue garde le sens demandé — positif
    // veut dire « `a` doit à `b` » quel que soit l'ordre des arguments.
    const { up, down, flipped } = this.orient(a, b);
    const [first, second] = [up, down];

    const [collected, earned, out, back] = await Promise.all([
      this.prisma.cashCollection.aggregate({
        where: this.collectionsBetween(first, second),
        _sum: { collectedAmount: true },
      }),
      this.prisma.driverEarning.aggregate({
        where: this.earningsBetween(first, second),
        _sum: { grossAmount: true },
      }),
      this.prisma.cashRemittance.aggregate({
        where: this.remittancesFromTo(first, second),
        _sum: { amount: true },
      }),
      this.prisma.cashRemittance.aggregate({
        where: this.remittancesFromTo(second, first),
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
    // Le signe suit l'ordre DEMANDÉ, pas l'ordre canonique.
    return (flipped ? -1 : 1) * (Math.round(total * 100) / 100);
  }

  /**
   * Lignes d'encaissement qui portent la dette de `a` envers `b`.
   *
   * ⚠️ La condition sur le DÉCLARANT est reprise telle quelle de la version
   * précédente, et elle compte à deux titres.
   *
   * **Le sens** : un encaissement déclaré par le TRANSPORTEUR n'a besoin de
   * personne — il s'attribue sa propre dette, et nul ne ment pour se rendre
   * débiteur. Déclaré par le COMMERÇANT, il engage quelqu'un d'autre ; le
   * compter sans confirmation permettrait d'inventer une créance.
   *
   * **La migration** : filtrer sur le seul `confirmedAt: { not: null }` ferait
   * disparaître toutes les dettes existantes, les lignes d'avant naissant avec
   * ce champ nul (journal §30.4).
   */
  private collectionsBetween(a: Party, b: Party): any {
    const declared: any = { OR: [{ declaredBy: 'driver' }, { confirmedAt: { not: null } }] };
    const scope = this.legScope(a, b);
    return scope ? { ...scope, ...declared } : { id: '__aucune__' };
  }

  private earningsBetween(a: Party, b: Party): any {
    const scope = this.legScope(a, b, true);
    return scope ?? { id: '__aucune__' };
  }

  /**
   * Traduit un couple de parties en filtre sur les colonnes du registre.
   *
   * Trois couples ont un sens ; tout autre rend `null`, et l'appelant produit
   * alors un filtre qui ne matche rien. **Refuser en silence est ici le bon
   * défaut** : une paire inattendue doit donner une dette nulle, jamais une
   * agrégation trop large sur des sommes d'argent.
   *
   * `forEarnings` distingue le seul point où les deux tables divergent : sur le
   * maillon conducteur → facilitateur, ce que le conducteur déduit est ce qu'il
   * a **lui-même gagné** (`earnerType = 'driver'`), pas la rémunération de la
   * course, qui revient à l'entreprise quand il y en a une.
   */
  private legScope(a: Party, b: Party, forEarnings = false): any | null {
    // Conducteur → facilitateur (chaîne interne).
    if (a.type === 'driver' && b.type === 'fleet') {
      return forEarnings
        ? { earnerType: 'driver', earnerId: a.id, facilitatorId: b.id }
        : { driverId: a.id, facilitatorId: b.id };
    }

    // Facilitateur → commerçant (chaîne contractuelle).
    if (a.type === 'fleet' && b.type === 'merchant') {
      return { facilitatorId: a.id, merchantId: b.id };
    }

    // Conducteur → commerçant : le cas SANS facilitateur, et donc celui de
    // toutes les lignes écrites avant ce chantier. `facilitatorId: null` est
    // essentiel — sans lui, une course confiée à une entreprise compterait
    // deux fois, chez l'entreprise et chez le conducteur.
    if (a.type === 'driver' && b.type === 'merchant') {
      return { driverId: a.id, merchantId: b.id, facilitatorId: null };
    }

    return null;
  }

  /**
   * Remises confirmées allant de `a` vers `b`.
   *
   * Deux formes coexistent, et il faut les compter toutes les deux : les lignes
   * **d'avant** ce chantier n'ont pas de couple typé, seulement `driverId`,
   * `merchantId` et `direction`. Les ignorer effacerait des remises déjà
   * confirmées, c'est-à-dire ferait réapparaître des dettes soldées.
   */
  private remittancesFromTo(a: Party, b: Party): any {
    const typed: any = {
      fromType: a.type,
      fromId: a.id,
      toType: b.type,
      toId: b.id,
      confirmedAt: { not: null },
    };

    let legacy: any = null;
    if (a.type === 'driver' && b.type === 'merchant') {
      legacy = { driverId: a.id, merchantId: b.id, direction: 'driver_to_merchant' };
    } else if (a.type === 'merchant' && b.type === 'driver') {
      legacy = { driverId: b.id, merchantId: a.id, direction: 'merchant_to_driver' };
    }

    if (!legacy) return typed;

    return {
      OR: [typed, { ...legacy, fromType: null, confirmedAt: { not: null } }],
    };
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
      // ⚠️ Filtré sur le BÉNÉFICIAIRE, pas sur `driverId`.
      //
      // Une ligne de course d'entreprise porte quand même le `driverId` de
      // celui qui a livré : filtrer dessus facturait au salarié la commission
      // due sur un chiffre d'affaires qu'il n'a jamais touché. La correction
      // avait été appliquée à la retenue et oubliée sur cet agrégat — c'est
      // exactement ce que le commentaire de `earnerType` promet d'éviter.
      //
      // La seconde branche couvre les lignes d'avant ce chantier : elles
      // naissent avec `earnerType` nul, et le conducteur en est bien le
      // bénéficiaire.
      where: {
        OR: [
          { earnerType: 'driver', earnerId: driverId },
          { earnerType: null, driverId },
        ],
      },
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
    /**
     * Facilitateur de la course, ou `null` quand elle n'en porte pas.
     *
     * `isPlatform` décide de la seule chose qui varie : ce que le conducteur
     * retient. Passer le compte entier plutôt que son seul identifiant évite
     * une seconde lecture ici, sur un chemin déjà appelé à chaque clôture.
     */
    facilitator?: { id: string; isPlatform: boolean } | null,
  ) {
    const gross = Math.round(grossAmount * 100) / 100;
    if (gross <= 0) return null;

    const existing = await this.prisma.driverEarning.findUnique({
      where: { fleetbaseOrderUuid },
    });
    if (existing) return existing;

    const rate = this.commissionRate();
    const commission = Math.round(gross * rate * 100) / 100;

    // ── Qui gagne cette course, et donc qui retient sur les espèces ──────────
    //
    // Sur une course du pool (facilitateur plateforme, ou pas de facilitateur
    // du tout), la rémunération revient au **conducteur** : c'est un montant
    // que nous connaissons, puisque le commerçant l'a saisi, et il la retient
    // sur ce qu'il détient.
    //
    // Sur une course confiée à une **entreprise réelle**, elle revient à
    // l'entreprise. Ce que le conducteur touche est un salaire interne que nous
    // ne verrons jamais : il retient donc **0** et remet l'intégralité.
    //
    // Sans cette distinction, le code tranchait tout seul et dans le mauvais
    // sens — un salarié aurait empoché le chiffre d'affaires de son employeur,
    // et Echango aurait facturé l'employeur au salarié
    // (`docs/specs_facilitateur.md` §7.2).
    // ⚠️ `=== false` et non `!isPlatform`.
    //
    // Avec `isPlatform: undefined`, `!undefined` vaut `true` : une course du
    // pool aurait été traitée comme une course d'entreprise, le conducteur
    // aurait remis 1950 au lieu de 1300, et sa rémunération aurait été créditée
    // au facilitateur — donc jamais déduite de son maillon. Le seul appelant
    // sélectionne bien le champ aujourd'hui, mais Prisma est un `any` ici :
    // rien ne le tiendra demain.
    const earner: Party =
      facilitator && facilitator.isPlatform === false
        ? fleetParty(facilitator.id)
        : driverParty(driverId);

    const retained =
      earner.type === 'driver'
        ? Math.round(Math.min(gross, Math.max(collectedAmount, 0)) * 100) / 100
        : 0;

    const earning = await this.prisma.driverEarning.create({
      data: {
        driverId,
        merchantId,
        facilitatorId: facilitator?.id ?? null,
        earnerType: earner.type,
        earnerId: earner.id,
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
    debtor: Party,
    creditor: Party,
    amount: number,
  ): Promise<{
    allowed: boolean;
    debt: number;
    ceiling: number;
    /** Lequel des deux plafonds a refusé — pour que le message le dise. */
    scope: 'couple' | 'person';
  }> {
    const debt = await this.debtBetween(debtor, creditor);
    const ceiling = this.debtCeiling();

    if (debt + amount > ceiling) {
      return { allowed: false, debt, ceiling, scope: 'couple' };
    }

    // ⚠️ Les deux plafonds sont vérifiés **ici**, et non chez les appelants.
    //
    // Il y en a deux — `acceptOrder` côté conducteur, `assignDriver` côté
    // entreprise — et une règle d'argent recopiée à deux endroits finit par
    // diverger. C'est ce que `specs_flux_argent_quatre_acteurs.md` §5 interdit
    // explicitement, et c'est le motif de `driverCounterparty()` juste au-dessus.
    const total = await this.totalHeldBy(debtor);
    const personCeiling = this.personDebtCeiling();

    if (total + amount > personCeiling) {
      return { allowed: false, debt: total, ceiling: personCeiling, scope: 'person' };
    }

    return { allowed: true, debt, ceiling, scope: 'couple' };
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
    /**
     * Facilitateur de la course, **figé ici et jamais recalculé**.
     *
     * Exception §3.3 d'`architecture_bff_fleetbase.md`, la même que
     * `expectedAmount` : si un admin change `facilitator_uuid` demain, la dette
     * d'aujourd'hui ne doit pas changer de débiteur.
     */
    facilitatorId?: string | null,
  ) {
    const collected = Math.round(input.collectedAmount * 100) / 100;

    if (collected < 0) {
      badRequest('cash.amount_negative', 'Le montant encaissé ne peut pas être négatif');
    }

    if (collected > expectedAmount) {
      // Un transporteur qui perçoit plus que dû n'est pas un cas à absorber en
      // silence : soit le montant annoncé était faux, soit la déclaration l'est.
      // Les deux appellent une correction humaine.
      badRequest(
        'cash.amount_exceeds_expected',
        `Montant supérieur à ce qui était annoncé (${expectedAmount} ${this.currency}). ` +
          'Contactez Echango si le montant à encaisser était incorrect.',
      );
    }

    const differs = collected !== expectedAmount;
    if (differs && !input.discrepancyReason) {
      badRequest(
        'cash.discrepancy_reason_required',
        'Un écart entre le montant annoncé et le montant perçu exige un motif',
      );
    }

    // ── Idempotence, et pourquoi elle est indispensable ────────────────────
    //
    // L'appelant écrit ce registre **avant** de clôturer la livraison chez
    // Fleetbase. Si cette clôture échoue — réseau, transition refusée, amont
    // indisponible — le transporteur réessaie, et repasse ici.
    //
    // Lever à ce moment-là bloquait définitivement la course : l'encaissement
    // était enregistré, la livraison restait ouverte, et **plus aucune tentative
    // ne pouvait aboutir**. C'est le mode d'échec propre à l'écriture dans deux
    // systèmes sans transaction commune : on ne peut pas les rendre atomiques,
    // on peut rendre la reprise sûre.
    //
    // Un encaissement déjà déclaré par le MÊME transporteur est donc une
    // reprise, et on la laisse passer. Par un autre, c'est une anomalie qu'il
    // faut refuser — deux personnes ne peuvent pas avoir encaissé la même
    // livraison.
    const existing = await this.prisma.cashCollection.findUnique({
      where: { fleetbaseOrderUuid },
    });

    if (existing) {
      if (existing.driverId !== driverId) {
        badRequest(
          'cash.collection_conflict',
          'Un autre transporteur a déjà déclaré l\'encaissement de cette livraison',
        );
      }

      this.logger.log(
        `Encaissement ${fleetbaseOrderUuid} déjà enregistré — reprise après échec de clôture`,
      );

      return {
        id: existing.id,
        expectedAmount: existing.expectedAmount,
        collectedAmount: existing.collectedAmount,
        currency: existing.currency,
        // La contrepartie relue sur la LIGNE, pas sur l'argument : une reprise
        // après échec de clôture doit rendre la dette telle qu'elle a été
        // figée, même si la course a changé de facilitateur entre-temps.
        debt: await this.debtBetween(
          driverParty(driverId),
          this.driverCounterparty(existing.facilitatorId, merchantId),
        ),
        replayed: true,
      };
    }

    const collection = await this.prisma.cashCollection.create({
      data: {
        driverId,
        merchantId,
        facilitatorId: facilitatorId ?? null,
        fleetbaseOrderUuid,
        expectedAmount,
        collectedAmount: collected,
        // Le motif n'est conservé que s'il y a un écart : le garder sur une
        // ligne conforme laisserait croire à un incident lors d'une relecture.
        discrepancyReason: differs ? input.discrepancyReason : null,
        notes: input.notes,
        currency: this.currency,
        // Déclaré par celui qui tient l'argent : confirmé d'office. Exiger que
        // le commerçant valide chaque encaissement ferait dépendre la dette de
        // son attention, alors que le fait est déjà établi par celui qu'il
        // engage.
        declaredBy: 'driver',
        confirmedAt: new Date(),
      },
    });

    const debt = await this.debtBetween(
      driverParty(driverId),
      this.driverCounterparty(facilitatorId, merchantId),
    );

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
      replayed: false,
    };
  }

  /**
   * À qui un conducteur doit les espèces d'une course.
   *
   * Son facilitateur quand la course en porte un, le commerçant sinon. Une
   * seule ligne, mais elle porte toute la décision du §2.1 — et la placer ici
   * évite qu'elle soit réécrite à chaque endroit qui touche à l'argent, ce que
   * `docs/specs_flux_argent_quatre_acteurs.md` §5 interdit explicitement.
   */
  driverCounterparty(facilitatorId: string | null | undefined, merchantId: string): Party {
    return facilitatorId ? fleetParty(facilitatorId) : merchantParty(merchantId);
  }

  /**
   * Contreparties avec lesquelles un compte a une histoire.
   *
   * L'union des trois tables, et non les seuls encaissements : un transporteur
   * qui a livré sans encaisser n'apparaîtrait nulle part, alors que c'est
   * précisément le cas où le commerçant lui doit quelque chose.
   */
  private async counterpartiesOf(actor: Party): Promise<Party[]> {
    const found = new Map<string, Party>();
    const add = (p: Party | null) => {
      if (p && !(p.type === actor.type && p.id === actor.id)) found.set(`${p.type}:${p.id}`, p);
    };

    if (actor.type === 'driver') {
      // Un conducteur fait face à son facilitateur quand la course en porte un,
      // au commerçant sinon. Les deux populations sont disjointes ligne à
      // ligne — c'est `facilitatorId` qui tranche — donc on lit les deux.
      const [collections, earnings, remittances] = await Promise.all([
        this.prisma.cashCollection.findMany({
          where: { driverId: actor.id },
          select: { merchantId: true, facilitatorId: true },
        }),
        this.prisma.driverEarning.findMany({
          where: { driverId: actor.id },
          select: { merchantId: true, facilitatorId: true },
        }),
        this.prisma.cashRemittance.findMany({
          where: { OR: [{ fromType: 'driver', fromId: actor.id }, { toType: 'driver', toId: actor.id }, { fromType: null, driverId: actor.id }] },
          select: { merchantId: true, fromType: true, fromId: true, toType: true, toId: true },
        }),
      ]);

      for (const row of [...collections, ...earnings] as any[]) {
        add(this.driverCounterparty(row.facilitatorId, row.merchantId));
      }
      for (const r of remittances as any[]) {
        if (r.fromType && r.fromId && !(r.fromType === 'driver' && r.fromId === actor.id)) {
          add({ type: r.fromType, id: r.fromId });
        }
        if (r.toType && r.toId && !(r.toType === 'driver' && r.toId === actor.id)) {
          add({ type: r.toType, id: r.toId });
        }
        if (!r.fromType && r.merchantId) add(merchantParty(r.merchantId));
      }

      return [...found.values()];
    }

    if (actor.type === 'merchant') {
      // Face au commerçant : le facilitateur quand la course en porte un, le
      // conducteur sinon. Même bascule, lue depuis l'autre bout.
      const [collections, earnings, remittances] = await Promise.all([
        this.prisma.cashCollection.findMany({
          where: { merchantId: actor.id },
          select: { driverId: true, facilitatorId: true },
        }),
        this.prisma.driverEarning.findMany({
          where: { merchantId: actor.id },
          select: { driverId: true, facilitatorId: true },
        }),
        this.prisma.cashRemittance.findMany({
          where: { OR: [{ fromType: 'merchant', fromId: actor.id }, { toType: 'merchant', toId: actor.id }, { fromType: null, merchantId: actor.id }] },
          select: { driverId: true, fromType: true, fromId: true, toType: true, toId: true },
        }),
      ]);

      for (const row of [...collections, ...earnings] as any[]) {
        add(row.facilitatorId ? fleetParty(row.facilitatorId) : driverParty(row.driverId));
      }
      for (const r of remittances as any[]) {
        if (r.fromType && r.fromId && !(r.fromType === 'merchant' && r.fromId === actor.id)) {
          add({ type: r.fromType, id: r.fromId });
        }
        if (r.toType && r.toId && !(r.toType === 'merchant' && r.toId === actor.id)) {
          add({ type: r.toType, id: r.toId });
        }
        if (!r.fromType && r.driverId) add(driverParty(r.driverId));
      }

      return [...found.values()];
    }

    // Facilitateur : ses conducteurs d'un côté, ses commerçants de l'autre.
    // ⚠️ `driverEarning` est lu ici AUSSI, comme dans les deux autres branches.
    //
    // Une course d'entreprise **sans encaissement** — prépayée — ne produit
    // qu'une ligne de rémunération. Sans cette lecture, le commerçant n'est
    // jamais listé comme contrepartie de l'entreprise, et les 650 qu'il lui
    // doit ne sont calculés nulle part : une créance réelle, invisible des deux
    // côtés.
    const [collections, earnings, remittances] = await Promise.all([
      this.prisma.cashCollection.findMany({
        where: { facilitatorId: actor.id },
        select: { driverId: true, merchantId: true },
      }),
      this.prisma.driverEarning.findMany({
        where: { facilitatorId: actor.id },
        select: { driverId: true, merchantId: true },
      }),
      this.prisma.cashRemittance.findMany({
        where: { OR: [{ fromType: 'fleet', fromId: actor.id }, { toType: 'fleet', toId: actor.id }] },
        select: { fromType: true, fromId: true, toType: true, toId: true },
      }),
    ]);

    for (const row of [...collections, ...earnings] as any[]) {
      add(driverParty(row.driverId));
      add(merchantParty(row.merchantId));
    }
    for (const r of remittances as any[]) {
      if (r.fromType && r.fromId) add({ type: r.fromType, id: r.fromId });
      if (r.toType && r.toId) add({ type: r.toType, id: r.toId });
    }

    return [...found.values()];
  }

  /**
   * Nom et téléphone d'une contrepartie, quelle que soit sa table.
   *
   * ── Pourquoi ce n'était pas un détail d'affichage ───────────────────────
   *
   * `merchantBalances` lisait `driverAccount` en dur. Une contrepartie de type
   * entreprise y donnait `driver_name: null` **sans la moindre erreur** : le
   * commerçant aurait lu « 1300 DZD dus » sans nom ni téléphone, donc sans
   * personne à appeler pour organiser la remise. Une panne silencieuse sur
   * l'écran qui sert précisément à réclamer de l'argent (défaut D15).
   */
  private async describeParties(parties: Party[]): Promise<Map<string, { name: string | null; phone: string | null }>> {
    const key = (p: Party) => `${p.type}:${p.id}`;
    const ids = (type: PartyType) => parties.filter((p) => p.type === type).map((p) => p.id);

    const [merchants, fleets, drivers] = await Promise.all([
      this.prisma.merchantAccount.findMany({
        where: { id: { in: ids('merchant') } },
        select: { id: true, businessName: true, phone: true, businessPhone: true },
      }),
      this.prisma.fleetAccount.findMany({
        where: { id: { in: ids('fleet') } },
        select: { id: true, businessName: true, phone: true, businessPhone: true },
      }),
      this.prisma.driverAccount.findMany({
        where: { id: { in: ids('driver') } },
        select: { id: true, firstName: true, lastName: true, phone: true },
      }),
    ]);

    const out = new Map<string, { name: string | null; phone: string | null }>();
    for (const m of merchants as any[]) {
      out.set(key(merchantParty(m.id)), { name: m.businessName ?? null, phone: m.businessPhone ?? m.phone ?? null });
    }
    for (const f of fleets as any[]) {
      out.set(key(fleetParty(f.id)), { name: f.businessName ?? null, phone: f.businessPhone ?? f.phone ?? null });
    }
    for (const d of drivers as any[]) {
      out.set(key(driverParty(d.id)), {
        name: [d.firstName, d.lastName].filter(Boolean).join(' ') || null,
        phone: d.phone ?? null,
      });
    }
    return out;
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
    return this.balancesFor(driverParty(driverId), { withCeiling: true });
  }

  /** Soldes du commerçant, un par contrepartie. Symétrique du précédent. */
  async merchantBalances(merchantId: string) {
    return this.balancesFor(merchantParty(merchantId));
  }

  /** Soldes d'un facilitateur : ses conducteurs d'un côté, ses commerçants de l'autre. */
  async fleetBalances(fleetId: string) {
    return this.balancesFor(fleetParty(fleetId), { withCeiling: true });
  }

  /**
   * Soldes d'un compte, un par contrepartie.
   *
   * ── Une seule fonction pour les trois personas ──────────────────────────
   *
   * Les trois versions précédentes ne différaient que par la table où elles
   * allaient chercher le nom de la contrepartie — et c'est précisément ce qui
   * faisait le défaut D15 : le commerçant lisait toujours `driverAccount`, donc
   * une contrepartie de type entreprise donnait `driver_name: null` **sans la
   * moindre erreur**. Un montant dû par personne, sans personne à appeler.
   *
   * Chaque solde passe par `debtBetween()` plutôt que par une agrégation
   * parallèle : deux façons de calculer la même dette finiraient par en donner
   * deux valeurs, et sur de l'argent la divergence n'est pas un détail
   * d'affichage.
   *
   * ── Le contrat des champs est conservé ──────────────────────────────────
   *
   * `merchant_id`/`merchant_name` côté conducteur, `driver_id`/`driver_name`
   * côté commerçant : ces noms sont lus par l'application et par le contrôle de
   * référence. Ils sont servis **en plus** de `counterparty_*`, jamais à la
   * place — et ils ne portent une valeur que lorsque la contrepartie est
   * effectivement du type que leur nom annonce. Mentir sur un identifiant
   * serait pire que ne rien dire.
   */
  private async balancesFor(actor: Party, opts: { withCeiling?: boolean } = {}) {
    const parties = await this.counterpartiesOf(actor);
    const described = await this.describeParties(parties);
    const ceiling = this.debtCeiling();

    const balances = await Promise.all(
      parties.map(async (party) => {
        // ⚠️ Interrogé dans le sens CANONIQUE, jamais dans celui de l'acteur.
        //
        // `debtBetween` fait suivre son signe à l'ordre demandé — API la moins
        // surprenante — mais le contrat des écrans veut l'inverse : les deux
        // parties doivent lire **le même nombre**, positif quand l'amont détient
        // l'argent de l'aval. C'est ce que fait `cash.dart` (`driverOwes =>
        // debt > 0`) et ce que vérifie le contrôle de référence des deux côtés.
        //
        // Demander `(actor, party)` rendait donc −1300 au commerçant là où il
        // doit lire +1300 : juste au signe près, et faux à l'écran.
        const { up, down } = this.orient(actor, party);
        const debt = await this.debtBetween(up, down);
        const info = described.get(`${party.type}:${party.id}`);

        return {
          counterparty_type: party.type,
          counterparty_id: party.id,
          counterparty_name: info?.name ?? null,
          counterparty_phone: info?.phone ?? null,
          // Champs historiques, servis seulement quand ils ne mentent pas.
          merchant_id: party.type === 'merchant' ? party.id : null,
          merchant_name: party.type === 'merchant' ? (info?.name ?? null) : null,
          merchant_phone: party.type === 'merchant' ? (info?.phone ?? null) : null,
          driver_id: party.type === 'driver' ? party.id : null,
          driver_name: party.type === 'driver' ? (info?.name ?? null) : null,
          driver_phone: party.type === 'driver' ? (info?.phone ?? null) : null,
          debt,
          blocked: opts.withCeiling ? debt >= ceiling : undefined,
        };
      }),
    );

    return {
      currency: this.currency,
      ...(opts.withCeiling ? { ceiling } : {}),
      ...(actor.type === 'driver'
        ? {
            /** Commission cumulée due à Echango. Son recouvrement n'est pas construit. */
            platform_commission: await this.platformCommissionOwed(actor.id),
          }
        : {}),
      // Les soldes nuls disparaissent, les négatifs restent : ils disent que la
      // contrepartie doit quelque chose, ce qui appelle une action tout autant
      // qu'une dette dans l'autre sens.
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
    declaredBy: PartyType,
    declarantSide: Party,
    counterparty: Party,
    amount: number,
  ) {
    const rounded = Math.round(amount * 100) / 100;
    if (rounded <= 0) {
      badRequest('cash.remittance_amount_must_be_positive', 'Le montant remis doit être positif');
    }

    // Les deux colonnes historiques restent renseignées quand elles ont un
    // sens, pour que les index et les écrans existants continuent de servir.
    const driverId =
      declarantSide.type === 'driver' ? declarantSide.id
        : counterparty.type === 'driver' ? counterparty.id
        : null;
    const merchantId =
      declarantSide.type === 'merchant' ? declarantSide.id
        : counterparty.type === 'merchant' ? counterparty.id
        : null;

    const debt = await this.debtBetween(declarantSide, counterparty);
    if (debt === 0) {
      badRequest('cash.no_debt', 'Aucune somme due entre ces deux comptes');
    }

    // Le SENS est déduit de qui doit, pas de qui déclare. Laisser le déclarant
    // le choisir permettrait d'enregistrer un versement dans le mauvais sens et
    // de doubler une dette au lieu de l'éteindre — une erreur de saisie qui
    // coûterait de l'argent réel.
    // ⚠️ `direction` conserve son vocabulaire d'origine **tant qu'il décrit la
    // réalité** — c'est ce que lisent les lignes déjà écrites et les écrans
    // existants. Sur un maillon qu'il ne sait pas nommer (conducteur →
    // entreprise), il prend la forme générale `<from>_to_<to>` : mieux vaut un
    // vocabulaire élargi qu'un champ qui ment sur la moitié des lignes.
    const from = debt > 0 ? declarantSide : counterparty;
    const to = debt > 0 ? counterparty : declarantSide;
    const direction = `${from.type}_to_${to.type}`;
    const outstanding = Math.abs(debt);

    if (rounded > outstanding) {
      badRequest(
        'cash.remittance_exceeds_debt',
        `Montant supérieur à la somme due (${outstanding} ${this.currency})`,
      );
    }

    // Le couple typé est écrit systématiquement ; `driverId`/`merchantId` ne
    // sont renseignés que là où ils ont un sens, et ne décident plus de rien.
    const remittance = await this.prisma.cashRemittance.create({
      data: {
        driverId,
        merchantId,
        fromType: from.type,
        fromId: from.id,
        toType: to.type,
        toId: to.id,
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
    // Seul un commerçant a un journal de notifications ; une remise qui ne le
    // concerne pas (conducteur → entreprise) n'a personne à prévenir ici, et
    // `merchantId` y est nul. La condition porte donc sur le DESTINATAIRE de
    // l'information, pas sur le déclarant seul.
    if (declaredBy === 'driver' && merchantId) {
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
      `Remise déclarée par ${declaredBy} : ${rounded} ${this.currency} ` +
        `(${from.type}:${from.id} → ${to.type}:${to.id})`,
    );

    return this.projectRemittance(remittance);
  }

  /**
   * Déclare une remise à partir d'un simple identifiant de contrepartie.
   *
   * ── Pourquoi le serveur résout le type, et non le client ────────────────────
   *
   * Les deux routes de remise reçoivent un identifiant nu — `merchantId` côté
   * transporteur, `driverId` côté commerçant. Ces noms sont **gelés** : le
   * contrôle de référence les envoie tels quels, et `docs/specs_facilitateur.md`
   * §14 interdit de les changer.
   *
   * Or la contrepartie d'un conducteur devient son facilitateur dès qu'une
   * course en porte un. Plutôt que d'ajouter un champ de type que le client
   * devrait deviner — et qu'un client menteur pourrait falsifier — le serveur
   * regarde à quelle table appartient l'identifiant. C'est lui qui sait, et il
   * n'a personne à croire.
   */
  async declareRemittanceTo(
    declarant: Party,
    counterpartyId: string,
    amount: number,
  ) {
    const counterparty = await this.resolveParty(counterpartyId);

    if (!counterparty) {
      notFound('cash.counterparty_not_found', 'Contrepartie introuvable');
    }

    return this.declareRemittance(declarant.type, declarant, counterparty, amount);
  }

  /**
   * À quelle table appartient cet identifiant ?
   *
   * Les trois sont des cuid distincts : aucune ambiguïté possible. Les trois
   * lectures partent ensemble plutôt qu'en cascade — le coût est le même et le
   * temps de réponse ne dépend pas du type trouvé.
   */
  async resolveParty(id: string): Promise<Party | null> {
    const [merchant, fleet, driver] = await Promise.all([
      this.prisma.merchantAccount.findUnique({ where: { id }, select: { id: true } }),
      this.prisma.fleetAccount.findUnique({ where: { id }, select: { id: true } }),
      this.prisma.driverAccount.findUnique({ where: { id }, select: { id: true } }),
    ]);

    if (merchant) return merchantParty(merchant.id);
    if (fleet) return fleetParty(fleet.id);
    if (driver) return driverParty(driver.id);
    return null;
  }

  /**
   * Confirme une remise. **Réservé à la partie qui ne l'a pas déclarée.**
   *
   * C'est toute la valeur du mécanisme : une remise confirmée par son propre
   * déclarant n'est pas une preuve mais une répétition, et elle éteindrait une
   * dette sur la seule parole de celui qui la doit.
   */
  async confirmRemittance(
    confirmedBy: PartyType,
    actorId: string,
    remittanceId: string,
  ) {
    const remittance = await this.loadRemittanceFor(confirmedBy, actorId, remittanceId);

    if (remittance.confirmedAt) {
      badRequest('cash.remittance_already_confirmed', 'Cette remise est déjà confirmée');
    }
    if (remittance.disputedAt) {
      badRequest('cash.remittance_disputed', 'Cette remise est contestée — contactez Echango');
    }
    if (remittance.declaredBy === confirmedBy) {
      this.audit.denied({
        actorType: confirmedBy === 'driver' ? 'transporteur' : confirmedBy,
        actorId,
        action: 'cash.remittance.confirm',
        resourceType: 'CashRemittance',
        resourceId: remittanceId,
        reason: 'Tentative de confirmer sa propre déclaration',
      });
      badRequest(
        'cash.remittance_must_be_confirmed_by_other_party',
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
    disputedBy: PartyType,
    actorId: string,
    remittanceId: string,
    reason?: string,
  ) {
    const remittance = await this.loadRemittanceFor(disputedBy, actorId, remittanceId);

    if (remittance.confirmedAt) {
      badRequest('cash.remittance_already_confirmed', 'Cette remise est déjà confirmée');
    }
    if (remittance.declaredBy === disputedBy) {
      badRequest('cash.remittance_self_dispute_forbidden', 'Vous ne pouvez pas contester votre propre déclaration');
    }

    const updated = await this.prisma.cashRemittance.update({
      where: { id: remittanceId },
      data: { disputedAt: new Date(), disputeReason: reason },
    });

    this.audit.succeeded({
      actorType: disputedBy === 'driver' ? 'transporteur' : disputedBy,
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
    persona: PartyType,
    actorId: string,
    remittanceId: string,
  ) {
    // ⚠️ Le filtre porte sur **la partie**, jamais sur `driverId` seul.
    //
    // C'est le défaut D13, et il retournait le registre contre lui-même : une
    // remise entreprise → commerçant porte `driverId` — le conducteur qui a
    // encaissé — donc l'ancien filtre la lui rendait. Il appelait `confirmer`,
    // `declaredBy ('fleet') !== confirmedBy ('driver')` passait, et **la dette
    // de son employeur s'éteignait sans que le commerçant ait rien vu**.
    //
    // Le repli sur les colonnes historiques ne vaut que pour les lignes qui
    // n'ont pas de couple typé, c'est-à-dire celles d'avant ce chantier.
    const legacy =
      persona === 'driver'
        ? { driverId: actorId }
        : persona === 'merchant'
          ? { merchantId: actorId }
          : null;

    const remittance = await this.prisma.cashRemittance.findFirst({
      where: {
        id: remittanceId,
        OR: [
          { fromType: persona, fromId: actorId },
          { toType: persona, toId: actorId },
          ...(legacy ? [{ fromType: null, ...legacy }] : []),
        ],
      },
    });

    if (!remittance) {
      this.audit.denied({
        actorType: persona === 'driver' ? 'transporteur' : persona,
        actorId,
        action: 'cash.remittance.access',
        resourceType: 'CashRemittance',
        resourceId: remittanceId,
        reason: 'Remise inexistante ou concernant deux autres comptes',
      });
      notFound('cash.remittance_not_found', 'Remise introuvable');
    }

    return remittance;
  }

  /** Remises d'un compte, en attente d'abord — ce sont elles qui appellent une action. */
  async listRemittances(persona: PartyType, actorId: string) {
    // Le filtre porte sur la PARTIE, pas sur une colonne historique : une
    // remise conducteur → entreprise n'a pas de `merchantId`, et une entreprise
    // n'apparaît dans aucune des deux colonnes d'origine.
    const legacy =
      persona === 'driver' ? { driverId: actorId }
      : persona === 'merchant' ? { merchantId: actorId }
      : null;

    const remittances = await this.prisma.cashRemittance.findMany({
      where: {
        OR: [
          { fromType: persona, fromId: actorId },
          { toType: persona, toId: actorId },
          ...(legacy ? [{ fromType: null, ...legacy }] : []),
        ],
      },
      orderBy: [{ confirmedAt: 'asc' }, { declaredAt: 'desc' }],
      take: 100,
    });

    return { data: remittances.map((r: any) => this.projectRemittance(r)) };
  }

  /** Encaissements d'un compte, du plus récent au plus ancien. */
  /**
   * Le détail des encaissements, livraison par livraison.
   *
   * ── Pourquoi la retenue y figure ────────────────────────────────────────────
   *
   * Le total dû ne se vérifie pas : c'est une somme de différences. Depuis que
   * le montant réclamé à la porte comprend la livraison, un commerçant qui lit
   * « 4 200 DZD détenues par Alice » ne peut plus reconstituer d'où ça vient —
   * il faudrait qu'il connaisse, pour chaque course, ce qui a été perçu **et**
   * ce qu'Alice a retenu.
   *
   * Or c'est exactement ce qu'il doit contrôler **avant de confirmer une
   * remise**, puisqu'une confirmation éteint une dette. Un solde qu'on ne peut
   * pas décomposer se confirme sur la seule parole de l'autre.
   *
   * `retainedFromCash` vient de `DriverEarning` : c'est ce que le transporteur
   * a réellement pu prélever, plafonné à ce qu'il a perçu — et non la
   * rémunération théorique, qui différerait sur une course payée en partie.
   */
  async listCollections(persona: PartyType, actorId: string) {
    const collections = await this.prisma.cashCollection.findMany({
      where:
        persona === 'driver' ? { driverId: actorId }
        : persona === 'merchant' ? { merchantId: actorId }
        : { facilitatorId: actorId },
      orderBy: { collectedAt: 'desc' },
      take: 100,
    });

    if (!collections.length) return { data: [] };

    // Une requête pour toute la page, jamais une par ligne.
    const earnings = await this.prisma.driverEarning.findMany({
      where: { fleetbaseOrderUuid: { in: collections.map((c: any) => c.fleetbaseOrderUuid) } },
      select: { fleetbaseOrderUuid: true, retainedFromCash: true, grossAmount: true },
    });
    const byOrder = new Map<string, any>(
      earnings.map((e: any) => [e.fleetbaseOrderUuid, e]),
    );

    return {
      data: collections.map((c: any) => {
        const earning = byOrder.get(c.fleetbaseOrderUuid);
        const retained = earning?.retainedFromCash ?? 0;

        return {
          id: c.id,
          order_uuid: c.fleetbaseOrderUuid,
          expected_amount: c.expectedAmount,
          collected_amount: c.collectedAmount,
          /** Ce que le transporteur a prélevé sur ces espèces. */
          retained_amount: retained,
          /**
           * Ce qui revient au commerçant sur cette course.
           *
           * Calculé sur le montant **perçu** et non sur celui qui était
           * attendu : sur un écart à la porte, promettre la somme demandée
           * annoncerait de l'argent qui ne viendra pas.
           */
          net_amount: c.collectedAmount - retained,
          discrepancy_reason: c.discrepancyReason,
          notes: c.notes,
          currency: c.currency,
          collected_at: c.collectedAt.toISOString(),
          // Une ligne déclarée par le commerçant et non encore confirmée ne
          // compte dans aucune dette. L'afficher comme les autres ferait lire
          // un montant acquis là où il n'y a qu'une affirmation.
          declared_by: c.declaredBy,
          confirmed_at: c.confirmedAt?.toISOString() ?? null,
          disputed_at: c.disputedAt?.toISOString() ?? null,
          dispute_reason: c.disputeReason,
        };
      }),
    };
  }

  /**
   * Le commerçant déclare l'encaissement d'une livraison que le registre ignore.
   *
   * ── Pourquoi ce geste existe ────────────────────────────────────────────────
   *
   * `CashCollection` n'a qu'un chemin d'écriture : la clôture par l'application
   * du transporteur. Une livraison close depuis la console Fleetbase n'y laisse
   * rien, et le commerçant se retrouve devant un trou qu'il est seul à voir.
   *
   * ── Pourquoi ça ne crée PAS de dette tout de suite ──────────────────────────
   *
   * Ici le déclarant engage **quelqu'un d'autre**. C'est l'inverse exact de la
   * déclaration du transporteur, qui s'attribue sa propre dette et n'a donc
   * besoin de personne. Sans confirmation, un commerçant pourrait inventer une
   * créance ; `debtBetween()` ne compte que le confirmé.
   *
   * Et la rémunération n'est **pas** écrite ici : l'écrire tout de suite ferait
   * une dette négative — l'encaissement ne compte pas encore, la rémunération
   * si — c'est-à-dire un commerçant qui devrait de l'argent pour avoir signalé
   * un oubli. Les deux écritures naissent ensemble, à la confirmation.
   */
  async declareCollectionByMerchant(
    merchantId: string,
    driverId: string,
    fleetbaseOrderUuid: string,
    expectedAmount: number,
    input: DeclareCollectionInput,
    /**
     * Facilitateur de la course, figé ici comme sur le chemin nominal.
     *
     * Sans lui, une course d'entreprise close en console puis régularisée par
     * le commerçant — c'est-à-dire **le cas exact pour lequel cette
     * fonctionnalité existe** — imputait la dette au conducteur et lui laissait
     * retenir une rémunération qui revient à son employeur.
     */
    facilitatorId?: string | null,
  ) {
    const collected = Math.round(input.collectedAmount * 100) / 100;

    if (collected < 0) {
      badRequest('cash.amount_negative', 'Le montant encaissé ne peut pas être négatif');
    }
    if (collected > expectedAmount) {
      badRequest(
        'cash.amount_exceeds_expected',
        `Montant supérieur à ce qui était annoncé (${expectedAmount} ${this.currency}).`,
      );
    }

    const differs = collected !== expectedAmount;
    if (differs && !input.discrepancyReason) {
      badRequest(
        'cash.discrepancy_reason_required',
        'Un écart entre le montant annoncé et le montant perçu exige un motif',
      );
    }

    const existing = await this.prisma.cashCollection.findUnique({
      where: { fleetbaseOrderUuid },
    });
    if (existing) {
      // Pas d'idempotence permissive ici, contrairement à `declareCollection` :
      // celle-ci existe parce que le transporteur peut réessayer après un échec
      // de clôture. Le commerçant, lui, ne réessaie rien — une seconde
      // déclaration signifie que la première a abouti et qu'il ne la voit pas,
      // ou qu'un transporteur a déclaré entre-temps. Les deux se disent.
      conflict(
        'cash.collection_already_declared',
        'Un encaissement est déjà enregistré pour cette livraison',
      );
    }

    const collection = await this.prisma.cashCollection.create({
      data: {
        driverId,
        merchantId,
        fleetbaseOrderUuid,
        expectedAmount,
        collectedAmount: collected,
        facilitatorId: facilitatorId ?? null,
        discrepancyReason: differs ? input.discrepancyReason : null,
        notes: input.notes,
        currency: this.currency,
        declaredBy: 'merchant',
        confirmedAt: null,
      },
    });

    this.logger.log(
      `Encaissement ${fleetbaseOrderUuid} déclaré par le commerçant ${merchantId} : `
        + `${collected}/${expectedAmount} ${this.currency} — en attente de confirmation du transporteur`,
    );

    return {
      id: collection.id,
      expectedAmount,
      collectedAmount: collected,
      currency: collection.currency,
      pending: true,
    };
  }

  /**
   * Le transporteur confirme un encaissement déclaré par le commerçant.
   *
   * C'est ici que naissent **les deux** écritures : l'encaissement devient
   * comptable, et la rémunération est enregistrée dans le même geste. Les
   * séparer laisserait, entre les deux, un état où la dette est fausse.
   */
  async confirmCollection(driverId: string, collectionId: string, grossAmount: number) {
    // Le facilitateur est relu sur la ligne, jamais redemandé à l'appelant :
    // il a été figé à la déclaration, et c'est lui qui décide de la retenue.
    const collection = await this.prisma.cashCollection.findFirst({
      where: { id: collectionId, driverId },
    });

    if (!collection) {
      notFound('cash.collection_not_found', 'Encaissement introuvable');
    }
    if (collection.declaredBy !== 'merchant') {
      badRequest(
        'cash.collection_not_confirmable',
        'Cet encaissement est le vôtre : il n\'y a rien à confirmer',
      );
    }
    if (collection.confirmedAt) {
      badRequest('cash.collection_already_confirmed', 'Cet encaissement est déjà confirmé');
    }
    if (collection.disputedAt) {
      badRequest('cash.collection_disputed', 'Cet encaissement est contesté — contactez Echango');
    }

    const updated = await this.prisma.cashCollection.update({
      where: { id: collectionId },
      data: { confirmedAt: new Date() },
    });

    // La rémunération, dans le même geste. `recordEarning` est idempotent sur
    // `fleetbaseOrderUuid`, donc une course qui en aurait déjà une — cas
    // improbable mais possible si la clôture applicative a fini par passer —
    // n'en crée pas une seconde.
    const facilitator = collection.facilitatorId
      ? await this.prisma.fleetAccount.findUnique({
          where: { id: collection.facilitatorId },
          select: { id: true, isPlatform: true },
        })
      : null;

    await this.recordEarning(
      driverId,
      collection.merchantId,
      collection.fleetbaseOrderUuid,
      grossAmount,
      updated.collectedAmount,
      facilitator,
    );

    const debt = await this.debtBetween(
      driverParty(driverId),
      this.driverCounterparty(collection.facilitatorId, collection.merchantId),
    );
    this.logger.log(
      `Encaissement ${collection.fleetbaseOrderUuid} confirmé par le transporteur — dette ${debt}`,
    );

    return { id: updated.id, confirmed: true, debt };
  }

  /** « Je n'ai pas encaissé cette livraison », ou « pas ce montant ». */
  async disputeCollection(driverId: string, collectionId: string, reason?: string) {
    const collection = await this.prisma.cashCollection.findFirst({
      where: { id: collectionId, driverId },
    });

    if (!collection) {
      notFound('cash.collection_not_found', 'Encaissement introuvable');
    }
    if (collection.declaredBy !== 'merchant') {
      badRequest(
        'cash.collection_not_confirmable',
        'Cet encaissement est le vôtre : contestez-le auprès d\'Echango',
      );
    }
    if (collection.confirmedAt) {
      badRequest('cash.collection_already_confirmed', 'Cet encaissement est déjà confirmé');
    }

    const updated = await this.prisma.cashCollection.update({
      where: { id: collectionId },
      data: { disputedAt: new Date(), disputeReason: reason ?? null },
    });

    // La ligne reste, contestée. L'effacer priverait le commerçant de toute
    // trace de ce qu'il a affirmé, et le désaccord disparaîtrait avec elle.
    this.logger.warn(
      `Encaissement ${collection.fleetbaseOrderUuid} CONTESTÉ par le transporteur `
        + `${driverId} : ${reason ?? 'sans motif'}`,
    );

    return { id: updated.id, disputed: true };
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
