import { Injectable, Logger, NotFoundException, ForbiddenException } from '@nestjs/common';
import { badRequest, notFound, forbidden, conflict } from '../common/errors/http-errors';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../database/prisma.service';
import { AuditService } from '../common/audit/audit.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { ListFleetOrdersQueryDto } from './dto/order.dto';
import { AddDriverDto } from './dto/driver.dto';
import {
  projectOrderForFleet,
  projectDriverForFleet,
} from '../common/projections/order.projection';
import { readDriverPosition, readPositionSeenAt } from '../common/geo/driver-position';
import { effectiveOrderMeta } from '../common/projections/order.projection';
import { CashService, driverParty, fleetParty, merchantParty } from '../cash/cash.service';
import { isOrderClaimable, isTerminalOrderStatus } from '../common/orders/order-status';
import {
  phoneContains,
  sameIdentifier,
  subscriberDigits,
} from '../common/identity/subscriber-number';

@Injectable()
export class FlotteService {
  private readonly logger = new Logger(FlotteService.name);

  constructor(
    private prisma: PrismaService,
    private fleetbaseClient: FleetbaseApiClient,
    private configService: ConfigService,
    private audit: AuditService,
    private cash: CashService,
  ) {}

  /**
   * List orders belonging to this fleet's Vendor.
   *
   * Le filtrage est demandé à Fleetbase depuis le 29/07/2026 (`?facilitator=`,
   * vérifié par appel réel — 2 commandes sur 29 renvoyées, 0 pour un uuid
   * inventé). L'ancienne version rapatriait toute la compagnie pour n'en garder
   * que celles-ci.
   *
   * ⚠️ **Le contrôle en mémoire qui suit est conservé, et doit l'être.** Il ne
   * fait pas doublon avec le filtre serveur : le filtre sert à ne pas
   * télécharger la compagnie, la vérification sert à décider qui a le droit de
   * voir. Un paramètre d'URL exprime une demande, pas une garantie — et comme
   * Fleetbase abandonne en silence un filtre qu'il ne reconnaît pas, une
   * régression de nom rendrait le filtre inopérant **sans aucun signal**. Ici,
   * elle produirait une liste vide plutôt qu'une fuite.
   */
  async getOrders(fleetId: string, query: ListFleetOrdersQueryDto) {
    const fleet = await this.getFleetWithValidation(fleetId);

    try {
      const allOrders = await this.fetchAllOrders(fleet.fleetbaseVendorUuid);

      let owned = allOrders.filter(
        (order: any) => order?.facilitator_uuid === fleet.fleetbaseVendorUuid,
      );

      if (query.status) {
        owned = owned.filter((order: any) => order?.status === query.status);
      }

      const page = query.page || 1;
      const limit = query.limit || 25;
      const total = owned.length;
      const paged = owned.slice((page - 1) * limit, (page - 1) * limit + limit);

      return {
        // Projection en liste d'autorisation : le BFF décide de ce qui sort,
        // et non Fleetbase (revue M10).
        data: paged.map((o: any) => projectOrderForFleet(this.withEffectiveMeta(o))),
        pagination: {
          page,
          limit,
          total,
          pages: Math.ceil(total / limit),
        },
      };
    } catch (error) {
      this.logger.error(`Failed to fetch fleet orders: ${error.message}`);
      badRequest('order.fetch_failed', 'Failed to fetch orders');
    }
  }


  /**
   * Les courses **libres**, que cette entreprise peut réclamer.
   *
   * Une course diffusée sans conducteur ni facilitateur. Deux populations les
   * voient — les transporteurs indépendants et les entreprises — et c'est ce
   * qui donne un rôle à une entreprise **sans obliger le commerçant à la
   * connaître** (`docs/specs_facilitateur.md` §6.2).
   *
   * Projection expurgée : tant que la course n'est engagée par personne, seuls
   * le nom et le téléphone du destinataire sont retirés, exactement comme côté
   * transporteur. L'adresse, les montants et les précisions d'accès restent —
   * ce sont eux qui permettent de décider.
   */
  async getClaimableOrders(fleetId: string, query: ListFleetOrdersQueryDto) {
    await this.getFleetWithValidation(fleetId);

    try {
      const free = await this.fleetbaseClient.fetchEveryOrder(100, 50, {
        without_driver: true,
      });

      const claimable = free.filter((o: any) => this.isClaimable(o));

      const page = query.page || 1;
      const limit = query.limit || 25;
      const total = claimable.length;
      const paged = claimable.slice((page - 1) * limit, (page - 1) * limit + limit);

      return {
        data: paged.map((o: any) =>
          projectOrderForFleet(this.withEffectiveMeta(o), {}, { unclaimed: true }),
        ),
        pagination: { page, limit, total, pages: Math.ceil(total / limit) },
      };
    } catch (error) {
      this.logger.error(`Failed to fetch claimable orders: ${error.message}`);
      badRequest('order.fetch_failed', 'Failed to fetch orders');
    }
  }

  /**
   * Cette course est-elle libre ?
   *
   * Délégué à `isOrderClaimable` : le prédicat était écrit ici ET côté
   * transporteur, avec de part et d'autre un commentaire affirmant que les deux
   * devaient rester identiques. Ils ne l'étaient plus.
   */
  private isClaimable(order: any): boolean {
    return isOrderClaimable(order);
  }

