import {
  Injectable,
  Logger,
  BadRequestException,
  ForbiddenException,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../database/prisma.service';
import { AuditService } from '../common/audit/audit.service';
import { NotificationsService } from '../notifications/notifications.service';
import { CashService } from '../cash/cash.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { projectOrderForDriver } from '../common/projections/order.projection';
import {
  UpdatePositionDto,
  ToggleOnlineDto,
  UpdateActivityDto,
  ReportDeliveryFailureDto,
  DeclineOrderDto,
  CashCollectionDto,
  CapturePhotoDto,
  ListDriverOrdersQueryDto,
} from './dto/transporteur.dto';

@Injectable()
export class TransporteurService {
  private readonly logger = new Logger(TransporteurService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly fleetbaseClient: FleetbaseApiClient,
    private readonly audit: AuditService,
    private readonly notifications: NotificationsService,
    private readonly cash: CashService,
    private readonly configService: ConfigService,
  ) {}

  /**
   * Load the Echango driver account and its Fleetbase identifiers.
   *
   * Every method below starts here rather than trusting the JWT payload: the
   * token carries an account id, and the mapping to a Fleetbase driver has to
   * come from the database each time, so a deactivated account stops working
   * immediately instead of at token expiry.
   */
  private async getDriverOrFail(driverId: string) {
    const driver = await this.prisma.driverAccount.findUnique({
      where: { id: driverId },
    });

    if (!driver || !driver.active) {
      throw new ForbiddenException('Driver account not found or inactive');
    }

    return driver;
  }

  /**
   * The Fleetbase Driver record behind an Echango account.
   *
   * A full list fetch, because `/drivers` has the same silently-ignored-filter
   * behaviour as `/orders` (journal §2.8) — there is no by-uuid lookup to use.
   */
  private async findFleetbaseDriver(fleetbaseDriverUuid: string) {
    const response = await this.fleetbaseClient.getAllDrivers();
    const drivers = this.fleetbaseClient.extractCollection(response, 'drivers');
    return drivers.find((d: any) => d?.uuid === fleetbaseDriverUuid);
  }

  /**
   * Resolve the driver's Fleetbase public_id, backfilling it if absent.
   *
   * Accounts registered before the column existed have it null, and
   * POST /v1/orders/{id}/start is the one call that refuses a uuid.
   */
  private async getDriverPublicId(driver: { id: string; fleetbaseDriverUuid: string; fleetbaseDriverPublicId: string | null }) {
    if (driver.fleetbaseDriverPublicId) {
      return driver.fleetbaseDriverPublicId;
    }

    const match = await this.findFleetbaseDriver(driver.fleetbaseDriverUuid);

    if (!match?.public_id) {
      throw new BadRequestException('Could not resolve this driver public_id in Fleetbase');
    }

    await this.prisma.driverAccount.update({
      where: { id: driver.id },
      data: { fleetbaseDriverPublicId: match.public_id },
    });

    return match.public_id;
  }

  /**
   * Resolve an order by whichever identifier the app sent, from the company
   * order list.
   *
   * Why not a direct GET by id: the public `v1` API addresses records by
   * public_id only — `findRecordOrFail()` matches `public_id`/`internal_id`
   * and never `uuid` (verified 28/07/2026 in core-api HasApiModelBehavior,
   * after a 404 on a perfectly valid uuid). Meanwhile `int/v1` works in uuids,
   * and §2.13 showed its by-id GET ignores the path param entirely. Matching
   * both identifiers here means the app can send either and neither quirk
   * leaks into the rest of the module.
   *
   * Cost: one list fetch per operation. Acceptable at this scale, and the
   * ownership check below needs the record anyway.
   */
  private async resolveOrder(orderId: string) {
    let orders: any[];
    try {
      orders = await this.fleetbaseClient.fetchEveryOrder();
    } catch (error) {
      this.logger.error(`Order lookup failed (${orderId}): ${error.message}`);
      throw new BadRequestException('Failed to fetch orders');
    }

    return orders.find((o) => o?.uuid === orderId || o?.public_id === orderId);
  }

  /**
   * The identifier to use when calling the public v1 API for this order.
   * Fails loudly rather than sending a uuid that would 404 confusingly.
   */
  private orderPublicId(order: any): string {
    if (!order?.public_id) {
      throw new BadRequestException('This order has no public_id — cannot address it on the v1 API');
    }
    return order.public_id;
  }

  /**
   * Attach this driver's reported failures to the orders being returned.
   *
   * Without this a reported failure is invisible: it lives only in the BFF
   * (§6.5 — no confirmed native per-waypoint failed status), and the Fleetbase
   * order keeps its own status, so the app has no way to show that anything
   * was reported. The driver files a report and the screen looks unchanged,
   * which is indistinguishable from the feature being broken.
   *
   * Exposed as `delivery_failure` because that is the key the app's model
   * already reads.
   */
  private async attachFailures(driverId: string, orders: any[]) {
    if (!orders.length) return orders;

    const failures = await this.prisma.deliveryFailure.findMany({
      where: {
        driverId,
        fleetbaseOrderUuid: { in: orders.map((o) => o?.uuid).filter(Boolean) },
      },
      orderBy: { reportedAt: 'desc' },
    });

    // Projeter même sans signalement : cette méthode est le seul point de
    // passage des commandes assignées, et un retour anticipé laisserait sortir
    // les objets Fleetbase bruts.
    if (!failures.length) return orders.map((o) => projectOrderForDriver(o));

    // Tous les rapports d'une commande, du plus récent au plus ancien.
    //
    // Une version précédente ne gardait que le dernier, au motif que « seul le
    // dernier décrit l'état courant ». C'est vrai d'un badge de statut, faux
    // d'un signalement : une livraison qui a échoué trois fois n'est pas celle
    // qui a échoué une fois, et l'opérateur qui décide de la suite a besoin de
    // la série. Chaque rapport porte de surcroît sa propre photo — n'en
    // exposer qu'une revenait à effacer les preuves précédentes.
    const byOrder = new Map<string, any[]>();
    for (const f of failures) {
      const list = byOrder.get(f.fleetbaseOrderUuid) ?? [];
      list.push(f);
      byOrder.set(f.fleetbaseOrderUuid, list);
    }

    const project = (failure: any) => ({
      id: failure.id,
      reason: failure.reason,
      notes: failure.notes,
      // Chemin sur le BFF, jamais l'URL Fleetbase. Celle-ci pointe sur
      // l'hôte tel que Fleetbase se connaît — injoignable depuis un
      // téléphone — et surtout elle n'est protégée par rien : la donner à
      // l'app reviendrait à publier les preuves de livraison à qui
      // devinerait l'adresse. Ici, le jeton du transporteur fait foi.
      photo_url: failure.proofUrl ? `/transporteur/preuves/${failure.id}` : null,
      created_at: failure.reportedAt.toISOString(),
    });

    return orders.map((order) => {
      const list = byOrder.get(order?.uuid);
      return projectOrderForDriver(order, {
        extra: list?.length
          ? {
              // `delivery_failure` reste le plus récent : c'est ce qu'affichent
              // les vues résumées, et le retirer casserait la liste sans rien
              // apporter.
              delivery_failure: project(list[0]),
              delivery_failures: list.map(project),
            }
          : {},
      });
    });
  }

  /**
   * Sert la photo d'un signalement, après contrôle d'appartenance.
   *
   * Le filtre porte sur `driverId` en plus de l'identifiant : sans lui, un
   * transporteur lirait les preuves d'un autre en changeant un cuid — même
   * discipline anti-IDOR que partout ailleurs, appliquée ici à un fichier.
   */
  async getProofImage(driverId: string, failureId: string) {
    const driver = await this.getDriverOrFail(driverId);

    const failure = await this.prisma.deliveryFailure.findFirst({
      where: { id: failureId, driverId: driver.id },
    });

    if (!failure) {
      // Distinguer « pas de preuve » de « preuve d'un autre » serait un oracle :
      // même réponse, mais seul le second cas est journalisé.
      this.audit.denied({
        actorType: 'transporteur',
        actorId: driverId,
        action: 'proof.access',
        resourceType: 'DeliveryFailure',
        resourceId: failureId,
        reason: 'Signalement inexistant ou appartenant à un autre transporteur',
      });
      throw new NotFoundException('Aucune preuve pour ce signalement');
    }

    if (!failure.proofUrl) {
      throw new NotFoundException('Aucune preuve pour ce signalement');
    }

    try {
      return await this.fleetbaseClient.fetchStoredFile(failure.proofUrl);
    } catch (error) {
      this.logger.warn(
        `Lecture de la preuve ${failureId} impossible (${failure.proofUrl}) : ${error.message}. ` +
          'Si Fleetbase répond « There is nothing to see here », le fichier existe mais ' +
          'aucune route ne le sert : vérifier FLEETBASE_PROOF_DISK=public et que ' +
          '`php artisan storage:link` a bien été exécuté côté Fleetbase.',
      );
      throw new NotFoundException('Preuve indisponible');
    }
  }

  /**
   * Extrait la ressource Proof de la réponse de `capture-photo`.
   *
   * Deux pièges, tous deux constatés en réel (28/07/2026) sur un upload qui
   * réussissait pourtant sans erreur :
   *
   * 1. **`uuid` n'existe pas sur l'API publique.** `Http/Resources/v1/Proof`
   *    place `uuid` et `public_id` derrière `Http::isInternalRequest()` ; sur
   *    `v1`, seul `id` est présent, et il porte le public_id. Lire `uuid`
   *    renvoyait donc toujours `null`, et l'app en concluait — logiquement —
   *    que la photo n'avait pas été jointe.
   *
   * 2. **La ressource expose elle-même un champ `data`.** Déballer
   *    aveuglément le premier `data` rencontré, pour traverser l'enveloppe
   *    Laravel, renvoie donc la charge utile de la preuve au lieu de la
   *    preuve. D'où la discrimination sur `url`/`id` plutôt que sur la seule
   *    présence de `data`.
   */
  private extractProof(response: any) {
    for (const candidate of [response?.data, response]) {
      if (candidate && (candidate.url !== undefined || candidate.id !== undefined)) {
        return candidate;
      }
    }
    return response;
  }

  private isAssignedTo(order: any, driverUuid: string) {
    return (
      order?.driver_assigned_uuid === driverUuid ||
      order?.driver_assigned?.uuid === driverUuid
    );
  }

  /**
   * Profil du transporteur, disponibilité comprise.
   *
   * `online` vient de Fleetbase et non d'un état mémorisé côté app : c'est
   * Fleetbase qui décide à qui le dispatch géospatial diffuse une course, donc
   * lui seul sait si ce driver est réellement joignable. Sans ce champ, l'app
   * afficherait au redémarrage la position par défaut de son interrupteur —
   * un driver rouvrant l'app se croirait hors ligne tout en continuant de
   * recevoir des courses, ou l'inverse.
   *
   * `null` quand Fleetbase est injoignable : l'app doit alors afficher un état
   * indéterminé plutôt que d'affirmer « hors ligne », qui serait un mensonge
   * dans le sens dangereux (le driver ne réagit pas à une course reçue).
   */
  async getProfile(driverId: string) {
    const driver = await this.getDriverOrFail(driverId);

    let online: boolean | null = null;
    try {
      const publicId = await this.getDriverPublicId(driver);
      const record = await this.fleetbaseClient.getDriverByPublicId(publicId);
      const payload = record?.data ?? record?.driver ?? record;
      if (payload?.online !== undefined && payload?.online !== null) {
        online = Boolean(payload.online);
      }
    } catch (error) {
      this.logger.warn(`Could not read online status for driver ${driverId}: ${error.message}`);
    }

    return {
      id: driver.id,
      email: driver.email,
      firstName: driver.firstName,
      lastName: driver.lastName,
      phone: driver.phone,
      fleetbaseDriverUuid: driver.fleetbaseDriverUuid,
      vehicleType: driver.vehicleType,
      online,
    };
  }

  /**
   * Déclare la catégorie de véhicule du transporteur.
   *
   * Elle filtre les opportunités qu'il voit : une course exigeant un
   * utilitaire ne lui est pas proposée s'il roule en moto. Ne rien déclarer
   * reste le comportement le plus ouvert — il voit tout.
   */
  async updateVehicleType(driverId: string, vehicleType?: string) {
    const driver = await this.getDriverOrFail(driverId);
    await this.prisma.driverAccount.update({
      where: { id: driver.id },
      data: { vehicleType: vehicleType ?? null },
    });
    return { vehicleType: vehicleType ?? null };
  }

  // Note on identifiers below: every /v1 call takes the driver's public_id,
  // never the uuid — see resolveOrder() for why.

  async updatePosition(driverId: string, dto: UpdatePositionDto) {
    const driver = await this.getDriverOrFail(driverId);
    const publicId = await this.getDriverPublicId(driver);

    try {
      await this.fleetbaseClient.trackDriver(publicId, dto);
    } catch (error) {
      this.logger.error(`Position update failed for driver ${driverId}: ${error.message}`);
      throw new BadRequestException('Failed to update position');
    }

    // Miroir local du dernier point, pour que la carte de flotte n'ait pas à
    // télécharger tout l'historique de la compagnie (cf. schema.prisma).
    // Fleetbase reste la source de vérité : l'écriture ci-dessus a déjà réussi
    // quand on arrive ici, et un échec du miroir ne doit pas faire croire au
    // driver que sa position n'est pas partie.
    try {
      await this.prisma.driverAccount.update({
        where: { id: driver.id },
        data: {
          lastLatitude: dto.latitude,
          lastLongitude: dto.longitude,
          lastPositionAt: new Date(),
        },
      });
    } catch (error) {
      this.logger.warn(`Position mirror failed for driver ${driverId}: ${error.message}`);
    }

    return { success: true };
  }

  async toggleOnline(driverId: string, dto: ToggleOnlineDto) {
    const driver = await this.getDriverOrFail(driverId);
    const publicId = await this.getDriverPublicId(driver);

    try {
      const response = await this.fleetbaseClient.toggleDriverOnline(publicId, dto.online);

      // On rapporte ce que Fleetbase dit, pas ce qu'on lui a demandé.
      // L'ancienne version renvoyait `dto.online` tel quel : la réponse était
      // donc toujours celle attendue, y compris si l'écriture n'avait aucun
      // effet. Un test vert sur cette route ne prouvait rien.
      const payload = response?.data ?? response?.driver ?? response;
      const confirmed = payload?.online;

      if (confirmed !== undefined && confirmed !== null) {
        const applied = Boolean(confirmed);
        if (applied !== dto.online) {
          this.logger.warn(
            `Fleetbase a répondu online=${applied} pour une demande de ${dto.online} (driver ${publicId})`,
          );
        }
        return { online: applied };
      }

      // Réponse sans le champ : on ne peut ni confirmer ni infirmer.
      this.logger.warn(`toggle-online sans champ 'online' en réponse (driver ${publicId})`);
      return { online: null as boolean | null, requested: dto.online };
    } catch (error) {
      this.logger.error(`Online toggle failed for driver ${driverId}: ${error.message}`);
      throw new BadRequestException('Failed to update online status');
    }
  }

  /**
   * List the driver's orders.
   *
   * ⚠️ Filtering happens HERE, in the BFF, never by passing the driver uuid as
   * a query param. Journal §2.8 established that Fleetbase silently ignores
   * unsupported filters on /orders and returns the whole company collection —
   * so a server-side filter that looks like it works would in fact leak every
   * order in the organization to every driver. This is the same anti-IDOR
   * discipline as the two other personas (docs/specs_bff.md §5.3).
   */
  async listOrders(driverId: string, query: ListDriverOrdersQueryDto) {
    const driver = await this.getDriverOrFail(driverId);

    let orders: any[];
    try {
      orders = await this.fleetbaseClient.fetchEveryOrder();
    } catch (error) {
      this.logger.error(`Order list failed for driver ${driverId}: ${error.message}`);
      throw new BadRequestException('Failed to fetch orders');
    }

    const assigned = orders.filter((o) => this.isAssignedTo(o, driver.fleetbaseDriverUuid));

    // Adhoc opportunities: broadcast, not yet claimed by anyone. Fleetbase's
    // geospatial dispatch decides who gets pinged (specs_echango_delivery §3.2);
    // the BFF only avoids showing orders already taken.
    // Une exigence de véhicule est un MINIMUM, pas une égalité : une course
    // demandant une voiture reste faisable en utilitaire. Et un transporteur
    // qui n'a pas déclaré son véhicule voit tout — être écarté du réseau par un
    // champ non rempli serait le pire des défauts silencieux.
    const ladder = ['moto', 'voiture', 'utilitaire'];
    const mine = ladder.indexOf(driver.vehicleType ?? '');
    const suits = (order: any) => {
      if (mine < 0) return true;
      const required = ladder.indexOf(order?.meta?.vehicle_type ?? '');
      return required < 0 || required <= mine;
    };

    // Les courses que CE transporteur a refusées ne lui sont plus proposées.
    // Sans ce filtre, le refus n'aurait aucun effet visible : la course
    // reviendrait au rafraîchissement suivant, et l'écran serait
    // indiscernable d'une fonctionnalité en panne.
    const declined = new Set(
      (
        await this.prisma.orderDecline.findMany({
          where: { driverId: driver.id },
          select: { fleetbaseOrderUuid: true },
        })
      ).map((d: any) => d.fleetbaseOrderUuid),
    );

    const adhoc = orders.filter(
      (o) =>
        o?.adhoc === true &&
        !o?.driver_assigned_uuid &&
        o?.status !== 'canceled' &&
        !declined.has(o?.uuid) &&
        suits(o),
    );

    const isFinished = (o: any) => ['completed', 'canceled'].includes(o?.status);
    // Projection en liste d'autorisation : le BFF décide de ce qui sort, et
    // non Fleetbase (revue M10). `unclaimed` réduit le point de livraison à sa
    // commune ; l'enlèvement, qui est un commerce, passe en entier.
    const publicAdhoc = adhoc.map((o) => projectOrderForDriver(o, { unclaimed: true }));

    if (query.type === 'adhoc') return { orders: publicAdhoc };
    if (query.type === 'history') {
      return { orders: await this.attachFailures(driver.id, assigned.filter(isFinished)) };
    }
    if (query.type === 'assigned') {
      return { orders: await this.attachFailures(driver.id, assigned.filter((o) => !isFinished(o))) };
    }

    return {
      active: await this.attachFailures(driver.id, assigned.filter((o) => !isFinished(o))),
      adhoc: publicAdhoc,
      history: await this.attachFailures(driver.id, assigned.filter(isFinished)),
    };
  }

  /**
   * Fetch one order, enforcing that the driver may see it.
   *
   * Allowed when the order is assigned to them, or when it is an unclaimed
   * adhoc order (a broadcast opportunity they are entitled to consider).
   * Anything else is a 404 rather than a 403 — a driver has no business
   * learning that a given order id exists at all.
   */
  async getOrder(driverId: string, orderId: string) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.resolveOrder(orderId);

    if (!order) {
      throw new NotFoundException('Order not found');
    }

    const mine = this.isAssignedTo(order, driver.fleetbaseDriverUuid);
    const claimableAdhoc = order?.adhoc === true && !order?.driver_assigned_uuid;

    if (!mine && !claimableAdhoc) {
      this.audit.denied({
        actorType: 'transporteur',
        actorId: driverId,
        action: 'order.access',
        resourceType: 'Order',
        resourceId: orderId,
        reason: 'Commande ni assignée à ce driver ni adhoc disponible',
      });
      throw new NotFoundException('Order not found');
    }

    // Une adhoc que ce driver n'a pas encore réclamée passe par la même
    // expurgation que la liste. Sans ça, la protection ne tiendrait pas une
    // seconde : il suffirait d'ouvrir la fiche pour obtenir le nom, l'adresse
    // exacte et le téléphone que la liste venait de retirer.
    if (!mine) {
      return projectOrderForDriver(order, { unclaimed: true });
    }

    const [withFailure] = await this.attachFailures(driver.id, [order]);
    return withFailure;
  }

  /**
   * Refuse une course, avec un motif.
   *
   * ── Deux effets, selon d'où vient la course ────────────────────────────────
   *
   * **Diffusée et non réclamée** : elle disparaît de la liste de ce
   * transporteur, et de lui seul. Rien ne change pour les autres, ni pour le
   * commerçant — refuser une proposition n'est pas un évènement.
   *
   * **Assignée à lui** (favori sollicité en premier) : elle est détachée et
   * remise en diffusion, et le commerçant est prévenu. Sans ce chemin, une
   * course confiée à un favori indisponible restait bloquée jusqu'à
   * intervention manuelle — la limite explicitement signalée par
   * `pickAvailableFavourite()`. Le refus ne la lève pas entièrement (un favori
   * qui ignore la course sans rien dire la bloque toujours), mais il traite le
   * cas où le transporteur, lui, sait qu'il ne la prendra pas.
   *
   * ── Ce qui n'est pas refusable ─────────────────────────────────────────────
   *
   * Une course déjà démarrée. À ce stade le transporteur est engagé, souvent en
   * route : la sortie est le signalement d'échec (`/echec`), qui laisse une
   * trace et une preuve. Rendre une course en cours par un simple refus
   * effacerait cette obligation.
   */
  async declineOrder(driverId: string, orderId: string, dto: DeclineOrderDto) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.resolveOrder(orderId);

    if (!order) {
      throw new NotFoundException('Order not found');
    }

    const mine = this.isAssignedTo(order, driver.fleetbaseDriverUuid);
    const claimableAdhoc = order?.adhoc === true && !order?.driver_assigned_uuid;

    if (!mine && !claimableAdhoc) {
      this.audit.denied({
        actorType: 'transporteur',
        actorId: driverId,
        action: 'order.decline',
        resourceType: 'Order',
        resourceId: orderId,
        reason: 'Commande ni assignée à ce driver ni adhoc disponible',
      });
      throw new NotFoundException('Order not found');
    }

    if (mine && !['created', 'dispatched'].includes(order?.status)) {
      throw new BadRequestException(
        'Cette course est déjà démarrée : signalez un échec de livraison plutôt que de la refuser.',
      );
    }

    // Le détachement AVANT l'enregistrement : si Fleetbase refuse, la course
    // reste assignée, et prétendre l'avoir refusée serait un mensonge visible
    // à l'écran suivant. On échoue bruyamment plutôt que d'enregistrer un
    // refus sans effet.
    if (mine) {
      try {
        await this.fleetbaseClient.releaseOrderToPool(
          order.uuid,
          this.adhocRadiusMetres(),
        );
      } catch (error: any) {
        this.logger.error(`Remise au pool impossible (${orderId}) : ${error.message}`);
        throw new BadRequestException(
          error.response?.data?.errors?.[0] ||
            "Impossible de rendre cette course pour l'instant",
        );
      }
    }

    // Entrées tarifaires copiées, pas référencées : c'est l'appariement « ce
    // qui était offert » / « refusé pour tel motif » qui a de la valeur, et il
    // disparaît dès que la commande change ou est supprimée.
    const meta = order?.meta ?? {};

    const decline = await this.prisma.orderDecline.upsert({
      where: {
        driverId_fleetbaseOrderUuid: {
          driverId: driver.id,
          fleetbaseOrderUuid: order.uuid,
        },
      },
      create: {
        driverId: driver.id,
        fleetbaseOrderUuid: order.uuid,
        reason: dto.reason,
        notes: dto.notes,
        wasAssigned: mine,
        pricingInputs: meta.pricing_inputs ?? undefined,
        offeredPrice: typeof meta.price === 'number' ? meta.price : undefined,
        currency: typeof meta.currency === 'string' ? meta.currency : undefined,
      },
      update: { reason: dto.reason, notes: dto.notes, declinedAt: new Date() },
    });

    if (mine) {
      // Le cache est aligné AVANT de notifier, et c'est ce qui évite un
      // doublon : le réconciliateur détecte le désistement en comparant le
      // transporteur assigné qu'il a mémorisé à celui de Fleetbase. Laisser
      // l'ancien en place lui ferait voir la même transition au passage
      // suivant, et le commerçant recevrait deux fois le même message — une
      // fois d'ici, une fois de là.
      //
      // `updateMany` et non `update` : la commande peut ne pas être dans le
      // cache (créée depuis la console par un opérateur), auquel cas il n'y a
      // rien à aligner et rien à signaler.
      await this.prisma.order
        .updateMany({
          where: { fleetbaseOrderId: order.uuid },
          data: { driverAssignedUuid: null, driverName: null },
        })
        .catch((error: any) =>
          this.logger.warn(`Cache non aligné après refus (${orderId}) : ${error.message}`),
        );

      await this.notifications.notifyOrderOwner(order.uuid, {
        type: 'order.released',
        title: 'Transporteur désisté',
        body: 'Votre livraison a été proposée à nouveau aux transporteurs du réseau.',
      });
    }

    this.logger.log(
      `Course ${orderId} refusée par ${driverId} (${dto.reason}${mine ? ', remise au pool' : ''})`,
    );

    return {
      id: decline.id,
      reason: decline.reason,
      /** La course est-elle repartie au réseau, ou seulement masquée ? */
      releasedToPool: mine,
    };
  }

  /**
   * Rayon de rediffusion d'une course rendue.
   *
   * Même valeur que celle appliquée à la création (`CommerçantService`) : une
   * course rendue doit être proposée exactement comme elle l'aurait été si le
   * favori n'avait pas été sollicité, sans quoi le refus changerait
   * silencieusement sa portée.
   */
  private adhocRadiusMetres(): number {
    const configured = Number(this.configService.get('ADHOC_RADIUS_METRES'));
    return Number.isFinite(configured) && configured > 0 ? configured : 15000;
  }

  /**
   * Claim an adhoc order. Fleetbase does this in a single call: start with
   * `assign` set, which both assigns the driver and starts the order — the
   * behaviour §4.2 describes for "Accepter" ("assigne le driver et démarre
   * immédiatement").
   */
  async acceptOrder(driverId: string, orderId: string) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.getOrder(driverId, orderId);

    if (order?.driver_assigned_uuid && !this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      throw new BadRequestException('This order has already been taken by another driver');
    }

    const publicId = await this.getDriverPublicId(driver);

    try {
      const result = await this.fleetbaseClient.startOrder(this.orderPublicId(order), publicId);
      this.logger.log(`Driver ${driverId} accepted order ${orderId}`);
      return result;
    } catch (error) {
      this.logger.error(`Accept failed (${orderId}): ${error.message}`);
      // Losing a race for an adhoc order is expected, not exceptional.
      throw new BadRequestException(
        error.response?.data?.errors?.[0] || 'Failed to accept this order',
      );
    }
  }

  async startOrder(driverId: string, orderId: string) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.getOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      throw new BadRequestException('This order is not assigned to you');
    }

    try {
      return await this.fleetbaseClient.startOrder(this.orderPublicId(order));
    } catch (error) {
      this.logger.error(`Start failed (${orderId}): ${error.message}`);
      throw new BadRequestException(
        error.response?.data?.errors?.[0] || 'Failed to start this order',
      );
    }
  }

  /**
   * Clôture la livraison.
   *
   * ── L'encaissement fait partie de la clôture, il ne la suit pas ─────────────
   *
   * Sur une course payée à la réception, l'appel est **refusé sans déclaration
   * d'encaissement**. En faire une étape distincte et facultative garantirait
   * qu'elle soit oubliée un jour de pluie — et un encaissement non déclaré est
   * exactement ce que le registre existe pour empêcher. « Livré » et « perçu X »
   * sont un seul fait (`specs_paiement_livraison.md` §4.2).
   *
   * L'ordre importe : le registre est écrit **avant** la clôture Fleetbase. Si
   * l'écriture du registre échoue, la commande reste ouverte et le transporteur
   * peut réessayer ; dans l'ordre inverse, on aurait une livraison close dont
   * l'argent n'est comptabilisé nulle part — c'est-à-dire une somme perdue pour
   * le commerçant, sans trace de qui la détient.
   */
  async completeOrder(driverId: string, orderId: string, cash?: CashCollectionDto) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.getOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      throw new BadRequestException('This order is not assigned to you');
    }

    await this.settleCashIfDue(driver.id, order, cash);

    try {
      return await this.fleetbaseClient.completeOrder(this.orderPublicId(order));
    } catch (error) {
      this.logger.error(`Complete failed (${orderId}): ${error.message}`);
      throw new BadRequestException(
        error.response?.data?.errors?.[0] || 'Failed to complete this order',
      );
    }
  }

  /**
   * The transitions available on this order right now.
   *
   * The app needs this before it can call updateActivity at all: the order
   * detail carries no activity data (§6.9), so there is nothing to hand back
   * without asking for it. Entries flagged require_pod are what tell the app
   * to route through the proof screen first.
   */
  async getNextActivities(driverId: string, orderId: string, waypoint?: string) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.getOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      throw new BadRequestException('This order is not assigned to you');
    }

    try {
      return await this.fleetbaseClient.getNextActivities(this.orderPublicId(order), waypoint);
    } catch (error) {
      this.logger.error(`Next activities failed (${orderId}): ${error.message}`);
      throw new BadRequestException('Failed to fetch available activities');
    }
  }


  /**
   * Solde une livraison qu'on s'apprête à clôturer : encaissement s'il y en a
   * un, rémunération dans tous les cas.
   *
   * ── Appelé depuis les DEUX chemins de clôture, et c'est essentiel ───────────
   *
   * `POST /terminer` n'est pas le seul moyen de clore une livraison :
   * l'application suit en réalité les transitions que le serveur lui propose
   * (`next-activity`), et la transition terminale passe par `update-activity`.
   * Poser la garde sur le seul `terminer` l'aurait rendue décorative — le
   * chemin réellement emprunté par l'app l'aurait contournée, et une livraison
   * encaissée se serait close sans que l'argent figure nulle part.
   *
   * ── L'ordre n'est pas indifférent ───────────────────────────────────────────
   *
   * Le registre s'écrit **avant** la clôture Fleetbase. Si l'écriture échoue,
   * la commande reste ouverte et le transporteur peut réessayer ; dans l'ordre
   * inverse, on obtiendrait une livraison close et un encaissement fantôme.
   *
   * ── Comment l'argent se répartit ────────────────────────────────────────────
   *
   * Le transporteur retient sa rémunération sur les espèces qu'il tient, et ne
   * doit au commerçant que la différence. La formule vaut que les frais de
   * livraison soient inclus ou non dans le montant à encaisser — c'est ce qui
   * rend ce choix purement informatif pour le commerçant.
   */
  private async settleCashIfDue(
    driverId: string,
    order: any,
    cash?: CashCollectionDto,
  ): Promise<void> {
    const codAmount = Number(order?.meta?.cod_amount) || 0;
    const price = Number(order?.meta?.price) || 0;

    // Rien à enregistrer : ni encaissement, ni rémunération annoncée.
    if (codAmount <= 0 && price <= 0) return;

    if (codAmount > 0 && !cash) {
      throw new BadRequestException(
        `Cette livraison est payée à la réception (${codAmount} ${this.cash.currency}) : ` +
          'déclarez le montant encaissé pour la clôturer.',
      );
    }

    // Le commerçant vient du cache local, jamais de Fleetbase : c'est lui qui
    // fait autorité sur « à qui appartient cette commande » (§2.8).
    const cached = await this.prisma.order.findFirst({
      where: { fleetbaseOrderId: order.uuid },
      select: { merchantId: true },
    });

    if (!cached) {
      // Commande créée hors d'Echango — depuis la console opérateur. Il n'y a
      // pas de commerçant à qui rendre des comptes, donc pas de registre : mais
      // on refuse quand même l'encaissement, faute de savoir à qui l'imputer.
      if (codAmount > 0) {
        throw new BadRequestException(
          "Commande inconnue du registre Echango : impossible d'enregistrer un encaissement",
        );
      }
      return;
    }

    let collected = 0;
    if (codAmount > 0 && cash) {
      const result = await this.cash.declareCollection(
        driverId,
        cached.merchantId,
        order.uuid,
        codAmount,
        cash,
      );
      collected = result.collectedAmount;
    }

    // La rémunération est enregistrée sur TOUTE course, encaissée ou non :
    // c'est elle qui porte la commission d'Echango, et une course prépayée en
    // produit une tout autant. `collected` borne ce que le transporteur peut
    // retenir — on ne se paie pas sur de l'argent qu'on n'a pas.
    await this.cash.recordEarning(
      driverId,
      cached.merchantId,
      order.uuid,
      price,
      collected,
    );
  }

  /**
   * Cette transition clôt-elle la livraison ?
   *
   * `completed` est le code terminal des configurations de commande Fleetbase —
   * le même que celui sur lequel l'application colore déjà son bouton. Reconnu
   * ici pour savoir quand exiger la déclaration d'encaissement.
   */
  private isTerminalActivity(activity: any): boolean {
    return activity?.code === 'completed' || activity?.status === 'completed';
  }

  async updateActivity(driverId: string, orderId: string, dto: UpdateActivityDto) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.getOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      throw new BadRequestException('This order is not assigned to you');
    }

    // La transition terminale exige la déclaration d'encaissement au même titre
    // que `POST /terminer` : c'est ce chemin-ci que l'application emprunte.
    if (this.isTerminalActivity(dto.activity)) {
      await this.settleCashIfDue(driver.id, order, dto.cash);
    }

    try {
      return await this.fleetbaseClient.updateOrderActivity(
        this.orderPublicId(order),
        dto.activity,
        dto.proof,
      );
    } catch (error) {
      this.logger.error(`Activity update failed (${orderId}): ${error.message}`);
      throw new BadRequestException(
        error.response?.data?.errors?.[0] || 'Failed to update activity',
      );
    }
  }

  async capturePhoto(driverId: string, orderId: string, dto: CapturePhotoDto) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.getOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      throw new BadRequestException('This order is not assigned to you');
    }

    try {
      return await this.fleetbaseClient.captureOrderPhoto(
        this.orderPublicId(order),
        dto.photos,
        dto.remarks,
        dto.subjectId,
      );
    } catch (error) {
      this.logger.error(`Proof capture failed (${orderId}): ${error.message}`);
      // Surface Fleetbase's own message: a proof upload can fail for reasons
      // the driver can act on (image rejected) or not at all (storage disk
      // misconfigured), and a flat "failed" hides which.
      const detail =
        error.response?.data?.errors?.[0] ||
        error.response?.data?.error ||
        error.response?.data?.message;
      throw new BadRequestException(
        detail ? `Failed to upload proof: ${detail}` : 'Failed to upload proof',
      );
    }
  }

  /**
   * Report a failed delivery (docs/specs_app_transporteur.md §4.3).
   *
   * The failure record lives in the BFF because a native per-waypoint "failed"
   * status is still unconfirmed on the Fleetbase side (§4.3 lists it as
   * to-verify). What we can do today is make it visible to whoever is watching
   * the order in Fleetbase, which is why an attached photo is pushed as a Proof
   * carrying the reason in its remarks.
   *
   * The photo upload is deliberately best-effort: a driver standing at a closed
   * door must be able to record the failure even on a bad connection, so an
   * upload error must not discard the report itself.
   */
  async reportDeliveryFailure(driverId: string, orderId: string, dto: ReportDeliveryFailureDto) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.getOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      throw new BadRequestException('This order is not assigned to you');
    }

    let fleetbaseProofUuid: string | null = null;
    let proofUrl: string | null = null;

    // Tracé explicitement, y compris l'absence : sans cette ligne, « aucune
    // photo envoyée » et « photo envoyée mais rejetée » ne se distinguent que
    // par la présence d'un avertissement — donc pas du tout, dès que les logs
    // ont défilé. Le diagnostic a coûté un aller-retour pour cette raison.
    this.logger.log(
      `Delivery failure report on ${orderId}: photo ${
        dto.photo ? `présente (${Math.round(dto.photo.length / 1024)} ko base64)` : 'absente'
      }`,
    );

    if (dto.photo) {
      try {
        const remarks = `Échec de livraison : ${dto.reason}${dto.notes ? ` — ${dto.notes}` : ''}`;
        const proof = await this.fleetbaseClient.captureOrderPhoto(
          this.orderPublicId(order),
          [dto.photo],
          remarks.slice(0, 255),
          dto.waypointUuid,
        );
        const record = this.extractProof(proof);
        // `uuid` n'est PAS exposé sur l'API publique (voir extractProof) :
        // `id` y porte le public_id, seul identifiant disponible. On garde le
        // premier des deux qui existe — cette référence n'est qu'opaque.
        fleetbaseProofUuid = record?.uuid || record?.id || null;
        proofUrl = record?.url || null;

        // Tracer ce qu'on a réellement su extraire : c'est cette information
        // qui manquait pour comprendre pourquoi un upload réussi ressortait
        // comme « photo non jointe ». Les clés brutes en dernier recours,
        // quand rien n'a été trouvé — la forme de la réponse est alors la
        // seule chose à regarder.
        if (proofUrl || fleetbaseProofUuid) {
          this.logger.log(`Preuve enregistrée : url=${proofUrl ?? '—'} ref=${fleetbaseProofUuid ?? '—'}`);
        } else {
          this.logger.warn(
            `Preuve acceptée par Fleetbase mais illisible dans la réponse. ` +
              `Clés reçues : ${Object.keys(record ?? {}).join(', ') || '(aucune)'}`,
          );
        }
      } catch (error) {
        // `error` d'axios porte le détail utile dans response.data ; le
        // `message` seul dit « Request failed with status code 500 », ce qui
        // n'aide à rien quand c'est justement le serveur amont qui refuse.
        const detail = error?.response?.data
          ? JSON.stringify(error.response.data)
          : error.message;
        this.logger.warn(
          `Delivery failure photo upload failed (${orderId}), keeping the report: ${detail}`,
        );
      }
    }

    const failure = await this.prisma.deliveryFailure.create({
      data: {
        driverId: driver.id,
        fleetbaseOrderUuid: order.uuid || orderId,
        waypointUuid: dto.waypointUuid,
        reason: dto.reason,
        notes: dto.notes,
        fleetbaseProofUuid,
        proofUrl,
      },
    });

    this.logger.log(`Delivery failure reported: order ${orderId}, reason ${dto.reason}`);

    // Le commerçant est prévenu tout de suite, sans attendre le
    // réconciliateur : un échec de livraison ne change pas le statut Fleetbase
    // de la commande (§6.5 — pas de statut « failed » natif confirmé), donc
    // rien d'observable ne le trahirait. C'est aussi la notification la plus
    // urgente des cinq : c'est la seule qui demande au commerçant d'agir.
    await this.notifications.notifyOrderOwner(order.uuid || orderId, {
      type: 'order.failed',
      title: 'Échec de livraison',
      body: `Le transporteur n'a pas pu livrer : ${dto.reason.replace(/_/g, ' ')}.`,
    });

    return {
      id: failure.id,
      reason: failure.reason,
      // Ce qui compte pour l'appelant est que Fleetbase ait bien stocké la
      // photo, pas qu'on ait su en relire tel identifiant : l'URL est le
      // signal fiable, l'identifiant dépend de l'API empruntée.
      photoUploaded: Boolean(proofUrl || fleetbaseProofUuid),
      photoUrl: proofUrl ? `/transporteur/preuves/${failure.id}` : null,
      reportedAt: failure.reportedAt,
    };
  }
}
