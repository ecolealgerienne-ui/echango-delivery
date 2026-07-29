import {
  Injectable,
  Logger,
  BadRequestException,
  NotFoundException,
  ForbiddenException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../database/prisma.service';
import { AuditService } from '../common/audit/audit.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { CreateOrderDto, ListOrdersQueryDto } from './dto/create-order.dto';
import { SaveAddressDto } from './dto/address.dto';
import { QuoteRequestDto } from './dto/quote.dto';
import { projectOrderForMerchant } from '../common/projections/order.projection';
import { PricingService } from '../common/pricing/pricing.service';

@Injectable()
export class CommerçantService {
  private readonly logger = new Logger(CommerçantService.name);

  constructor(
    private prisma: PrismaService,
    private fleetbaseClient: FleetbaseApiClient,
    private configService: ConfigService,
    private audit: AuditService,
    private pricing: PricingService,
  ) {}

  /**
   * Get merchant's orders from Fleetbase via customer-portal-api
   */
  /**
   * Merge the merchant's cached order rows with their live Fleetbase state.
   *
   * The cache alone is not enough to show anything useful: it stores an id, a
   * tracking number and a status frozen at 'pending' on creation that nothing
   * ever resynchronises — so a merchant would watch a delivery that never
   * appears to progress, and would see neither addresses nor courier.
   *
   * The cache keeps the job it is actually good at: recording which orders
   * belong to which merchant. That mapping is what makes the anti-IDOR check
   * trustworthy, and it must stay authoritative — §2.8 established that
   * Fleetbase silently ignores unsupported filters on /orders, so asking it
   * "which orders are this merchant's" would return the whole company.
   */
  private async mergeWithFleetbase(cached: { id: string; fleetbaseOrderId: string }[]) {
    if (!cached.length) return [];

    let live: any[] = [];
    try {
      live = await this.fleetbaseClient.fetchEveryOrder();
    } catch (error) {
      // Degrade rather than fail: without Fleetbase the merchant still sees
      // that the order exists, just not how far along it is.
      this.logger.warn(`Fleetbase unreachable, serving cached orders only: ${error.message}`);
      // Repli dégradé : seuls l'identifiant et le drapeau sortent. Étendre la
      // ligne Prisma exposait `merchantId` et les colonnes internes du cache.
      return cached.map((c) => ({
        uuid: c.fleetbaseOrderId,
        bff_order_id: c.id,
        stale: true,
      }));
    }

    const byId = new Map(live.map((o: any) => [o?.uuid, o]));

    return cached.map((c) => {
      const order = byId.get(c.fleetbaseOrderId);
      if (!order) {
        // Order vanished from Fleetbase (deleted, or another organization).
        return { uuid: c.fleetbaseOrderId, bff_order_id: c.id, missing: true };
      }
      // Projection en liste d'autorisation : le BFF décide de ce qui sort, et
      // non Fleetbase (revue M10). L'identifiant local est conservé pour que
      // l'app puisse encore adresser la ligne dont il provient.
      return projectOrderForMerchant(order, { bff_order_id: c.id });
    });
  }

  async getOrders(merchantId: string, query: ListOrdersQueryDto) {
    this.logger.log(`Fetching orders for merchant ${merchantId}`);

    await this.getMerchantWithValidation(merchantId);

    try {
      const page = query.page || 1;
      const limit = query.limit || 25;

      const cached = await this.prisma.order.findMany({
        where: { merchantId },
        skip: (page - 1) * limit,
        take: limit,
        orderBy: { createdAt: 'desc' },
      });

      const orders = await this.mergeWithFleetbase(cached);
      const total = await this.prisma.order.count({ where: { merchantId } });

      // `status` is filtered here rather than in the query: the cached status
      // is stale, so only the merged result knows the real one.
      const filtered = query.status
        ? orders.filter((o: any) => o?.status === query.status)
        : orders;

      return {
        orders: filtered,
        pagination: { page, limit, total, pages: Math.ceil(total / limit) },
      };
    } catch (error) {
      this.logger.error(`Failed to fetch orders: ${error.message}`);
      throw new BadRequestException('Failed to fetch orders');
    }
  }

  /**
   * Rayon de diffusion d'une course adhoc, en mètres.
   *
   * Fleetbase porte nativement `adhoc_distance` : inutile de reconstruire un
   * filtre de proximité côté BFF, c'est son dispatch géospatial qui l'applique.
   *
   * ⚠️ La valeur par défaut est un **repli, pas une décision produit** : 15 km
   * couvre une agglomération sans noyer les transporteurs de courses hors de
   * portée. À régler au pilote, avec de vraies distances.
   */
  private adhocRadiusMetres(): number {
    const configured = Number(this.configService.get('ADHOC_RADIUS_METRES'));
    return Number.isFinite(configured) && configured > 0 ? configured : 15000;
  }

  /**
   * Métadonnées transmises à Fleetbase.
   *
   * `vehicle_type` y vit plutôt que dans une colonne native : Fleetbase n'a pas
   * de notion de *catégorie* de véhicule — `vehicle_assigned_uuid` désigne un
   * véhicule précis. Le filtrage est donc appliqué par le BFF au moment de
   * lister les opportunités d'un transporteur.
   */
  private buildOrderMeta(dto: CreateOrderDto): Record<string, any> | undefined {
    const meta: Record<string, any> = {};
    if (dto.deliveryInstructions) meta.instructions = dto.deliveryInstructions;
    if (dto.vehicleType) meta.vehicle_type = dto.vehicleType;
    if (dto.items?.length) meta.items = dto.items;
    if (dto.pickupNotes) meta.pickup_notes = dto.pickupNotes;
    if (dto.dropoffNotes) meta.dropoff_notes = dto.dropoffNotes;

    // Le devis est demandé sur TOUTE commande, même quand le commerçant a
    // saisi son montant : ce qui est enregistré au passage — distance, horaire,
    // catégorie de véhicule — sont les entrées de la future formule de calcul.
    // Elles ne sont pas rattrapables après coup : la distance dépend du
    // géocodage et du réseau routier du moment, et une commande rejouée plus
    // tard ne donnerait pas le même chiffre. Sans elles, les courses du pilote
    // ne serviront pas à calibrer le barème.
    const quote = this.pricing.quote(
      {
        pickupLatitude: dto.pickupLatitude,
        pickupLongitude: dto.pickupLongitude,
        dropoffLatitude: dto.dropoffLatitude,
        dropoffLongitude: dto.dropoffLongitude,
        scheduledAt: dto.scheduledAt,
        vehicleType: dto.vehicleType,
      },
      dto.price,
    );

    meta.pricing_inputs = quote.inputs;

    if (quote.amount !== null) {
      meta.price = quote.amount;
      meta.currency = quote.currency;
      // L'origine du montant est enregistrée AVEC lui. Sans elle, l'historique
      // mélangerait prix proposés et prix calculés, et la calibration de la
      // future formule se ferait sur ses propres résultats.
      meta.price_source = quote.source;
    }

    return Object.keys(meta).length ? meta : undefined;
  }

  /**
   * Premier transporteur favori actuellement en ligne, ou `null`.
   *
   * ── Ce que fait ce repli, et ce qu'il ne fait pas ──────────────────────────
   *
   * Il choisit **au moment de la création** : si aucun favori n'est en ligne,
   * la course part immédiatement au pool commun. C'est ce qui préserve l'effet
   * réseau (voir DriverFavourite dans le schéma).
   *
   * Ce qu'il ne fait PAS : reprendre la course si le favori ne l'accepte
   * jamais. Ce second repli, différé dans le temps, demande une tâche de fond
   * surveillant les courses assignées et non démarrées — à construire, avec le
   * délai comme décision produit. En attendant, une course confiée à un favori
   * qui l'ignore reste bloquée : c'est la limite à connaître avant d'activer
   * l'option en production.
   */
  private async pickAvailableFavourite(merchantId: string, vehicleType?: string) {
    const favourites = await this.prisma.driverFavourite.findMany({
      where: { merchantId },
    });
    if (!favourites.length) return null;

    const uuids = favourites.map((f: any) => f.fleetbaseDriverUuid);

    // Le compte Echango porte la catégorie de véhicule et sert de garde : un
    // favori sans compte applicatif ne peut de toute façon pas recevoir la
    // course, faute de jeton push et d'application.
    const accounts = await this.prisma.driverAccount.findMany({
      where: {
        fleetbaseDriverUuid: { in: uuids },
        active: true,
        // Non déclaré = compatible : un transporteur ne doit pas être écarté
        // du réseau par un champ qu'il n'a pas rempli.
        ...(vehicleType
          ? {
              OR: [
                { vehicleType: null },
                { vehicleType: this.compatibleVehicleTypes(vehicleType) },
              ],
            }
          : {}),
      },
    });
    if (!accounts.length) return null;

    // La disponibilité fait foi côté Fleetbase, pas côté BFF : c'est lui qui
    // décide à qui le dispatch parle.
    let drivers: any[] = [];
    try {
      const response = await this.fleetbaseClient.getAllDrivers();
      drivers = this.fleetbaseClient.extractCollection(response, 'drivers');
    } catch (error) {
      this.logger.warn(`Favoris non résolus, repli sur le pool : ${error.message}`);
      return null;
    }

    const online = new Set(
      drivers.filter((d: any) => d?.online === true).map((d: any) => d.uuid),
    );

    return accounts.find((a: any) => online.has(a.fleetbaseDriverUuid)) ?? null;
  }

  /**
   * Catégories acceptables pour une exigence donnée.
   *
   * Une exigence est un **minimum**, pas une égalité : demander une voiture
   * n'exclut pas un utilitaire. Traiter le champ comme une égalité stricte
   * écarterait des transporteurs parfaitement capables.
   */
  private compatibleVehicleTypes(required: string): { in: string[] } {
    const ladder = ['moto', 'voiture', 'utilitaire'];
    const index = ladder.indexOf(required);
    return { in: index < 0 ? ladder : ladder.slice(index) };
  }

  /**
   * Devis d'une course, avant sa création.
   *
   * ── Pourquoi cet endpoint existe alors qu'aucune formule n'est écrite ───────
   *
   * Pour que l'appel soit **déjà en place** le jour où le barème sera tranché :
   * l'app interroge, affiche ce qu'on lui répond, et n'aura pas à changer.
   * Aujourd'hui `amount` vaut `null` et l'app garde sa saisie manuelle ; demain
   * il portera un montant calculé et la saisie s'effacera d'elle-même.
   *
   * Poser la couture avant la formule évite le scénario habituel : un barème
   * décidé, puis trois semaines à recâbler les écrans pour l'afficher.
   *
   * Les entrées retenues sont renvoyées avec le devis — distance, horaire — pour
   * que le commerçant voie sur quoi le montant repose, et pas seulement le
   * montant.
   */
  async quoteOrder(merchantId: string, dto: QuoteRequestDto) {
    await this.getMerchantWithValidation(merchantId);

    const quote = this.pricing.quote({
      pickupLatitude: dto.pickupLatitude,
      pickupLongitude: dto.pickupLongitude,
      dropoffLatitude: dto.dropoffLatitude,
      dropoffLongitude: dto.dropoffLongitude,
      scheduledAt: dto.scheduledAt,
      vehicleType: dto.vehicleType,
    });

    return {
      amount: quote.amount,
      currency: quote.currency,
      source: quote.source,
      distanceMetres: quote.inputs.distance_metres,
      distanceMethod: quote.inputs.distance_method,
    };
  }

  // ── Transporteurs favoris ─────────────────────────────────────────────────

  async listFavourites(merchantId: string) {
    await this.getMerchantWithValidation(merchantId);
    const favourites = await this.prisma.driverFavourite.findMany({
      where: { merchantId },
      orderBy: { createdAt: 'desc' },
    });
    return {
      data: favourites.map((f: any) => ({
        id: f.id,
        driver_uuid: f.fleetbaseDriverUuid,
        name: f.driverName,
      })),
    };
  }

  /**
   * Transporteurs proposables en favori : ceux qui ont déjà livré pour ce
   * commerçant.
   *
   * Volontairement restreint à l'historique plutôt qu'à l'annuaire complet de
   * l'organisation. Exposer tous les transporteurs à tous les commerçants
   * livrerait la composition du réseau à quiconque crée un compte, et n'a
   * aucune utilité : on ne met en favori que quelqu'un qu'on a vu travailler.
   */
  async listKnownDrivers(merchantId: string) {
    await this.getMerchantWithValidation(merchantId);

    const cached = await this.prisma.order.findMany({
      where: { merchantId },
      select: { fleetbaseOrderId: true },
    });
    const owned = new Set(cached.map((c: any) => c.fleetbaseOrderId));
    if (!owned.size) return { data: [] };

    let orders: any[] = [];
    try {
      orders = await this.fleetbaseClient.fetchEveryOrder();
    } catch (error) {
      this.logger.warn(`Historique transporteurs indisponible : ${error.message}`);
      return { data: [] };
    }

    const seen = new Map<string, string | null>();
    for (const order of orders) {
      if (!owned.has(order?.uuid)) continue;
      const uuid = order?.driver_assigned_uuid ?? order?.driver_assigned?.uuid;
      if (uuid && !seen.has(uuid)) {
        seen.set(uuid, order?.driver_assigned?.name ?? null);
      }
    }

    return {
      data: Array.from(seen.entries()).map(([uuid, name]) => ({
        driver_uuid: uuid,
        name,
      })),
    };
  }

  async addFavourite(merchantId: string, fleetbaseDriverUuid: string, driverName?: string) {
    await this.getMerchantWithValidation(merchantId);

    // Un commerçant ne met en favori qu'un transporteur qui a déjà travaillé
    // pour lui : sans ce contrôle, l'endpoint permettrait de sonder l'existence
    // d'un uuid arbitraire.
    const known = await this.listKnownDrivers(merchantId);
    if (!known.data.some((d: any) => d.driver_uuid === fleetbaseDriverUuid)) {
      this.audit.denied({
        actorType: 'merchant',
        actorId: merchantId,
        action: 'favourite.add',
        resourceType: 'Driver',
        resourceId: fleetbaseDriverUuid,
        reason: "Transporteur n'ayant jamais livré pour ce commerçant",
      });
      throw new BadRequestException(
        "Vous ne pouvez mettre en favori qu'un transporteur ayant déjà effectué une de vos livraisons",
      );
    }

    return this.prisma.driverFavourite.upsert({
      where: { merchantId_fleetbaseDriverUuid: { merchantId, fleetbaseDriverUuid } },
      create: { merchantId, fleetbaseDriverUuid, driverName },
      update: { driverName },
    });
  }

  async removeFavourite(merchantId: string, favouriteId: string) {
    await this.getMerchantWithValidation(merchantId);

    // `deleteMany` avec le merchantId dans le filtre : un `delete` par id seul
    // permettrait de supprimer le favori d'un autre commerçant.
    const { count } = await this.prisma.driverFavourite.deleteMany({
      where: { id: favouriteId, merchantId },
    });

    if (count === 0) {
      throw new NotFoundException('Favori introuvable');
    }
    return { removed: true };
  }

  /**
   * Résout une commande du commerçant par l'un OU l'autre de ses identifiants,
   * et vérifie l'appartenance.
   *
   * ⚠️ Deux identifiants coexistent : le `cuid` local (renvoyé à la création)
   * et l'`uuid` Fleetbase (présent partout ailleurs). L'app envoie l'uuid, or
   * `cancelOrder` et `getOrderTracking` cherchaient le cuid — les deux
   * répondaient donc **404 systématiquement**, et le suivi échouait en
   * silence côté client (revue archi #3). `getOrderDetail` faisait déjà la
   * bonne chose ; ce helper évite que les trois divergent à nouveau.
   *
   * L'appartenance est décidée **ici**, sur la table locale, jamais sur ce que
   * renvoie Fleetbase : §2.8 a établi que Fleetbase ignore silencieusement les
   * filtres non supportés, donc lui demander « quelles commandes sont à ce
   * commerçant » renverrait toute la compagnie.
   */
  private async resolveOwnedOrder(merchantId: string, orderId: string) {
    const order = await this.prisma.order.findFirst({
      where: { OR: [{ id: orderId }, { fleetbaseOrderId: orderId }] },
      include: { commissions: true },
    });

    if (!order) {
      throw new NotFoundException('Order not found');
    }

    if (order.merchantId !== merchantId) {
      this.audit.denied({
        actorType: 'merchant',
        actorId: merchantId,
        action: 'order.access',
        resourceType: 'Order',
        resourceId: orderId,
        reason: 'Commande appartenant à un autre commerçant',
      });
      throw new ForbiddenException('You do not have access to this order');
    }

    return order;
  }

  async getOrderDetail(merchantId: string, orderId: string) {
    this.logger.log(`Fetching order ${orderId} for merchant ${merchantId}`);

    await this.getMerchantWithValidation(merchantId);

    const order = await this.resolveOwnedOrder(merchantId, orderId);
    const [merged] = await this.mergeWithFleetbase([order]);
    // Les commissions ne sont PAS renvoyées : ce sont des données de
    // facturation interne, sans usage dans l'app commerçant, et
    // `include: { commissions: true }` les exposait au client (revue M10).
    return merged;
  }



  /**
   * Create a new delivery order
   */
  async createOrder(merchantId: string, dto: CreateOrderDto) {
    this.logger.log(`Creating order for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      // Fleetbase orders require pre-created Place records for pickup/dropoff,
      // referenced by UUID, plus a resolved order_config_uuid.
      const [pickupPlace, dropoffPlace, orderConfigUuid] = await Promise.all([
        this.fleetbaseClient.createPlace(dto.pickupLocationName, dto.pickupLatitude, dto.pickupLongitude),
        this.fleetbaseClient.createPlace(dto.dropoffLocationName, dto.dropoffLatitude, dto.dropoffLongitude),
        this.fleetbaseClient.getDefaultOrderConfigUuid(),
      ]);

      // Favori disponible ? On le sollicite ; sinon la course part au pool.
      const favourite = dto.preferFavourites
        ? await this.pickAvailableFavourite(merchantId, dto.vehicleType)
        : null;

      const response = await this.fleetbaseClient.createOrder({
        order_config_uuid: orderConfigUuid,
        customer_uuid: merchant.fleetbaseVendorUuid,
        customer_type: 'vendor',
        type: 'transport',
        payload: {
          pickup_uuid: pickupPlace.place.uuid,
          dropoff_uuid: dropoffPlace.place.uuid,
        },
        meta: this.buildOrderMeta(dto),
        scheduled_at: dto.scheduledAt,
        ...(favourite
          ? { driver_assigned_uuid: favourite.fleetbaseDriverUuid }
          : { adhoc: true, adhoc_distance: this.adhocRadiusMetres() }),
        pod_required: dto.podMethod ? dto.podMethod !== 'aucune' : undefined,
        pod_method: dto.podMethod && dto.podMethod !== 'aucune' ? dto.podMethod : undefined,
      });

      const fleetbaseOrder = response.order;
      const fleetbaseOrderId = fleetbaseOrder?.uuid || fleetbaseOrder?.id;

      // Cache order in BFF database
      const order = await this.prisma.order.create({
        data: {
          merchantId,
          fleetbaseOrderId,
          status: 'pending',
          trackingNumber: fleetbaseOrder?.tracking_number?.tracking_number,
        },
      });

      if (favourite) {
        this.logger.log(
          `Commande ${order.id} confiée au favori ${favourite.fleetbaseDriverUuid}`,
        );
      }

      this.logger.log(`Order created: ${order.id}`);

      return order;
    } catch (error) {
      this.logger.error(`Failed to create order: ${error.message}`, error);
      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      throw new BadRequestException(
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to create order: ${detail}`
          : 'Failed to create order',
      );
    }
  }

  /**
   * Cancel an order
   */
  async cancelOrder(merchantId: string, orderId: string) {
    this.logger.log(`Cancelling order ${orderId}`);

    await this.getMerchantWithValidation(merchantId);

    const order = await this.resolveOwnedOrder(merchantId, orderId);

    // Le garde de transition lit l'état RÉEL chez Fleetbase, pas le champ
    // `status` du cache — celui-ci est figé à 'pending' depuis la création et
    // n'est jamais resynchronisé (revue archi #15). S'y fier laissait annuler
    // une commande déjà livrée.
    const [live] = await this.mergeWithFleetbase([order]);
    const liveStatus = (live as any)?.status ?? null;

    if (liveStatus && ['completed', 'canceled', 'cancelled'].includes(liveStatus)) {
      throw new BadRequestException(`Commande déjà ${liveStatus}, annulation impossible`);
    }

    // Annuler pendant qu'un transporteur est en route est une décision qui
    // engage : le driver peut être devant la porte. Le refus par défaut protège
    // les deux parties tant que la règle métier n'est pas tranchée
    // (specs_echango_delivery.md §6) ; l'opérateur, lui, peut toujours annuler
    // depuis la console Fleetbase.
    if (liveStatus && ['started', 'enroute'].includes(liveStatus)) {
      throw new BadRequestException(
        'Le transporteur est déjà en route. Contactez Echango pour annuler cette livraison.',
      );
    }

    try {
      await this.fleetbaseClient.cancelOrder(order.fleetbaseOrderId);

      const updated = await this.prisma.order.update({
        where: { id: order.id },
        data: { status: 'cancelled' },
      });

      this.logger.log(`Order cancelled: ${order.id}`);
      return updated;
    } catch (error) {
      if (error instanceof BadRequestException) throw error;
      this.logger.error(`Failed to cancel order: ${error.message}`);
      throw new BadRequestException('Failed to cancel order');
    }
  }


  /**
   * Get secure tracking info for an order
   */
  async getOrderTracking(merchantId: string, orderId: string) {
    this.logger.log(`Fetching tracking for order ${orderId}`);

    await this.getMerchantWithValidation(merchantId);

    const order = await this.resolveOwnedOrder(merchantId, orderId);

    try {
      const [live] = await this.mergeWithFleetbase([order]);
      return {
        id: order.id,
        // Statut issu de Fleetbase, pas du cache : c'est tout l'objet du suivi.
        status: (live as any)?.status ?? null,
        trackingNumber: order.trackingNumber,
        fleetbaseData: live,
      };
    } catch (error) {
      this.logger.error(`Failed to fetch tracking: ${error.message}`);
      throw new BadRequestException('Failed to fetch tracking information');
    }
  }


  /**
   * Get merchant's saved addresses, stored as Fleetbase Places owned by
   * their Vendor (owner_uuid), scoped server-side via GET /places?owner_uuid=...
   */
  async getAddresses(merchantId: string) {
    this.logger.log(`Fetching addresses for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      const response = await this.fleetbaseClient.getOwnedPlaces(merchant.fleetbaseVendorUuid);
      return { data: response?.places || [] };
    } catch (error) {
      this.logger.error(`Failed to fetch addresses: ${error.message}`);
      return { data: [] };
    }
  }

  /**
   * Save a new address as a Fleetbase Place owned by the merchant's Vendor.
   */
  async saveAddress(merchantId: string, dto: SaveAddressDto) {
    this.logger.log(`Saving address for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      const response = await this.fleetbaseClient.createOwnedPlace(merchant.fleetbaseVendorUuid, {
        name: dto.name,
        latitude: dto.latitude,
        longitude: dto.longitude,
        address: dto.address,
        phone: dto.contactPhone,
        meta: {
          label: dto.label,
          contactName: dto.contactName,
          notes: dto.notes,
        },
      });

      this.logger.log(`Address saved: ${response?.place?.uuid}`);
      return response.place;
    } catch (error) {
      this.logger.error(`Failed to save address: ${error.message}`);
      throw new BadRequestException('Failed to save address');
    }
  }

  /**
   * Helper: Get merchant and validate
   */
  private async getMerchantWithValidation(merchantId: string) {
    const merchant = await this.prisma.merchantAccount.findUnique({
      where: { id: merchantId },
    });

    if (!merchant) {
      throw new NotFoundException('Merchant not found');
    }

    if (!merchant.active) {
      throw new ForbiddenException('Merchant account is inactive');
    }

    return merchant;
  }
}