  /**
   * L'entreprise prend une course du pool.
   *
   * ── Il n'y a PAS de course critique à arbitrer, et c'est le piège ─────────
   *
   * On attendait une compétition entre un indépendant et une entreprise pour la
   * même course. Elle n'existe pas : **les deux n'écrivent pas la même
   * colonne**. L'indépendant pose `driver_assigned_uuid` par
   * `POST /v1/orders/{id}/start`, l'entreprise poserait `facilitator_uuid`. Les
   * deux écritures réussissent, personne ne perd, et la course finit **démarrée
   * par l'un et facilitée par l'autre** — l'indépendant part avec le colis, puis
   * l'entreprise affecte son conducteur, écrase `driver_assigned_uuid`, et celui
   * qui tient les espèces ne peut plus clôturer.
   *
   * Le prédicat exige donc **les deux colonnes libres**, dans les deux sens.
   *
   * ── Fleetbase n'offre aucune écriture conditionnelle ─────────────────────
   *
   * Pas de `If-Match`, pas de verrou optimiste : `$record->update($input)` est
   * un dernier-écrivain-gagne, et le perdant reçoit un `2xx`. La seule parade
   * compatible avec le comportement par défaut est un **compare-and-set
   * applicatif** : écrire, relire, et refuser si le facilitateur relu n'est pas
   * le nôtre.
   *
   * ⚠️ **C'est best-effort, et la fenêtre n'est pas fermée** (règle 2 : nommer
   * ce qu'on ne garantit pas). Deux entreprises qui écrivent à la même
   * milliseconde peuvent toutes deux relire la seconde valeur. La relecture peut
   * en outre être servie par le cache Redis de Fleetbase — à vérifier, contrôle
   * C3 de `docs/specs_facilitateur.md` §12.
   */
  async claimOrder(fleetId: string, orderId: string) {
    const fleet = await this.getFleetWithValidation(fleetId);

    let order: any;
    try {
      order = await this.readOrder(orderId);
    } catch (error: any) {
      this.logger.error(`Prise impossible, commande ${orderId} illisible : ${error.message}`);
      notFound('order.not_found', 'Order not found');
    }

    if (!order?.uuid) {
      notFound('order.not_found', 'Order not found');
    }

    // Refusé AVANT toute écriture, et hors de tout `try` qui réemballe.
    if (!this.isClaimable(order)) {
      conflict(
        'order.already_taken',
        'Cette course vient d\'être prise, ou n\'est plus disponible.',
      );
    }

    // Le plafond avant l'écriture : une entreprise qui doit déjà trop ne prend
    // pas une course encaissée de plus. Vérifié ici plutôt qu'après, pour ne pas
    // avoir à défaire un rattachement.
    await this.assertClaimCashCeiling(fleetId, this.withEffectiveMeta(order));

    try {
      await this.fleetbaseClient.attachFacilitator(order.uuid, fleet.fleetbaseVendorUuid);
    } catch (error: any) {
      this.logger.error(`Rattachement de ${orderId} échoué : ${error.message}`);
      badRequest('order.claim_failed', 'Impossible de prendre cette course pour le moment.');
    }

    // ── Compare-and-set : relire, et croire la relecture, pas notre écriture ──
    const after = await this.fleetbaseClient
      .getOrder(order.uuid)
      .then((r: any) => r?.order || r)
      .catch((): any => null);

    if (!after) {
      // On a écrit sans pouvoir vérifier. Le dire plutôt que d'affirmer un
      // succès : l'entreprise verra la course dans sa liste si elle l'a eue.
      this.logger.warn(
        `Prise de ${orderId} écrite mais non vérifiée — relecture impossible`,
      );
      return { claimed: true, verified: false };
    }

    if (after.facilitator_uuid !== fleet.fleetbaseVendorUuid) {
      this.audit.denied({
        actorType: 'fleet',
        actorId: fleetId,
        action: 'order.claim',
        resourceType: 'Order',
        resourceId: orderId,
        reason: `Course rattachée à ${after.facilitator_uuid ?? 'personne'} après écriture`,
      });
      conflict('order.already_taken', 'Cette course vient d\'être prise par quelqu\'un d\'autre.');
    }

    this.audit.succeeded({
      actorType: 'fleet',
      actorId: fleetId,
      action: 'order.claim',
      resourceType: 'Order',
      resourceId: orderId,
    });

    this.logger.log(`Course ${orderId} prise par la flotte ${fleetId}`);
    return projectOrderForFleet(this.withEffectiveMeta(after));
  }

  /**
   * Plafond de dette avant de prendre une course encaissée.
   *
   * La contrepartie est le commerçant, et le débiteur l'entreprise : c'est son
   * exposition à elle qu'on borne, tous conducteurs confondus.
   */
  /**
   * Le plafond de dette de l'ENTREPRISE, vérifié et refusé.
   *
   * ⚠️ **Ces dix-neuf lignes existaient en deux copies** (détecteur de corps
   * similaires, 01/08/2026, 100 %) — une sur la prise d'une course libre, une
   * sur l'affectation à un conducteur. Le critère de la règle 5 ne laisse
   * aucun doute : si le plafond change de portée, de message ou de code
   * d'erreur, les deux DOIVENT changer. Et ici une divergence ne se voit
   * pas — elle produit un refus qui annonce un montant faux, ou pire, un refus
   * d'un côté et un passage de l'autre pour la même course.
   *
   * Rend `false` quand il n'y a rien à vérifier (course sans encaissement,
   * commande absente du cache) : l'appelant sait alors qu'aucun montant n'est
   * en jeu. Les deux appelants en profitent pour s'arrêter là.
   */
  private async assertFleetCeiling(
    fleetId: string,
    order: any,
  ): Promise<{ codAmount: number; merchantId: string } | null> {
    const codAmount = Number(order?.meta?.cod_amount) || 0;
    if (codAmount <= 0) return null;

    const cached = await this.prisma.order.findFirst({
      where: { fleetbaseOrderId: order?.uuid },
      select: { merchantId: true },
    });
    if (!cached) return null;

    const { allowed, debt, ceiling, scope } = await this.cash.canTakeCashOrder(
      fleetParty(fleetId),
      merchantParty(cached.merchantId),
      codAmount,
    );

    if (!allowed) {
      // ⚠️ Le message suit le plafond qui a refusé. Dire « pour ce commerçant »
      // quand c'est le plafond global qui a mordu enverrait chercher une remise
      // auprès de quelqu'un qui n'est pour rien dans le blocage.
      badRequest(
        'cash.ceiling_exceeded',
        scope === 'person'
          ? `Votre entreprise détient déjà ${debt} ${this.cash.currency} au total, et cette ` +
              `course en ajouterait ${codAmount} — au-delà du plafond de ${ceiling}.`
          : `Votre entreprise détient déjà ${debt} ${this.cash.currency} pour ce commerçant, et ` +
              `cette course en ajouterait ${codAmount} — au-delà du plafond de ${ceiling}.`,
      );
    }

    return { codAmount, merchantId: cached.merchantId };
  }

  private async assertClaimCashCeiling(fleetId: string, order: any): Promise<void> {
    await this.assertFleetCeiling(fleetId, order);
  }

  /**
   * Le détail d'une course **libre**, avant de décider de la prendre.
   *
   * ── Pourquoi une route séparée de `getOrderDetail` ────────────────────────
   *
   * `getOrderDetail` exige `facilitator_uuid === le nôtre` : appelée sur une
   * opportunité, elle répond 403 — précisément sur les courses que l'entreprise
   * a le droit de consulter. Fusionner les deux en assouplissant la garde
   * reviendrait à rendre la vérification d'appartenance **conditionnelle**, et
   * une garde conditionnelle est une garde qu'on finit par contourner sans le
   * vouloir. Deux routes, deux règles explicites.
   *
   * La règle ici n'est pas l'appartenance mais la **disponibilité** : n'importe
   * quelle entreprise active peut lire n'importe quelle course que personne n'a
   * prise, puisque c'est exactement ce que la liste lui sert déjà. Dès qu'elle
   * ne l'est plus, la lecture s'arrête — sans quoi il suffirait de garder un
   * identifiant sous la main pour suivre une course prise par un concurrent.
   *
   * Projection expurgée, la même que la liste : l'identité du destinataire
   * n'apparaît qu'à l'engagement. Sans ça, ouvrir le détail rendrait ce que la
   * liste retire — c'est le trou exact trouvé côté transporteur le 28/07.
   */
  async getClaimableOrderDetail(fleetId: string, orderId: string) {
    await this.getFleetWithValidation(fleetId);

    let order: any;
    try {
      order = await this.readOrder(orderId);
    } catch (error: any) {
      this.logger.error(`Opportunité ${orderId} illisible : ${error.message}`);
      notFound('order.not_found', 'Order not found');
    }

    // ⚠️ L'identifiant relu est comparé à celui demandé — la garde que ce projet
    // impose à toute lecture unitaire depuis que `GET /vendors/{uuid}` a été
    // pris à ignorer son paramètre de chemin (journal §2.13). Ici elle compte
    // doublement : sans elle, un endpoint qui renverrait une liste ferait passer
    // son premier élément pour la course demandée, et la garde de disponibilité
    // s'appliquerait à la mauvaise course.
    //
    // Les deux identifiants sont acceptés parce que la résolution n'est pas
    // uniforme chez Fleetbase (`v1` par `public_id`, `int/v1` par `uuid`, avec
    // des exceptions) : n'en accepter qu'un ferait refuser une course légitime.
    // Ce qui est vérifié n'est pas la forme, c'est qu'on a bien reçu **celle
    // qu'on a demandée**.
    if (!order?.uuid || (order.uuid !== orderId && order.public_id !== orderId)) {
      notFound('order.not_found', 'Order not found');
    }

    if (!this.isClaimable(order)) {
      // La trace : une entreprise qui balaie des identifiants ne doit pas le
      // faire en silence (règle F14, les refus s'écrivent). `getOrderDetail` en
      // écrit une, cette route-ci n'en écrivait pas.
      this.audit.denied({
        actorType: 'fleet',
        actorId: fleetId,
        action: 'order.access',
        resourceType: 'Order',
        resourceId: orderId,
        reason: 'Course déjà prise ou non diffusée',
      });
      // Volontairement un `not_found` et non un `forbidden` : une course prise
      // par une autre entreprise ne regarde pas celle-ci, et distinguer les deux
      // réponses lui apprendrait qu'elle existe et qu'elle a été prise.
      notFound('order.not_found', 'Order not found');
    }

    return projectOrderForFleet(this.withEffectiveMeta(order), {}, { unclaimed: true });
  }

