import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../database/prisma.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';

@Injectable()
export class CommerçantService {
  private readonly logger = new Logger(CommerçantService.name);

  constructor(
    private prisma: PrismaService,
    private fleetbaseClient: FleetbaseApiClient,
  ) {}

  /**
   * Get merchant's orders
   * TODO: Implement pagination, filtering by status
   */
  async getOrders(merchantId: string) {
    this.logger.log(`Fetching orders for merchant ${merchantId}`);
    // TODO: Implement
    return [];
  }

  /**
   * Get order detail
   */
  async getOrderDetail(merchantId: string, orderId: string) {
    this.logger.log(`Fetching order ${orderId} for merchant ${merchantId}`);
    // TODO: Implement
    return null;
  }

  /**
   * Create order
   */
  async createOrder(merchantId: string, data: any) {
    this.logger.log(`Creating order for merchant ${merchantId}`);
    // TODO: Implement
    return null;
  }

  /**
   * Cancel order
   */
  async cancelOrder(merchantId: string, orderId: string) {
    this.logger.log(`Cancelling order ${orderId} for merchant ${merchantId}`);
    // TODO: Implement
    return null;
  }

  /**
   * Get tracking info for order
   */
  async getOrderTracking(merchantId: string, orderId: string) {
    this.logger.log(`Fetching tracking for order ${orderId}`);
    // TODO: Implement
    return null;
  }

  /**
   * Register device token for push notifications
   */
  async registerDeviceToken(merchantId: string, token: string, platform: string) {
    this.logger.log(`Registering device token for merchant ${merchantId}`);

    return this.prisma.deviceToken.create({
      data: {
        merchantId,
        token,
        platform,
      },
    });
  }

  /**
   * Get merchant's addresses
   */
  async getAddresses(merchantId: string) {
    this.logger.log(`Fetching addresses for merchant ${merchantId}`);
    // TODO: Implement
    return [];
  }

  /**
   * Create/Save address
   */
  async saveAddress(merchantId: string, address: any) {
    this.logger.log(`Saving address for merchant ${merchantId}`);
    // TODO: Implement
    return null;
  }
}
