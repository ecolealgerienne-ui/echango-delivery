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
import { ListFleetOrdersQueryDto } from './dto/order.dto';
import { AddDriverDto } from './dto/driver.dto';

@Injectable()
export class FlotteService {
  private readonly logger = new Logger(FlotteService.name);

  constructor(
    private prisma: PrismaService,
    private fleetbaseClient: FleetbaseApiClient,
    private configService: ConfigService,
  ) {}

  /**
   * List orders belonging to this fleet's Vendor.
   *
   * Fleetbase's `facilitator_uuid` query filter on GET /orders is silently
   * ignored server-side (confirmed by direct testing, see
   * docs/journal_implementation_bff.md §2.8) - it returns the full
   * company-wide dataset regardless of the value passed. We therefore fetch
   * everything and filter/paginate in memory; the query param is never sent.
   */
  async getOrders(fleetId: string, query: ListFleetOrdersQueryDto) {
    const fleet = await this.getFleetWithValidation(fleetId);

    try {
      const allOrders = await this.fetchAllOrders();

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
        data: paged,
        pagination: {
          page,
          limit,
          total,
          pages: Math.ceil(total / limit),
        },
      };
    } catch (error) {
      this.logger.error(`Failed to fetch fleet orders: ${error.message}`);
      throw new BadRequestException('Failed to fetch orders');
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
        throw new NotFoundException('Order not found');
      }

      if (order.facilitator_uuid !== fleet.fleetbaseVendorUuid) {
        throw new ForbiddenException('You do not have access to this order');
      }

      return order;
    } catch (error) {
      if (error instanceof NotFoundException || error instanceof ForbiddenException) {
        throw error;
      }
      this.logger.error(`Failed to fetch order ${orderId}: ${error.message}`);
      throw new NotFoundException('Order not found');
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
      return { data: owned };
    } catch (error) {
      this.logger.error(`Failed to fetch fleet drivers: ${error.message}`);
      throw new BadRequestException('Failed to fetch drivers');
    }
  }

  /**
   * Get positions for this fleet's drivers only.
   *
   * Fleetbase's /positions endpoint has no per-driver query filter at all
   * (confirmed by reading PositionFilter.php, see
   * docs/journal_implementation_bff.md §2.9) - only free-text `query` and
   * `createdAt` are supported, plus automatic company-wide scoping. So we
   * fetch every company Position and filter in memory, same pattern as
   * orders/drivers: first by this fleet's owned driver UUIDs, then further
   * by the caller's requested subset if any.
   */
  async getDriverPositions(fleetId: string, requestedDriverIds: string[]) {
    const fleet = await this.getFleetWithValidation(fleetId);

    try {
      const owned = await this.fetchOwnedDrivers(fleet.fleetbaseVendorUuid);
      const ownedUuids = new Set(owned.map((d: any) => d.uuid));

      const targetIds =
        requestedDriverIds && requestedDriverIds.length > 0
          ? requestedDriverIds.filter((id) => ownedUuids.has(id))
          : (Array.from(ownedUuids) as string[]);

      if (targetIds.length === 0) {
        return [];
      }

      const response = await this.fleetbaseClient.getAllPositions();
      const positions = response?.positions || response?.data || [];
      const targetSet = new Set(targetIds);

      // Field name (subject_uuid vs driver_uuid) is a best-effort guess: the
      // company has zero Position rows in this dev instance, so there is no
      // real record to check the shape against yet. Re-verify once a driver
      // has actually sent a location ping.
      return (Array.isArray(positions) ? positions : []).filter((p: any) =>
        targetSet.has(p?.subject_uuid || p?.driver_uuid),
      );
    } catch (error) {
      this.logger.error(`Failed to fetch driver positions: ${error.message}`);
      throw new BadRequestException('Failed to fetch driver positions');
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
      throw new BadRequestException(
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
      throw new ForbiddenException('You do not have access to this driver');
    }

    try {
      const response = await this.fleetbaseClient.assignOrderToDriver(driverId, orderId);
      this.logger.log(`Order ${orderId} assigned to driver ${driverId}`);
      return response;
    } catch (error) {
      this.logger.error(`Failed to assign driver: ${error.message}`);
      throw new BadRequestException('Failed to assign driver');
    }
  }

  /**
   * Fetch every order in the company, across pages, since the
   * facilitator_uuid filter cannot be trusted server-side. Capped to avoid
   * an unbounded loop against a much larger dataset than expected today.
   */
  private async fetchAllOrders(): Promise<any[]> {
    const pageSize = 100;
    const maxPages = 50;
    const all: any[] = [];

    for (let page = 1; page <= maxPages; page++) {
      const response = await this.fleetbaseClient.getAllOrders(page, pageSize);
      const orders = response?.orders || response?.data || (Array.isArray(response) ? response : []);

      if (!orders || orders.length === 0) {
        break;
      }

      all.push(...orders);

      if (orders.length < pageSize) {
        break;
      }

      if (page === maxPages) {
        this.logger.warn(`fetchAllOrders hit the ${maxPages}-page safety cap - results may be incomplete`);
      }
    }

    return all;
  }

  private async fetchOwnedDrivers(vendorUuid: string): Promise<any[]> {
    const response = await this.fleetbaseClient.getAllDrivers();
    const drivers = response?.drivers || response?.data || (Array.isArray(response) ? response : []);
    return (drivers || []).filter((d: any) => d?.vendor_uuid === vendorUuid);
  }

  private async getFleetWithValidation(fleetId: string) {
    const fleet = await this.prisma.fleetAccount.findUnique({
      where: { id: fleetId },
    });

    if (!fleet) {
      throw new NotFoundException('Fleet account not found');
    }

    if (!fleet.active) {
      throw new ForbiddenException('Fleet account is inactive');
    }

    return fleet;
  }
}