  /**
   * Get a single order, verifying it belongs to this fleet before returning
   * anything (anti-IDOR - never trust the id alone).
   */
  async getOrderDetail(fleetId: string, orderId: string) {
    const fleet = await this.getFleetWithValidation(fleetId);

    try {
      const order = await this.readOrder(orderId);

      if (!order || !order.uuid) {
        notFound('order.not_found', 'Order not found');
      }

      if (order.facilitator_uuid !== fleet.fleetbaseVendorUuid) {
        this.audit.denied({
          actorType: 'fleet',
          actorId: fleetId,
          action: 'order.access',
          resourceType: 'Order',
          resourceId: orderId,
          reason: 'Commande rattachée à une autre flotte',
        });
        forbidden('order.forbidden', 'You do not have access to this order');
      }

      return projectOrderForFleet(this.withEffectiveMeta(order));
    } catch (error) {
      if (error instanceof NotFoundException || error instanceof ForbiddenException) {
        throw error;
      }
      this.logger.error(`Failed to fetch order ${orderId}: ${error.message}`);
      notFound('order.not_found', 'Order not found');
    }
  }

  /**
   * List drivers belonging to this fleet's Vendor.
   *
   * Same server-side filtering bypass as orders: `vendor_uuid` on GET
   * /drivers is ignored, so we fetch all company drivers and filter
   * in memory (docs/journal_implementation_bff.md §2.8).
   */
  async getDrivers(fleetId: string) {
    const fleet = await this.getFleetWithValidation(fleetId);

    try {
      const drivers = await this.fleetDrivers(fleetId, fleet.fleetbaseVendorUuid);
      return { data: drivers.map((d: any) => projectDriverForFleet(d)) };
    } catch (error) {
      if (error instanceof NotFoundException || error instanceof ForbiddenException) throw error;
      this.logger.error(`Failed to fetch fleet drivers: ${error.message}`);
      badRequest('driver.fetch_failed', 'Failed to fetch drivers');
    }
  }

  /**
   * Tous les conducteurs de cette entreprise — les siens **et** ses adhérents.
   *
   * ── Pourquoi deux sources, et pourquoi il ne faut pas en oublier une ──────
   *
   * `?vendor=` chez Fleetbase ne rend que ceux dont l'entreprise est
   * **l'origine** (`Driver.vendor_uuid`, mono-valué). Depuis que la
   * multi-appartenance existe, s'en tenir là rendrait une liste **tronquée en
   * silence** : l'entreprise ne verrait pas les conducteurs qu'elle a rattachés,
   * et croirait à une liste complète. Ce projet a déjà payé deux fois cette
   * erreur-là — le plafond `limit=100` sur les commandes, la pagination absente
   * de `searchDrivers` — et à chaque fois le symptôme était le même : « il
   * existe, et l'application dit qu'il n'existe pas ».
   *
   * Les adhérents sont lus **un par un**. C'est assumé : une entreprise en a
   * quelques-uns, et `getDriverByUuid()` compare l'uuid rendu à celui demandé,
   * ce qu'un filtre de liste ne fait pas.
   */
  private async fleetDrivers(fleetId: string, vendorUuid: string): Promise<any[]> {
    const origin = await this.fetchOwnedDrivers(vendorUuid);
    const memberUuids = await this.activeMemberUuids(fleetId);

    // L'origine gagne : un conducteur ne doit apparaître qu'une fois même si une
    // adhésion a été créée avant que `vendor_uuid` ne le désigne.
    const seen = new Set(origin.map((d: any) => d?.uuid));
    const fetched = await Promise.all(
      memberUuids
        .filter((uuid) => !seen.has(uuid))
        .map((uuid) =>
          this.fleetbaseClient.getDriverByUuid(uuid).catch((error: any): any => {
            // Un conducteur illisible ne fait pas disparaître les autres — mais
            // il est signalé, parce qu'une adhésion active pointant vers un
            // conducteur introuvable est un état qu'il faut réparer.
            this.logger.warn(`Adhérent ${uuid} illisible : ${error.message}`);
            return null;
          }),
        ),
    );

    return [...origin, ...fetched.filter((d: any) => d?.uuid)];
  }

