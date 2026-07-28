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

    if (!failures.length) return orders;

    // Keep the most recent report per order: a driver may retry a delivery
    // and fail again, and only the latest one describes the current state.
    const byOrder = new Map<string, any>();
    for (const f of failures) {
      if (!byOrder.has(f.fleetbaseOrderUuid)) byOrder.set(f.fleetbaseOrderUuid, f);
    }

    return orders.map((order) => {
      const failure = byOrder.get(order?.uuid);
      if (!failure) return order;
      return {
        ...order,
        delivery_failure: {
          id: failure.id,
          reason: failure.reason,
          notes: failure.notes,
          photo_url: null,
          created_at: failure.reportedAt.toISOString(),
        },
      };
    });
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
      const record = await this.findFleetbaseDriver(driver.fleetbaseDriverUuid);
      if (record && record.online !== undefined && record.online !== null) {
        online = Boolean(record.online);
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
      online,
    };
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
      orders = await this.fleetbaseClient.fetchEveryOrder();
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
    if (query.type === 'history') {
      return { orders: await this.attachFailures(driver.id, assigned.filter(isFinished)) };
    }
    if (query.type === 'assigned') {
      return { orders: await this.attachFailures(driver.id, assigned.filter((o) => !isFinished(o))) };
    }

    return {
      active: await this.attachFailures(driver.id, assigned.filter((o) => !isFinished(o))),
      adhoc,
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
      this.logger.warn(`Driver ${driverId} attempted to access order ${orderId}`);
      throw new NotFoundException('Order not found');
    }

    const [withFailure] = await this.attachFailures(driver.id, [order]);
    return withFailure;
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
