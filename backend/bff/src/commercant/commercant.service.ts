import {
  Injectable,
  Logger,
  BadRequestException,
  NotFoundException,
  ForbiddenException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../database/prisma.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { CreateOrderDto, ListOrdersQueryDto } from './dto/create-order.dto';
import { SaveAddressDto } from './dto/address.dto';

@Injectable()
export class CommerçantService {
  private readonly logger = new Logger(CommerçantService.name);

  constructor(
    private prisma: PrismaService,
    private fleetbaseClient: FleetbaseApiClient,
    private configService: ConfigService,
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
      return cached.map((c) => ({ ...c, uuid: c.fleetbaseOrderId, stale: true }));
    }

    const byId = new Map(live.map((o: any) => [o?.uuid, o]));

    return cached.map((c) => {
      const order = byId.get(c.fleetbaseOrderId);
      if (!order) {
        // Order vanished from Fleetbase (deleted, or another organization).
        return { ...c, uuid: c.fleetbaseOrderId, missing: true };
      }
      // Fleetbase order wins on every business field; the local id is kept so
      // the app can still address the row it came from.
      return { ...order, bff_order_id: c.id };
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
      this.logger.warn(`Merchant ${merchantId} attempted to access order ${orderId}`);
      throw new ForbiddenException('You do not have access to this order');
    }

    return order;
  }

  async getOrderDetail(merchantId: string, orderId: string) {
    this.logger.log(`Fetching order ${orderId} for merchant ${merchantId}`);

    await this.getMerchantWithValidation(merchantId);

    const order = await this.resolveOwnedOrder(merchantId, orderId);
    const [merged] = await this.mergeWithFleetbase([order]);
    return { ...merged, commissions: order.commissions };
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

      const response = await this.fleetbaseClient.createOrder({
        order_config_uuid: orderConfigUuid,
        customer_uuid: merchant.fleetbaseVendorUuid,
        customer_type: 'vendor',
        type: 'transport',
        payload: {
          pickup_uuid: pickupPlace.place.uuid,
          dropoff_uuid: dropoffPlace.place.uuid,
        },
        meta: dto.deliveryInstructions ? { instructions: dto.deliveryInstructions } : undefined,
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