  /**
   * Ce conducteur a-t-il déjà une course en cours, **où que ce soit** ?
   *
   * ── Pourquoi la règle est « une à la fois » et non « une par entreprise » ─
   *
   * Les espèces ne savent pas de quelle entreprise elles viennent. Un conducteur
   * qui porte simultanément l'encaissement d'un commerçant pour la société A et
   * celui d'un autre pour la société B a **une seule poche**, et l'ordre dans
   * lequel il remet devient indéterminé — chaque entreprise réclame le sien sans
   * moyen de savoir ce qui a déjà été rendu. La multi-appartenance rend ce cas
   * courant alors qu'il était impossible avant.
   *
   * Le contrôle porte donc sur **toutes** les courses du conducteur, y compris
   * celles d'une autre entreprise, dont celle-ci ne saura rien de plus que
   * « occupé ». Le dire autrement — nommer le commerçant ou la société — ferait
   * de ce refus une fuite d'information commerciale.
   *
   * ⚠️ **Best-effort, et il faut le dire** (règle 2). Deux affectations
   * simultanées par deux entreprises passeront toutes les deux : Fleetbase
   * n'offre aucune écriture conditionnelle, et le contrôle est une lecture. Il
   * ferme le cas ordinaire, pas la course critique.
   */
  private async driverIsBusy(driverUuid: string, exceptOrderUuid?: string): Promise<boolean> {
    try {
      const orders = await this.fleetbaseClient.fetchEveryOrder(100, 50, {
        driver: driverUuid,
      });

      // La vérification en mémoire est conservée malgré le filtre `?driver=` :
      // Fleetbase abandonne en silence un paramètre qu'il ne reconnaît pas, et
      // une régression de nom rendrait ici **tout le monde occupé** plutôt que
      // personne — le bon côté de l'erreur, mais seulement si on relit.
      const candidates = orders.filter((o: any) => {
        // ⚠️ La course qu'on est en train d'affecter ne compte pas contre
        // elle-même. Sans ça, un rejeu après coupure réseau — l'écriture ayant
        // en fait abouti — recevait « ce conducteur a déjà une course en
        // cours », en parlant de celle qu'on lui assigne.
        if (exceptOrderUuid && o?.uuid === exceptOrderUuid) return false;
        const assigned =
          o?.driver_assigned_uuid === driverUuid || o?.driver_assigned?.uuid === driverUuid;
        return assigned && !isTerminalOrderStatus(o?.status);
      });

      if (candidates.length === 0) return false;

      // ⚠️ **Une course dont l'échec a été signalé ne rend PAS occupé.**
      //
      // Fleetbase n'a pas de statut « échec » confirmé (§6.5), donc
      // `reportDeliveryFailure` ne touche pas au statut : la course reste
      // `driver_enroute` et **assignée**, pour toujours. Sans cette exception, un
      // client absent immobilisait le conducteur définitivement, pour toutes les
      // entreprises, sans message ni issue applicative — le déblocage aurait
      // demandé un passage d'opérateur en console.
      //
      // C'est le prix du statut manquant en amont : le fait vit chez nous, donc
      // c'est chez nous qu'il faut le lire.
      const failed = await this.prisma.deliveryFailure.findMany({
        where: { fleetbaseOrderUuid: { in: candidates.map((o: any) => o.uuid) } },
        select: { fleetbaseOrderUuid: true },
      });
      const reported = new Set(failed.map((f: any) => f.fleetbaseOrderUuid));

      return candidates.some((o: any) => !reported.has(o.uuid));
    } catch (error: any) {
      // ⚠️ Injoignable ⇒ on **laisse passer**.
      //
      // Refuser transformerait une panne de lecture en impossibilité d'affecter,
      // alors que le pire cas toléré est deux courses simultanées — visible,
      // réparable, et sans perte d'argent. Bloquer toute la flotte sur une
      // lecture ratée serait le mauvais côté de l'erreur.
      this.logger.warn(`Occupation non vérifiée pour ${driverUuid} : ${error.message}`);
      return false;
    }
  }

  /**
   * Cette entreprise peut-elle confier une course à ce conducteur ?
   *
   * Origine **ou** adhésion active. Le rattachement `pending` ne compte pas :
   * c'est tout l'objet de l'acceptation, sans quoi une entreprise imposerait des
   * courses — et la dette d'espèces qui va avec — à quelqu'un qui n'a rien
   * accepté.
   */
  private async fleetMayUseDriver(
    fleetId: string,
    vendorUuid: string,
    driverUuid: string,
  ): Promise<boolean> {
    const origin = await this.fetchOwnedDrivers(vendorUuid);
    if (origin.some((d: any) => d?.uuid === driverUuid)) return true;

    const membership = await this.prisma.driverMembership.findUnique({
      where: {
        fleetbaseDriverUuid_fleetId: { fleetbaseDriverUuid: driverUuid, fleetId },
      },
    });

    return membership?.status === 'active';
  }

  /**
   * Cette personne est-elle déjà dans le réseau ?
   *
   * On cherche par **email et par téléphone**, séparément : ce sont les deux
   * identifiants qu'un humain reconnaît, et une personne réinscrite le sera
   * souvent avec l'un mais pas l'autre. Le nom ne sert pas — deux personnes
   * peuvent le partager, et refuser une inscription sur un homonyme serait pire
   * que le doublon qu'on évite.
   */
  private async assertNotAlreadyInNetwork(dto: AddDriverDto): Promise<void> {
    const needles = [dto.email, dto.phone].filter(
      (v): v is string => typeof v === 'string' && v.trim().length > 0,
    );

    // ⚠️ **Sans identifiant, pas de création.**
    //
    // `email` et `phone` sont tous deux facultatifs dans le DTO : un
    // `{ name: 'Ali Benali' }` seul produisait `needles = []`, la boucle ne
    // s'exécutait pas, et **la garde ne faisait rien**. Le contournement était
    // le chemin par défaut, pas une astuce.
    //
    // Le refus n'est pas qu'un artifice de contrôle : un conducteur sans email
    // ni téléphone ne peut recevoir aucune invitation, donc jamais de compte
    // applicatif, donc aucune course. On refuserait plus tard, sans le dire.
    if (needles.length === 0) {
      badRequest(
        'driver.create_failed',
        'Renseignez au moins un email ou un téléphone — sans quoi ce conducteur ' +
          'ne pourra jamais recevoir son invitation.',
      );
    }

    for (const needle of needles) {
      let matches: any[] = [];
      try {
        const response = await this.fleetbaseClient.getAllDrivers({
          query: needle.trim(),
          limit: 20,
        });
        matches = this.fleetbaseClient.extractCollection(response, 'drivers');

        // ⚠️ Repli par les chiffres seuls, repris de `commercant.searchDrivers`.
        //
        // `?query=` est un LIKE SQL : « +213555123456 » ne trouve rien si
        // l'enregistrement porte « 0555123456 ». Sans ce repli, aucune
        // comparaison identifiante n'a lieu, et le doublon que toute cette
        // fonctionnalité existe pour empêcher est créé — sur le format le plus
        // courant du pays.
        //
        // ⚠️ **La condition porte sur l'absence de correspondance IDENTIFIANTE,
        // pas sur une liste vide.** Elle testait `matches.length === 0` : il
        // suffisait donc que le LIKE ramène quelqu'un d'autre — un email
        // contenant les mêmes chiffres, par exemple — pour que le balayage soit
        // sauté et le doublon créé quand même. Une liste non vide n'est pas une
        // réponse à la question posée.
        //
        // ⚠️ Et le balayage est PAGINÉ. Il était plafonné à 100 conducteurs :
        // au-delà, cette garde cessait d'opérer sans rien signaler.
        const identifies = (list: any[]) =>
          list.some(
            (d: any) =>
              sameIdentifier(d?.email, needle) || sameIdentifier(d?.phone, needle),
          );

        if (!identifies(matches) && subscriberDigits(needle).length >= 6) {
          matches = await this.fleetbaseClient.fetchEveryDriverMatching();
        }
      } catch (error: any) {
        // ⚠️ L'annuaire injoignable **ne bloque pas** la création.
        //
        // Refuser ici transformerait une panne de lecture en impossibilité
        // d'embaucher, alors que le pire cas toléré est un doublon — réparable,
        // et signalé dans le log. L'inverse ne l'est pas.
        this.logger.warn(`Contrôle de doublon impossible (${needle}) : ${error.message}`);
        return;
      }

      const exact = matches.find(
        (d: any) =>
          sameIdentifier(d?.email, needle) || sameIdentifier(d?.phone, needle),
      );

      if (exact) {
        conflict(
          'driver.already_in_network',
          'Cette personne est déjà dans le réseau — demandez son rattachement ' +
            'plutôt que de la créer une seconde fois.',
        );
      }
    }
  }


