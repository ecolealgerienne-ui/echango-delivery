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
  async getOrders(merchantId: string, query: ListOrdersQueryDto) {
    this.logger.log(`Fetching orders for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      const page = query.page || 1;
      const limit = query.limit || 25;

      // Call customer-portal-api if merchant has a token
      // For now, return cached orders from BFF database
      const orders = await this.prisma.order.findMany({
        where: {
          merchantId,
          ...(query.status && { status: query.status }),
        },
        skip: (page - 1) * limit,
        take: limit,
        orderBy: { createdAt: 'desc' },
      });

      const total = await this.prisma.order.count({
        where: {
          merchantId,
          ...(query.status && { status: query.status }),
        },
      });

      return {
        data: orders,
        pagination: {
          page,
          limit,
          total,
          pages: Math.ceil(total / limit),
        },
      };
    } catch (error) {
      this.logger.error(`Failed to fetch orders: ${error.message}`);
      throw new BadRequestException('Failed to fetch orders');
    }
  }

  /**
   * Get single order detail with full information
   */
  async getOrderDetail(merchantId: string, orderId: string) {
    this.logger.log(`Fetching order ${orderId} for merchant ${merchantId}`);

    await this.getMerchantWithValidation(merchantId);

    const order = await this.prisma.order.findUnique({
      where: { id: orderId },
      include: {
        commissions: true,
      },
    });

    if (!order) {
      throw new NotFoundException('Order not found');
    }

    // Anti-IDOR: Verify merchant owns this order
    if (order.merchantId !== merchantId) {
      throw new ForbiddenException('You do not have access to this order');
    }

    return order;
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
        customer: merchant.fleetbaseVendorUuid,
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

    const order = await this.prisma.order.findUnique({
      where: { id: orderId },
    });

    if (!order) {
      throw new NotFoundException('Order not found');
    }

    if (order.merchantId !== merchantId) {
      throw new ForbiddenException('You do not have access to this order');
    }

    if (['completed', 'cancelled', 'failed'].includes(order.status)) {
      throw new BadRequestException(`Cannot cancel order with status: ${order.status}`);
    }

    try {
      // Cancel in Fleetbase
      await this.fleetbaseClient.cancelOrder(order.fleetbaseOrderId);

      // Update local cache
      const updated = await this.prisma.order.update({
        where: { id: orderId },
        data: { status: 'cancelled' },
      });

      this.logger.log(`Order cancelled: ${orderId}`);
      return updated;
    } catch (error) {
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

    const order = await this.prisma.order.findUnique({
      where: { id: orderId },
    });

    if (!order) {
      throw new NotFoundException('Order not found');
    }

    if (order.merchantId !== merchantId) {
      throw new ForbiddenException('You do not have access to this order');
    }

    try {
      // Fetch latest data from Fleetbase
      const response = await this.fleetbaseClient.callFleetOps(
        'GET',
        `/orders/${order.fleetbaseOrderId}`,
      );

      return {
        id: order.id,
        status: order.status,
        trackingNumber: order.trackingNumber,
        fleetbaseData: response.data,
      };
    } catch (error) {
      this.logger.error(`Failed to fetch tracking: ${error.message}`);
      throw new BadRequestException('Failed to fetch tracking information');
    }
  }

  /**
   * Get merchant's saved addresses from Fleetbase address-book
   */
  async getAddresses(merchantId: string) {
    this.logger.log(`Fetching addresses for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      // Call Fleetbase to get address-book entries for this vendor
      const response = await this.fleetbaseClient.callFleetOps('GET', '/addresses', undefined, {
        vendor_uuid: merchant.fleetbaseVendorUuid,
        limit: 100,
      });

      return {
        data: response.data || [],
      };
    } catch (error) {
      this.logger.error(`Failed to fetch addresses: ${error.message}`);
      // Return empty list if Fleetbase call fails
      return { data: [] };
    }
  }

  /**
   * Save a new address to merchant's address-book
   */
  async saveAddress(merchantId: string, dto: SaveAddressDto) {
    this.logger.log(`Saving address for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      // Create address in Fleetbase
      const payload = {
        vendor_uuid: merchant.fleetbaseVendorUuid,
        name: dto.name,
        address: dto.address,
        latitude: dto.latitude,
        longitude: dto.longitude,
        contact_name: dto.contactName,
        contact_phone: dto.contactPhone,
        notes: dto.notes,
        meta: {
          label: dto.label,
        },
      };

      const response = await this.fleetbaseClient.callFleetOps('POST', '/addresses', payload);

      this.logger.log(`Address saved: ${response.data?.id}`);
      return response.data;
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
