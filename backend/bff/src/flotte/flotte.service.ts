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
import { CashService, fleetParty, merchantParty } from '../cash/cash.service';

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
   * Projection expurgée : tant que la course n'est engagée par personne, la
   * livraison se réduit à sa commune, exactement comme côté transporteur. Le
   * prix et le montant à encaisser restent, eux — ce sont eux qui permettent de
   * décider.
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
   * Le pendant exact d'`isClaimableAdhoc()` côté transporteur, et il doit le
   * rester : les deux populations réclament la même chose, donc elles doivent
   * s'accorder sur ce que « libre » veut dire. **Les deux colonnes doivent être
   * vides** — un indépendant ne prend pas une course confiée à une entreprise,
   * une entreprise ne prend pas une course déjà démarrée par un indépendant.
   */
  private isClaimable(order: any): boolean {
    return (
      order?.adhoc === true &&
      !order?.driver_assigned_uuid &&
      !order?.facilitator_uuid &&
      order?.status !== 'canceled'
    );
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
      const response = await this.fleetbaseClient.getOrder(orderId);
      order = response?.order || response;
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
  private async assertClaimCashCeiling(fleetId: string, order: any): Promise<void> {
    const codAmount = Number(order?.meta?.cod_amount) || 0;
    if (codAmount <= 0) return;

    const cached = await this.prisma.order.findFirst({
      where: { fleetbaseOrderId: order?.uuid },
      select: { merchantId: true },
    });
    if (!cached) return;

    const { allowed, debt, ceiling } = await this.cash.canTakeCashOrder(
      fleetParty(fleetId),
      merchantParty(cached.merchantId),
      codAmount,
    );

    if (!allowed) {
      badRequest(
        'cash.ceiling_exceeded',
        `Votre entreprise détient déjà ${debt} ${this.cash.currency} pour ce commerçant, et ` +
          `cette course en ajouterait ${codAmount} — au-delà du plafond de ${ceiling}.`,
      );
    }
  }

  /**
   * Get a single order, verifying it belongs to this fleet before returning
   * anything (anti-IDOR - never trust the id alone).
   */
  async getOrderDetail(fleetId: string, orderId: string) {
    const fleet = await this.getFleetWithValidation(fleetId);

    try {
      const response = await this.fleetbaseClient.getOrder(orderId);
      const order = response?.order || response;

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
      const owned = await this.fetchOwnedDrivers(fleet.fleetbaseVendorUuid);
      return { data: owned.map((d: any) => projectDriverForFleet(d)) };
    } catch (error) {
      this.logger.error(`Failed to fetch fleet drivers: ${error.message}`);
      badRequest('driver.fetch_failed', 'Failed to fetch drivers');
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
      const owned = await this.fetchOwnedDrivers(fleet.fleetbaseVendorUuid);
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
      // `fetchOwnedDrivers()` ci-dessus renvoie déjà `location` : la version
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
   * Create a Driver and attach it to this fleet's Vendor.
   */
  async addDriver(fleetId: string, dto: AddDriverDto) {
    const fleet = await this.getFleetWithValidation(fleetId);

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

    const owned = await this.fetchOwnedDrivers(fleet.fleetbaseVendorUuid);
    const ownsDriver = owned.some((d: any) => d.uuid === driverId);

    if (!ownsDriver) {
      forbidden('driver.forbidden', 'You do not have access to this driver');
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
      const response = await this.fleetbaseClient.getOrder(orderId);
      order = this.withEffectiveMeta(response?.order || response);
    } catch (error: any) {
      this.logger.warn(`Plafond non vérifié pour ${orderId} : ${error.message}`);
      return;
    }

    const codAmount = Number(order?.meta?.cod_amount) || 0;
    if (codAmount <= 0) return;

    const cached = await this.prisma.order.findFirst({
      where: { fleetbaseOrderId: order?.uuid },
      select: { merchantId: true },
    });
    if (!cached) return;

    const { allowed, debt, ceiling } = await this.cash.canTakeCashOrder(
      fleetParty(fleetId),
      merchantParty(cached.merchantId),
      codAmount,
    );

    if (!allowed) {
      badRequest(
        'cash.ceiling_exceeded',
        `Votre entreprise détient déjà ${debt} ${this.cash.currency} pour ce commerçant, et ` +
          `cette course en ajouterait ${codAmount} — au-delà du plafond de ${ceiling}.`,
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

    const response = await this.fleetbaseClient.getAllDrivers({ vendor: vendorUuid });
    const drivers = response?.drivers || response?.data || (Array.isArray(response) ? response : []);
    const owned = (drivers || []).filter((d: any) => d?.vendor_uuid === vendorUuid);

    this.driverCache.set(vendorUuid, { at: Date.now(), drivers: owned });
    return owned;
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