  /**
   * Dernière position connue des conducteurs de cette flotte.
   *
   * ── Où vit cette donnée, et où je l'ai longtemps cherchée ────────────────
   *
   * Sur le **conducteur lui-même** : `Driver.location`, mis à jour par l'appel
   * `track` que le BFF fait déjà à chaque remontée GPS. La table `Position` est
   * l'**historique**, pas l'état courant — et c'est là que je cherchais.
   *
   * L'absence de filtre par conducteur sur `/positions` (journal §2.11) est
   * bien réelle, mais elle ne concernait pas ce besoin. C'est ce contresens qui
   * a justifié trois colonnes de miroir pendant deux jours.
   *
   * Un conducteur sans position exploitable est absent du résultat, comme
   * avant : `[0,0]` signifie « n'a jamais émis », pas « au large de la Guinée »
   * (voir `readDriverPosition`).
   */
  async getDriverPositions(fleetId: string, requestedDriverIds: string[]) {
    const fleet = await this.getFleetWithValidation(fleetId);

    try {
      // Les adhérents compris : une carte qui n'affiche que les conducteurs
      // d'origine montrerait la moitié de la flotte sans le dire.
      const owned = await this.fleetDrivers(fleetId, fleet.fleetbaseVendorUuid);
      const ownedUuids = new Set<string>(owned.map((d: any) => d.uuid));

      const targetIds =
        requestedDriverIds && requestedDriverIds.length > 0
          ? requestedDriverIds.filter((id) => ownedUuids.has(id))
          : Array.from(ownedUuids);

      if (targetIds.length === 0) {
        return [];
      }

      // ── La position vient des conducteurs déjà rapatriés (Lot 6) ─────────
      //
      // `fleetDrivers()` ci-dessus renvoie déjà `location` : la version
      // précédente téléchargeait donc la donnée, la jetait, puis allait la
      // relire dans un miroir local. Le miroir a été supprimé, pas remplacé par
      // un second appel.
      //
      // Un conducteur sans position exploitable est simplement absent de la
      // liste, comme avant — c'est ce que faisait `lastPositionAt: { not: null }`.
      const targets = new Set(targetIds);

      return owned
        .filter((driver: any) => targets.has(driver?.uuid))
        .map((driver: any) => ({ driver, position: readDriverPosition(driver) }))
        .filter((entry) => entry.position !== null)
        .map(({ driver, position }) => ({
          driver_uuid: driver.uuid,
          // Le nom vient de Fleetbase, où l'opérateur l'a saisi, et non des
          // champs facultatifs que le transporteur remplit à l'inscription —
          // souvent vides (§19.3).
          name: driver.name ?? null,
          latitude: position!.latitude,
          longitude: position!.longitude,
          recorded_at: readPositionSeenAt(driver),
        }));
    } catch (error) {
      this.logger.error(`Failed to fetch driver positions: ${error.message}`);
      badRequest('driver.positions_fetch_failed', 'Failed to fetch driver positions');
    }
  }

  /**
   * Cherche un conducteur **déjà dans le réseau**, par nom ou téléphone.
   *
   * ── Pourquoi une recherche, et surtout pourquoi pas un annuaire ───────────
   *
   * Une entreprise qui embauche quelqu'un déjà connu du réseau doit pouvoir le
   * rattacher plutôt que le recréer. Sans ce chemin, la multi-appartenance est
   * mécaniquement impossible : la seconde entreprise n'a aucun moyen de savoir
   * que la personne existe, donc elle la crée — deux `Driver` Fleetbase pour un
   * seul être humain, avec position, disponibilité et historique dupliqués et
   * désynchronisés (le défaut documenté le 26/07 pour le multi-Organization).
   *
   * Le mécanisme est **repris tel quel** de la recherche de transporteur du
   * commerçant (29/07), y compris ses deux refus :
   *
   * - **le téléphone n'est jamais renvoyé** — celui qui cherche le connaît, il
   *   cherche par là ; le rendre ferait de cette route un moyen de collecter
   *   les coordonnées de conducteurs qu'on n'a jamais employés ;
   * - **pas de liste tronquée** — au-delà de dix correspondances on demande de
   *   préciser, une liste qu'on balaie en changeant une lettre étant exactement
   *   l'annuaire qu'on refuse d'ouvrir.
   *
   * ⚠️ `?query=` et jamais `?phone=` : ce dernier renvoie **500** chez
   * Fleetbase (`whereHas('phone')` sur un attribut calculé, bug amont reproduit
   * depuis leur propre console).
   */
  async searchNetworkDrivers(fleetId: string, query: string) {
    const fleet = await this.getFleetWithValidation(fleetId);

    const q = query.trim();

    let matches: any[] = [];
    try {
      // Onze demandés pour dix rendus : le onzième ne sert qu'à savoir qu'il y
      // en a trop, et n'est jamais renvoyé.
      const response = await this.fleetbaseClient.getAllDrivers({ query: q, limit: 11 });
      matches = this.fleetbaseClient.extractCollection(response, 'drivers');

      // ⚠️ Repli par les chiffres seuls, comme `commercant.searchDrivers` dont
      // cette méthode se réclame. `?query=` est un LIKE SQL : « 0555 12 34 »
      // ne trouve rien si l'enregistrement porte « +213555123456 ». Sans lui,
      // l'entreprise conclut que la personne n'est pas dans le réseau — et la
      // recrée, ce que tout ce lot existe pour éviter.
      // ⚠️ Deux défauts en un ici. Le balayage était plafonné à 100 — d'où la
      // pagination —, et surtout la comparaison portait sur les chiffres BRUTS :
      // « 0555123456 » ne contient pas « 213555123456 », donc le repli échouait
      // précisément sur le couple qu'il existait pour rattraper.
      if (matches.length === 0 && subscriberDigits(q).length >= 4) {
        const wide = await this.fleetbaseClient.fetchEveryDriverMatching();
        matches = wide.filter((d: any) => phoneContains(d?.phone, q));
      }
    } catch (error: any) {
      this.logger.warn(`Annuaire conducteurs indisponible : ${error.message}`);
      badRequest('driver.search_unavailable', 'Recherche indisponible pour le moment');
    }

    if (matches.length > 10) {
      badRequest(
        'driver.search_too_broad',
        'Trop de correspondances — précisez le nom ou le numéro.',
      );
    }

    // L'état du rattachement est joint à chaque résultat : sans lui, l'écran
    // proposerait « rattacher » sur quelqu'un déjà rattaché, et l'entreprise
    // découvrirait le refus après coup.
    const uuids = matches.map((d: any) => d?.uuid).filter(Boolean);

    const existing = await this.prisma.driverMembership.findMany({
      where: { fleetId, fleetbaseDriverUuid: { in: uuids } },
    });
    const byUuid = new Map<string, string>(
      existing.map((m: any) => [m.fleetbaseDriverUuid, m.status]),
    );

    // ⚠️ Qui a un compte applicatif, et qui n'en a pas.
    //
    // Un `Driver` peut exister chez Fleetbase sans compte Echango — c'est le cas
    // de tous ceux qu'un opérateur a créés et qui n'ont pas encore répondu à
    // leur invitation. Leur demander un rattachement produit une adhésion
    // `pending` que **personne ne pourra jamais accepter**, et l'entreprise
    // attendrait une réponse qui ne viendra pas. On le dit plutôt que de le
    // taire, comme le fait déjà la recherche du commerçant.
    const accounts = await this.prisma.driverAccount.findMany({
      where: { fleetbaseDriverUuid: { in: uuids } },
      select: { fleetbaseDriverUuid: true },
    });
    const withAccount = new Set(accounts.map((a: any) => a.fleetbaseDriverUuid));

    return {
      data: matches.map((driver: any) => ({
        driver_uuid: driver?.uuid,
        name: driver?.name ?? null,
        // Déjà d'origine chez nous : le rattacher n'aurait aucun sens.
        origin: driver?.vendor_uuid === fleet.fleetbaseVendorUuid,
        membership: byUuid.get(driver?.uuid) ?? null,
        has_account: withAccount.has(driver?.uuid),
      })),
    };
  }

