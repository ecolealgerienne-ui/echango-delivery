import {
  Injectable,
  Logger,
  BadRequestException,
  ForbiddenException,
  NotFoundException,
} from '@nestjs/common';
import { PrismaService } from '../database/prisma.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import {
  UpdatePositionDto,
  ToggleOnlineDto,
  UpdateActivityDto,
  ReportDeliveryFailureDto,
  CapturePhotoDto,
  ListDriverOrdersQueryDto,
} from './dto/transporteur.dto';

@Injectable()
export class TransporteurService {
  private readonly logger = new Logger(TransporteurService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly fleetbaseClient: FleetbaseApiClient,
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
   * Resolve the driver's Fleetbase public_id, backfilling it if absent.
   *
   * Accounts registered before the column existed have it null, and
   * POST /v1/orders/{id}/start is the one call that refuses a uuid.
   */
  private async getDriverPublicId(driver: { id: string; fleetbaseDriverUuid: string; fleetbaseDriverPublicId: string | null }) {
    if (driver.fleetbaseDriverPublicId) {
      return driver.fleetbaseDriverPublicId;
    }

    const response = await this.fleetbaseClient.getAllDrivers();
    const drivers = response?.drivers || response?.data || (Array.isArray(response) ? response : []);
    const match = (drivers || []).find((d: any) => d?.uuid === driver.fleetbaseDriverUuid);

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
   * Normalise the various shapes Fleetbase returns a collection in.
   * Confirmed in journal §2.4: responses are not consistently wrapped.
   */
  private extractOrders(response: any): any[] {
    return response?.orders || response?.data || (Array.isArray(response) ? response : []);
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
      const response = await this.fleetbaseClient.getAllOrders();
      orders = this.extractOrders(response);
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

  private isAssignedTo(order: any, driverUuid: string) {
    return (
      order?.driver_assigned_uuid === driverUuid ||
      order?.driver_assigned?.uuid === driverUuid
    );
  }

  async getProfile(driverId: string) {
    const driver = await this.getDriverOrFail(driverId);

    return {
      id: driver.id,
      email: driver.email,
      firstName: driver.firstName,
      lastName: driver.lastName,
      phone: driver.phone,
      fleetbaseDriverUuid: driver.fleetbaseDriverUuid,
    };
  }

  // Note on identifiers below: every /v1 call takes the driver's public_id,
  // never the uuid — see resolveOrder() for why.

  async updatePosition(driverId: string, dto: UpdatePositionDto) {
    const driver = await this.getDriverOrFail(driverId);
    const publicId = await this.getDriverPublicId(driver);

    try {
      await this.fleetbaseClient.trackDriver(publicId, dto);
      return { success: true };
    } catch (error) {
      this.logger.error(`Position update failed for driver ${driverId}: ${error.message}`);
      throw new BadRequestException('Failed to update position');
    }
  }

  async toggleOnline(driverId: string, dto: ToggleOnlineDto) {
    const driver = await this.getDriverOrFail(driverId);
    const publicId = await this.getDriverPublicId(driver);

    try {
      await this.fleetbaseClient.toggleDriverOnline(publicId, dto.online);
      return { online: dto.online };
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
      const response = await this.fleetbaseClient.getAllOrders();
      orders = this.extractOrders(response);
    } catch (error) {
      this.logger.error(`Order list failed for driver ${driverId}: ${error.message}`);
      throw new BadRequestException('Failed to fetch orders');
    }

    const assigned = orders.filter((o) => this.isAssignedTo(o, driver.fleetbaseDriverUuid));

    // Adhoc opportunities: broadcast, not yet claimed by anyone. Fleetbase's
    // geospatial dispatch decides who gets pinged (specs_echango_delivery §3.2);
    // the BFF only avoids showing orders already taken.
    const adhoc = orders.filter(
      (o) => o?.adhoc === true && !o?.driver_assigned_uuid && o?.status !== 'canceled',
    );

    const isFinished = (o: any) => ['completed', 'canceled'].includes(o?.status);

    if (query.type === 'adhoc') return { orders: adhoc };
    if (query.type === 'history') return { orders: assigned.filter(isFinished) };
    if (query.type === 'assigned') return { orders: assigned.filter((o) => !isFinished(o)) };

    return {
      active: assigned.filter((o) => !isFinished(o)),
      adhoc,
      history: assigned.filter(isFinished),
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
      this.logger.warn(`Driver ${driverId} attempted to access order ${orderId}`);
      throw new NotFoundException('Order not found');
    }

    return order;
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

  async completeOrder(driverId: string, orderId: string) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.getOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      throw new BadRequestException('This order is not assigned to you');
    }

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

  async updateActivity(driverId: string, orderId: string, dto: UpdateActivityDto) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.getOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      throw new BadRequestException('This order is not assigned to you');
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
      throw new BadRequestException('Failed to upload proof');
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

    if (dto.photo) {
      try {
        const remarks = `Échec de livraison : ${dto.reason}${dto.notes ? ` — ${dto.notes}` : ''}`;
        const proof = await this.fleetbaseClient.captureOrderPhoto(
          this.orderPublicId(order),
          [dto.photo],
          remarks.slice(0, 255),
          dto.waypointUuid,
        );
        fleetbaseProofUuid = proof?.data?.uuid || proof?.proof?.uuid || null;
      } catch (error) {
        this.logger.warn(
          `Delivery failure photo upload failed (${orderId}), keeping the report: ${error.message}`,
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
      },
    });

    this.logger.log(`Delivery failure reported: order ${orderId}, reason ${dto.reason}`);

    return {
      id: failure.id,
      reason: failure.reason,
      photoUploaded: Boolean(fleetbaseProofUuid),
      reportedAt: failure.reportedAt,
    };
  }
}