  /**
   * Demander le rattachement d'un conducteur existant à cette entreprise.
   *
   * ── L'adhésion naît `pending`, et ce n'est pas de la politesse ────────────
   *
   * La dette d'espèces naît du couple (conducteur, facilitateur). Créer ce
   * couple sans l'accord du conducteur lui imposerait une **obligation
   * financière unilatérale** : l'entreprise le rattache, lui confie une course
   * encaissée, et le voilà débiteur d'un montant qu'il n'a jamais accepté de
   * porter. L'acceptation est donc une condition de l'engagement, pas une
   * courtoisie.
   */
  async requestMembership(fleetId: string, driverUuid: string) {
    const fleet = await this.getFleetWithValidation(fleetId);

    let driver: any;
    try {
      driver = await this.fleetbaseClient.getDriverByUuid(driverUuid);
    } catch (error: any) {
      this.logger.warn(`Conducteur ${driverUuid} illisible : ${error.message}`);
      notFound('driver.not_found', 'Driver not found');
    }

    if (!driver?.uuid) {
      notFound('driver.not_found', 'Driver not found');
    }

    // Déjà d'origine chez nous : le lien existe par `vendor_uuid`, une adhésion
    // en doublon ferait apparaître la personne deux fois dans la liste.
    if (driver.vendor_uuid === fleet.fleetbaseVendorUuid) {
      conflict('membership.already_exists', 'Ce conducteur fait déjà partie de votre entreprise.');
    }

    const existing = await this.prisma.driverMembership.findUnique({
      where: {
        fleetbaseDriverUuid_fleetId: { fleetbaseDriverUuid: driverUuid, fleetId },
      },
    });

    if (existing && ['pending', 'active'].includes(existing.status)) {
      conflict('membership.already_exists', 'Une demande existe déjà pour ce conducteur.');
    }

    // Une adhésion refusée ou suspendue se **redemande** : on remet la ligne à
    // `pending` plutôt que d'en créer une seconde, pour que l'unicité du couple
    // tienne et que l'historique de la relation reste sur une seule ligne.
    // ⚠️ Annoté explicitement : le client Prisma n'est pas généré dans cet
    // environnement (le proxy sortant refuse `binaries.prisma.sh`), donc tout ce
    // qui traverse un type Prisma y est `any` et `tsc` ne vérifie rien de ces
    // lignes-là. L'annotation est ce qui reste vérifiable ici.
    const data: {
      status: string;
      driverName: string | null;
      requestedAt: Date;
      respondedAt: Date | null;
      suspendedAt: Date | null;
    } = {
      status: 'pending',
      driverName: driver.name ?? null,
      requestedAt: new Date(),
      respondedAt: null,
      suspendedAt: null,
    };

    const membership = existing
      ? await this.prisma.driverMembership.update({ where: { id: existing.id }, data })
      : await this.prisma.driverMembership.create({
          data: { ...data, fleetbaseDriverUuid: driverUuid, fleetId },
        });

    this.logger.log(`Adhésion demandée : conducteur ${driverUuid} → flotte ${fleetId}`);

    return {
      id: membership.id,
      driver_uuid: membership.fleetbaseDriverUuid,
      name: membership.driverName,
      status: membership.status,
    };
  }

  /** Les demandes et rattachements de cette entreprise, tous états confondus. */
  async listMemberships(fleetId: string) {
    await this.getFleetWithValidation(fleetId);

    const memberships = await this.prisma.driverMembership.findMany({
      where: { fleetId },
      orderBy: { requestedAt: 'desc' },
    });

    return {
      data: memberships.map((m: any) => ({
        id: m.id,
        driver_uuid: m.fleetbaseDriverUuid,
        name: m.driverName,
        status: m.status,
        requested_at: m.requestedAt,
        responded_at: m.respondedAt,
      })),
    };
  }

  /**
   * Suspendre ou réactiver un rattachement.
   *
   * ⚠️ **Jamais de suppression.** La dette d'un conducteur envers une entreprise
   * survit à leur séparation ; effacer la ligne emporterait la seule trace du
   * lien qui l'explique, et le registre afficherait une dette sans contrepartie
   * lisible. Une entreprise coupe l'accès, elle n'efface pas le passé.
   */
  async setMembershipStatus(fleetId: string, membershipId: string, suspended: boolean) {
    await this.getFleetWithValidation(fleetId);

    const membership = await this.prisma.driverMembership.findUnique({
      where: { id: membershipId },
    });

    // Un seul refus pour « inexistant » et « pas à vous » : distinguer les deux
    // apprendrait à une entreprise que l'adhésion existe ailleurs.
    if (!membership || membership.fleetId !== fleetId) {
      notFound('membership.not_found', 'Membership not found');
    }

    // ⚠️ **Les deux sens sont gardés, et il le faut absolument.**
    //
    // Seule la réactivation l'était. La suspension, elle, acceptait n'importe
    // quel état de départ — d'où un chemin en deux appels, entièrement dans les
    // droits de l'entreprise, qui produisait un rattachement **actif sans
    // consentement** :
    //
    //     demander        → pending
    //     suspendre       → suspended   (aucune garde)
    //     reactiver       → active      (garde satisfaite)
    //
    // Le conducteur n'avait jamais répondu, et l'entreprise pouvait lui confier
    // une course encaissée : exactement l'obligation financière unilatérale que
    // le passage par `pending` existe pour empêcher. Le même chemin **écrasait
    // un refus explicite** (`declined` → `suspended` → `active`).
    //
    // On ne suspend donc que ce qui est actif, et on ne réactive que ce qui a
    // été suspendu. `pending` et `declined` n'ont aucune sortie vers `active`
    // autre que la réponse du conducteur.
    if (suspended && membership.status !== 'active') {
      conflict(
        'membership.not_active',
        'Seul un rattachement actif peut être suspendu.',
      );
    }

    if (!suspended && membership.status !== 'suspended') {
      conflict(
        'membership.not_suspended',
        'Seul un rattachement suspendu peut être réactivé.',
      );
    }

    const updated = await this.prisma.driverMembership.update({
      where: { id: membership.id },
      data: {
        status: suspended ? 'suspended' : 'active',
        suspendedAt: suspended ? new Date() : null,
      },
    });

    return { id: updated.id, status: updated.status };
  }

  /**
   * Les uuid des conducteurs rattachés par adhésion **active**.
   *
   * Séparé de `fetchOwnedDrivers` parce que les deux sources ne se ressemblent
   * pas : l'une est un filtre Fleetbase sur `vendor_uuid`, l'autre une table
   * locale. Les composer est le travail de `getDrivers()`.
   */
  private async activeMemberUuids(fleetId: string): Promise<string[]> {
    const memberships = await this.prisma.driverMembership.findMany({
      where: { fleetId, status: 'active' },
      select: { fleetbaseDriverUuid: true },
    });
    return memberships.map((m: any) => m.fleetbaseDriverUuid as string);
  }

  /**
   * Create a Driver and attach it to this fleet's Vendor.
   *
   * ⚠️ **Refuse une personne déjà présente dans le réseau**, et c'est cette
   * garde qui fait tenir toute la multi-appartenance.
   *
   * Sans elle, l'entreprise B qui embauche quelqu'un que A a déjà inscrit le
   * crée une seconde fois — elle n'a aucun moyen de savoir qu'il existe. Deux
   * `Driver` Fleetbase pour une personne, dont la position, la disponibilité et
   * l'historique divergent aussitôt. L'écran pousse vers la recherche, mais un
   * écran se contourne : le refus est ici.
   */
  async addDriver(fleetId: string, dto: AddDriverDto) {
    const fleet = await this.getFleetWithValidation(fleetId);

    await this.assertNotAlreadyInNetwork(dto);

    try {
      const created = await this.fleetbaseClient.createDriver({
        name: dto.name,
        email: dto.email,
        phone: dto.phone,
      });
      const driver = created?.driver || created;
      const driverUuid = driver?.uuid || driver?.id;

      if (!driverUuid) {
        throw new Error('Driver UUID not returned from Fleetbase');
      }

      await this.fleetbaseClient.assignDriverToVendor(fleet.fleetbaseVendorUuid, driverUuid);

      // ⚠️ Le cache de `fetchOwnedDrivers` (5 s) ignore encore ce conducteur.
      // Sans cette invalidation, l'entreprise qui crée quelqu'un puis lui
      // affecte une course dans la foulée recevait un **403 sur un conducteur
      // qu'elle venait de créer** : `fleetMayUseDriver` lisait la liste périmée,
      // ne l'y trouvait pas, et aucune adhésion n'existe pour un conducteur
      // d'origine.
      this.driverCache.delete(fleet.fleetbaseVendorUuid);

      this.logger.log(`Driver ${driverUuid} created and assigned to fleet ${fleetId}`);
      return driver;
    } catch (error) {
      this.logger.error(`Failed to add driver: ${error.message}`, error);
      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      badRequest(
        'driver.create_failed',
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to add driver: ${detail}`
          : 'Failed to add driver',
      );
    }
  }

  /**
   * Assign a driver to an order. Verifies BOTH the order and the driver
   * belong to this fleet before calling Fleetbase (anti-IDOR - otherwise a
   * fleet manager could assign another fleet's order to their own driver,
   * or assign their order to a driver they don't own).
   */
  async assignDriver(fleetId: string, orderId: string, driverId: string) {
    const fleet = await this.getFleetWithValidation(fleetId);

    // Verifies ownership of the order (throws NotFound/Forbidden otherwise)
    await this.getOrderDetail(fleetId, orderId);

    // ⚠️ « À moi » ne veut plus dire `vendor_uuid` : un conducteur peut être
    // rattaché par adhésion, et s'en tenir à l'origine refuserait une
    // affectation parfaitement légitime — l'entreprise verrait la personne dans
    // sa liste et ne pourrait rien lui confier.
    const mayUse = await this.fleetMayUseDriver(fleetId, fleet.fleetbaseVendorUuid, driverId);

    if (!mayUse) {
      forbidden('driver.forbidden', 'You do not have access to this driver');
    }

    // Une course à la fois, toutes entreprises confondues : deux encaissements
    // simultanés se mélangent dans la même poche et l'ordre des remises devient
    // indéterminé. Le refus ne dit pas pour qui il roule — ce serait une fuite.
    if (await this.driverIsBusy(driverId, orderId)) {
      conflict(
        'driver.unavailable',
        'Ce conducteur a déjà une course en cours. Attendez qu\'il la termine.',
      );
    }

    // Le plafond de dette, sur un chemin qui ne le traversait pas (défaut D8).
    //
    // `assertCashCeiling()` du module transporteur n'est appelé que depuis
    // `acceptOrder()` — qu'une affectation par l'entreprise ne franchit jamais.
    // Une société pouvait donc s'affecter des courses encaissées sans aucune
    // borne, ce qui vide de son sens le seul garde-fou du paiement à la
    // livraison.
    await this.assertDriverCashCeiling(fleetId, driverId, orderId);

    try {
      const response = await this.fleetbaseClient.assignOrderToDriver(driverId, orderId);
      this.logger.log(`Order ${orderId} assigned to driver ${driverId}`);
      return response;
    } catch (error) {
      this.logger.error(`Failed to assign driver: ${error.message}`);
      badRequest('order.assign_failed', 'Failed to assign driver');
    }
  }


  /**
   * Refuse l'affectation si elle ferait franchir le plafond de dette.
   *
   * La contrepartie est **l'entreprise elle-même** dès qu'elle facilite la
   * course : c'est son exposition qu'on borne, tous conducteurs confondus, et
   * c'est précisément le défaut que ce chantier corrige — dix conducteurs
   * accumulaient dix plafonds chez le même commerçant.
   *
   * Un conducteur sans compte Echango ne peut pas porter de dette dans le
   * registre : on laisse passer plutôt que de bloquer une affectation
   * légitime sur une donnée qui n'existe pas.
   */
  private async assertDriverCashCeiling(
    fleetId: string,
    driverUuid: string,
    orderId: string,
  ): Promise<void> {
    let order: any;
    try {
      order = this.withEffectiveMeta(await this.readOrder(orderId));
    } catch (error: any) {
      this.logger.warn(`Plafond non vérifié pour ${orderId} : ${error.message}`);
      return;
    }

    const fleetSide = await this.assertFleetCeiling(fleetId, order);
    if (!fleetSide) return;
    const { codAmount, merchantId } = fleetSide;

    // ⚠️ **Le plafond du CONDUCTEUR, vérifié ici et pas seulement au démarrage.**
    //
    // Le contrôle ci-dessus porte sur l'entreprise. Celui du conducteur
    // n'existait que sur `acceptOrder`/`startOrder`, c'est-à-dire **après** que
    // l'entreprise lui a confié la course : elle affectait donc une course qu'il
    // ne pourrait pas démarrer, sans aucun signal de son côté — et la course
    // restait assignée à quelqu'un de bloqué.
    //
    // Le message ne nomme pas ce que le conducteur détient ailleurs : ce sont
    // les affaires d'une autre entreprise.
    const driverAccount = await this.prisma.driverAccount.findUnique({
      where: { fleetbaseDriverUuid: driverUuid },
      select: { id: true },
    });

    // Pas de compte applicatif ⇒ aucune dette possible dans le registre : rien à
    // vérifier, et bloquer ici ferait échouer une affectation légitime sur une
    // donnée qui n'existe pas.
    if (!driverAccount) return;

    const forDriver = await this.cash.canTakeCashOrder(
      driverParty(driverAccount.id),
      this.cash.driverCounterparty(fleetId, merchantId),
      codAmount,
    );

    if (!forDriver.allowed) {
      conflict(
        'cash.ceiling_exceeded',
        'Ce conducteur détient déjà trop d\'espèces non remises pour prendre ' +
          'une course encaissée. Faites-lui remettre ce qu\'il doit.',
      );
    }
  }

  /**
   * Commandes de cette flotte, paginées jusqu'au bout.
   *
   * La pagination reste nécessaire malgré le filtre serveur : une flotte active
   * peut dépasser 100 commandes, et une page unique tronquerait la liste en
   * silence — le défaut que cette méthode évitait déjà quand elle balayait
   * toute la compagnie.
   */
  private fetchAllOrders(vendorUuid: string): Promise<any[]> {
    return this.fleetbaseClient.fetchEveryOrder(100, 50, { facilitator: vendorUuid });
  }

  /**
   * Conducteurs de cette flotte, avec un cache mémoire de courte durée.
   *
   * `?vendor=` est le nom réel du filtre — `vendor_uuid`, essayé en §2.8,
   * n'existe pas et était abandonné en silence. La vérification en mémoire qui
   * suit est conservée pour la même raison que dans `getOrders` : c'est elle
   * qui autorise, le filtre ne fait qu'alléger.
   *
   * ── Pourquoi un cache, et pourquoi celui-ci est légitime ─────────────────
   *
   * La charge utile d'un conducteur Fleetbase est **très lourde** : elle
   * embarque `user.role.policies[].permissions[]`, soit plusieurs centaines
   * d'entrées répétées pour chaque conducteur. Constaté sur les données réelles
   * le 29/07/2026, pas supposé.
   *
   * Depuis le Lot 6, la carte de flotte lit les positions ici même : cet appel
   * passe donc de « une fois par écran » à « à chaque rafraîchissement ».
   *
   * C'est l'exception §3.1 de `architecture_bff_fleetbase.md` dans son usage
   * prévu : **jetable sans perte** — le vider ne fait que provoquer un appel de
   * plus — et motivé par un coût mesuré, non par une préférence. Sa durée de vie
   * est délibérément plus courte que la cadence d'émission GPS de l'app, pour
   * qu'une position fraîche ne puisse pas attendre derrière lui.
   *
   * Cloisonné par `vendorUuid` : deux flottes ne partagent jamais une entrée.
   */
  private readonly driverCache = new Map<string, { at: number; drivers: any[] }>();

  private driverCacheTtlMs(): number {
    const configured = Number(this.configService.get('FLEET_DRIVER_CACHE_MS'));
    return Number.isFinite(configured) && configured >= 0 ? configured : 5_000;
  }

  private async fetchOwnedDrivers(vendorUuid: string): Promise<any[]> {
    const ttl = this.driverCacheTtlMs();
    const cached = this.driverCache.get(vendorUuid);
    if (cached && ttl > 0 && Date.now() - cached.at < ttl) {
      return cached.drivers;
    }

    // Paginé : sans cela, une entreprise dont les conducteurs dépassent la page
    // par défaut de Fleetbase ne voyait pas les siens — et le sélecteur de
    // conducteur les déclarait inexistants.
    const drivers = await this.fleetbaseClient.fetchEveryDriverMatching({
      vendor: vendorUuid,
    });
    const owned = drivers.filter((d: any) => d?.vendor_uuid === vendorUuid);

    this.driverCache.set(vendorUuid, { at: Date.now(), drivers: owned });
    return owned;
  }


  /**
   * Une commande, lue à l'unité, **avec ses relations**.
   *
   * ── Pourquoi ce point unique, et pourquoi il porte de l'argent ────────────
   *
   * Les quatre lectures unitaires de ce module appelaient `getOrder()`, la
   * version nue de `GET /int/v1/orders/{uuid}`, sans aucun `with[]`. Les modules
   * transporteur et commerçant utilisent `getOrderWithRelations()` ; **le module
   * flotte était le seul à ne pas le faire**, et personne ne s'en apercevait
   * parce qu'aucun écran ne l'ouvrait.
   *
   * Depuis le 30/07, prix et montant à encaisser vivent dans
   * `custom_field_values`. `readOrderCustomFields()` exige donc la relation ; le
   * commentaire qui affirmait qu'elle arrive de toute façon (via un
   * `loadMissing()` de la ressource amont) décrit le chemin de **liste**, et n'a
   * jamais été éprouvé sur la lecture unitaire.
   *
   * Ce n'est pas un problème d'affichage. `assertClaimCashCeiling()` et
   * `assertDriverCashCeiling()` lisent `meta.cod_amount` par ce chemin : si la
   * relation manque, le montant vaut `0`, la garde ne se déclenche **jamais**, et
   * une entreprise accumule des espèces sans plafond — en silence, sans erreur,
   * avec un plafond qui a l'air de fonctionner. Un défaut d'argent déguisé en
   * détail de sérialisation.
   *
   * Un seul point d'entrée pour que la question ne se repose pas quatre fois.
   */
  private async readOrder(orderId: string): Promise<any> {
    const response = await this.fleetbaseClient.getOrderWithRelations(orderId);
    return response?.order || response;
  }

  /**
   * La commande, `meta` recomposé depuis les champs personnalisés.
   *
   * ── Pourquoi ce module en manquait, et ce que ça coûtait ─────────────────
   *
   * Depuis la migration du 30/07, prix et montant à encaisser vivent dans
   * `custom_field_values`, pas dans `meta`. Les modules transporteur et
   * commerçant recomposent ; **celui-ci ne l'a jamais fait**, parce qu'aucun
   * écran flotte n'existait pour s'en apercevoir.
   *
   * On demanderait donc à une entreprise de décider si elle prend une course,
   * puis de répondre des espèces encaissées, **sans lui montrer aucun des deux
   * montants** (défaut D6). La donnée est pourtant déjà dans la réponse :
   * `getAllOrders` demande `customFieldValues.customField`. Seule la projection
   * la jetait.
   */
  private withEffectiveMeta(order: any): any {
    if (!order) return order;
    // Pas de `specMeta` ici : ce module n'a pas de cache local des commandes.
    // La spécification est un filet posé sur les commandes créées PAR un
    // commerçant d'Echango ; une entreprise lit ce que Fleetbase porte.
    return { ...order, meta: effectiveOrderMeta(order, null) };
  }

  private async getFleetWithValidation(fleetId: string) {
    const fleet = await this.prisma.fleetAccount.findUnique({
      where: { id: fleetId },
    });

    if (!fleet) {
      notFound('fleet.not_found', 'Fleet account not found');
    }

    if (!fleet.active) {
      forbidden('fleet.inactive', 'Fleet account is inactive');
    }

    return fleet;
  }
}
