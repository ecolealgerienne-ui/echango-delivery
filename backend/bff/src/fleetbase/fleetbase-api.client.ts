import { Injectable, Logger } from '@nestjs/common';
import axios, { AxiosInstance } from 'axios';

@Injectable()
export class FleetbaseApiClient {
  private readonly logger = new Logger(FleetbaseApiClient.name);
  private readonly apiClient: AxiosInstance;

  constructor() {
    const baseURL = process.env.FLEETBASE_API_URL || 'http://localhost:8000';
    const apiKey = process.env.FLEETBASE_API_KEY;

    this.apiClient = axios.create({
      baseURL,
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      timeout: 30000,
    });

    this.apiClient.interceptors.response.use(
      (response) => response,
      (error) => {
        if (error.response) {
          this.logger.error(
            `Fleetbase API error: ${error.response.status} ${error.config?.method?.toUpperCase()} ${error.config?.url} - ${JSON.stringify(error.response.data)}`,
          );
        } else {
          this.logger.error(`Fleetbase API error: ${error.message}`);
        }
        throw error;
      },
    );
  }

  /**
   * Call Fleetbase customer-portal-api endpoint
   * Used for merchant operations (read/write orders, etc.)
   */
  async callCustomerPortal(method: string, path: string, data?: any, token?: string, params?: any) {
    const headers = token ? { 'Authorization': `Bearer ${token}` } : {};
    return this.apiClient({
      method,
      url: `/customer-portal/int/v1${path}`,
      data,
      params,
      headers,
    });
  }


  /**
   * Encode un identifiant destiné à un segment d'URL Fleetbase.
   *
   * ⚠️ Sans ça, un identifiant contrôlé par le client détourne la requête vers
   * une autre route, exécutée avec le token de service qui a tous les droits
   * sur l'organisation (revue E3/M8). Exemple réel :
   * `subjectId = "../../ORDER_X/cancel"` transforme
   * `/v1/orders/ORDER_A/capture-photo/<subjectId>` en
   * `/v1/orders/ORDER_X/cancel` après normalisation par le serveur amont — le
   * contrôle d'appartenance ayant porté sur ORDER_A.
   *
   * Deux barrières, volontairement redondantes : les DTO valident le format en
   * entrée, et cette fonction ré-encode à la sortie. Une seule des deux
   * suffirait aujourd'hui ; les deux garantissent qu'un nouvel appelant qui
   * oublierait la validation ne rouvre pas la faille.
   */
  private seg(value: string): string {
    return encodeURIComponent(value);
  }

  /**
   * Call the PUBLIC FleetOps API (`/v1`, middleware `fleetbase.api`) as
   * opposed to the internal one (`/int/v1`, middleware `fleetbase.protected`).
   *
   * Why this exists (verified 28/07/2026 by reading fleetbase/fleetops
   * server/src/routes.php and fleetbase/core-api CoreServiceProvider): the
   * driver-critical operations simply DO NOT EXIST on `int/v1`. Order activity
   * updates, start, proof capture, driver tracking and the online toggle are
   * only declared under the `v1` group. `int/v1` only carries bulk/dispatch
   * variants aimed at the console.
   *
   * Why the same Sanctum token still works, despite journal §2.2 concluding
   * the two auth schemes were separate: `fleetbase.api` maps to
   * `AuthenticateOnceWithBasicAuth`, whose name is misleading — it reads
   * `$request->bearerToken()` and tries `PersonalAccessToken::findToken()`
   * FIRST, falling back to an `ApiCredential` lookup on `key` only if that
   * misses. A Sanctum personal access token is therefore accepted on `v1`
   * exactly as it is on `int/v1`, and no second credential is needed.
   *
   * That corrects §2.2's "the flb_live_ key is nearly useless to us" framing:
   * the accurate statement is that BOTH credentials work on `v1`, while only
   * Sanctum works on `int/v1` — so a single Sanctum token covers everything.
   */
  async callFleetOpsPublic(method: string, path: string, data?: any, params?: any) {
    return this.apiClient({
      method,
      url: `/v1${path}`,
      data,
      params,
    });
  }

  /**
   * Call standard FleetOps API endpoint
   * Used for fleet operations (internal, with service account)
   */
  async callFleetOps(method: string, path: string, data?: any, params?: any) {
    return this.apiClient({
      method,
      url: `/int/v1${path}`,
      data,
      params,
    });
  }

  /**
   * Login to customer-portal for merchant
   */
  async merchantLogin(email: string, password: string) {
    try {
      const response = await this.callCustomerPortal('POST', '/auth/login', {
        email,
        password,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Merchant login failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a Fleetbase Vendor for a merchant
   */
  async createVendor(name: string, email: string, phone?: string) {
    try {
      const response = await this.callFleetOps('POST', '/vendors', {
        name,
        email,
        phone,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Vendor creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Attach a Contact as personnel of a Vendor, with type 'customer'.
   * Fleetbase auto-provisions a linked User (role "Fleet-Ops Customer")
   * unless create_login is set to false.
   */
  async createCustomer(vendorUuid: string, email: string, firstName: string, lastName: string) {
    try {
      const response = await this.callFleetOps('POST', `/vendors/${this.seg(vendorUuid)}/personnels`, {
        email,
        name: `${firstName} ${lastName}`.trim(),
        type: 'customer',
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Customer creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a Place (pickup/dropoff location) in Fleetbase.
   * Response shape: { place: { uuid, ... } }
   */
  async createPlace(name: string, latitude: number, longitude: number) {
    try {
      const response = await this.callFleetOps('POST', '/places', {
        name,
        location: {
          type: 'Point',
          coordinates: [longitude, latitude],
        },
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Place creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a Place owned by a merchant's Vendor, used as a saved address-book
   * entry. Confirmed by direct testing that owner_uuid is a genuine filter
   * column on GET /places (querying by an owner_uuid with no owned Places
   * returns an empty list, not the full company-wide set) - this is what
   * makes per-merchant address scoping safe.
   */
  async createOwnedPlace(
    ownerUuid: string,
    data: { name: string; latitude: number; longitude: number; address?: string; phone?: string; meta?: Record<string, any> },
  ) {
    try {
      const response = await this.callFleetOps('POST', '/places', {
        name: data.name,
        location: {
          type: 'Point',
          coordinates: [data.longitude, data.latitude],
        },
        address: data.address,
        phone: data.phone,
        owner_uuid: ownerUuid,
        owner_type: 'fleet-ops:vendor',
        meta: data.meta,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Owned place creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * List Places owned by a given Vendor (a merchant's saved addresses).
   */
  async getOwnedPlaces(ownerUuid: string) {
    try {
      const response = await this.callFleetOps('GET', '/places', undefined, { owner_uuid: ownerUuid });
      return response.data;
    } catch (error) {
      this.logger.error(`Get owned places failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Resolve the default 'transport' OrderConfig UUID, required by order creation.
   */
  async getDefaultOrderConfigUuid(): Promise<string> {
    try {
      const response = await this.callFleetOps('GET', '/order-configs');
      const configs = response.data?.order_configs || [];
      const transportConfig = configs.find((c: any) => c.key === 'transport') || configs[0];
      if (!transportConfig) {
        throw new Error('No OrderConfig found in Fleetbase');
      }
      return transportConfig.uuid;
    } catch (error) {
      this.logger.error(`Get order configs failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a delivery Order. Fleetbase requires the entire payload nested
   * under a top-level 'order' key, with payload.pickup_uuid/dropoff_uuid
   * referencing pre-created Place records (or a payload.waypoints array).
   *
   * customer_uuid/customer_type (not a flat 'customer' string) are required:
   * confirmed by live test (28/07/2026) that OrderController's
   * normalizeCustomerType() only reads input['customer_uuid'] or
   * input['customer']['uuid'] - a flat string 'customer' value is silently
   * dropped and customer_uuid ends up null (see
   * docs/journal_implementation_bff.md §2.10). facilitator_uuid/
   * facilitator_type use the same direct-column pattern, confirmed working.
   */
  async createOrder(order: {
    order_config_uuid: string;
    customer_uuid: string;
    customer_type?: string;
    type?: string;
    payload: { pickup_uuid: string; dropoff_uuid: string };
    meta?: Record<string, any>;
  }) {
    try {
      const response = await this.callFleetOps('POST', '/orders', { order });
      return response.data;
    } catch (error) {
      this.logger.error(`Order creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Get merchant's orders via customer-portal-api
   */
  async getMerchantOrders(token: string, page = 1, limit = 25) {
    try {
      const response = await this.callCustomerPortal('GET', '/orders', undefined, token, {
        page,
        limit,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Get merchant orders failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * List ALL company orders, unfiltered. Confirmed by direct testing (28/07/2026,
   * see docs/journal_implementation_bff.md §2.8) that Fleetbase silently IGNORES
   * `facilitator_uuid` as a query filter on this endpoint - it returns the full
   * company-wide dataset regardless of the value passed. Callers MUST filter the
   * result client-side by `facilitator_uuid`; never trust a query param here as
   * a security boundary.
   */
  async getAllOrders(page = 1, limit = 100) {
    try {
      const response = await this.callFleetOps('GET', '/orders', undefined, { page, limit });
      return response.data;
    } catch (error) {
      this.logger.error(`Get all orders failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Normalise the shapes Fleetbase wraps a collection in (journal §2.4):
   * sometimes a bare array, sometimes under `data`, sometimes under a
   * resource-named key. Never assume one — the same installation answers
   * differently depending on the endpoint.
   */
  extractCollection(response: any, ...resourceKeys: string[]): any[] {
    for (const key of [...resourceKeys, 'data']) {
      if (Array.isArray(response?.[key])) {
        return response[key];
      }
    }
    return Array.isArray(response) ? response : [];
  }

  /**
   * Every company order, across as many pages as it takes.
   *
   * `getAllOrders()` above returns ONE page, and its 100-item default silently
   * looks like "all of them" until the company crosses that count — after
   * which a caller scanning the result for a specific order stops finding
   * orders that exist and are legitimately assigned, and reports a 404. Since
   * every filter here is applied client-side (Fleetbase ignores the query
   * filters, see the note above), an incomplete fetch is an incorrect answer,
   * not merely a truncated list.
   *
   * The page cap is a runaway guard, not a limit anyone should hit; crossing
   * it is logged because past that point the results are wrong again.
   */
  async fetchEveryOrder(pageSize = 100, maxPages = 50): Promise<any[]> {
    const all: any[] = [];

    for (let page = 1; page <= maxPages; page++) {
      const orders = this.extractCollection(await this.getAllOrders(page, pageSize), 'orders');

      if (orders.length === 0) {
        break;
      }

      all.push(...orders);

      if (orders.length < pageSize) {
        break;
      }

      if (page === maxPages) {
        this.logger.warn(
          `fetchEveryOrder a atteint le garde-fou de ${maxPages} pages — la liste est tronquée, ` +
            'les recherches par identifiant peuvent renvoyer un 404 à tort',
        );
      }
    }

    return all;
  }

  /**
   * Get a single order by uuid. Confirmed working (used for tracking, see
   * commercant.service.ts getOrderTracking).
   */
  async getOrder(orderUuid: string) {
    try {
      const response = await this.callFleetOps('GET', `/orders/${this.seg(orderUuid)}`);
      return response.data;
    } catch (error) {
      this.logger.error(`Get order failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Cancel an order. Note: no {id} in the path - the order UUID goes in
   * the request body as 'order', per OrderController::cancel().
   */
  async cancelOrder(orderUuid: string) {
    try {
      const response = await this.callFleetOps('PATCH', '/orders/cancel', { order: orderUuid });
      return response.data;
    } catch (error) {
      this.logger.error(`Cancel order failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Assign an order to a driver. Confirmed shape by reading
   * DriverController::assignOrder() - route is `/drivers/{id}/assign-order`,
   * body key is `order` (not `order_id`/`orderId`).
   */
  async assignOrderToDriver(driverUuid: string, orderUuid: string) {
    try {
      const response = await this.callFleetOps('POST', `/drivers/${driverUuid}/assign-order`, {
        order: orderUuid,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Assign order to driver failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * List ALL company drivers, unfiltered. Confirmed by direct testing (28/07/2026,
   * see docs/journal_implementation_bff.md §2.8) that `vendor_uuid` is silently
   * IGNORED as a query filter here too - same bypass as /orders. Callers MUST
   * filter client-side by `vendor_uuid`; never trust this query param.
   */
  async getAllDrivers() {
    try {
      const response = await this.callFleetOps('GET', '/drivers');
      return response.data;
    } catch (error) {
      this.logger.error(`Get all drivers failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a new Driver record in Fleetbase.
   * Confirmed by live test (28/07/2026) that a flat payload crashes
   * DriverController::createRecord() with the exact same PHP TypeError as
   * flat order payloads crashed OrderController (see
   * docs/journal_implementation_bff.md §2.5): `Validator::make($request->
   * input(...), $rules)` receives `null`. Wrapping under a `driver` key
   * (mirroring the `order` envelope for /orders) is the fix by analogy -
   * NOT yet independently confirmed to be the correct key name; re-test
   * and, if it still 400s, check `DriverController.php` line 67 directly.
   */
  async createDriver(data: { name: string; email?: string; phone?: string }) {
    try {
      const response = await this.callFleetOps('POST', '/drivers', { driver: data });
      return response.data;
    } catch (error) {
      this.logger.error(`Create driver failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Attach a Driver to a Vendor's fleet. Confirmed shape by reading
   * VendorController::assignDriver() - route is `/vendors/{id}/assign-driver`,
   * body key is `driver`; this sets the Driver's `vendor_uuid`.
   */
  async assignDriverToVendor(vendorUuid: string, driverUuid: string) {
    try {
      const response = await this.callFleetOps('POST', `/vendors/${vendorUuid}/assign-driver`, {
        driver: driverUuid,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Assign driver to vendor failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create or update a push-notification device record for a Fleetbase user.
   *
   * IMPORTANT, discovered 28/07/2026 while implementing driver auth (reading
   * the public fleetbase/fleetops and fleetbase/core-api source, no local
   * Fleetbase instance was available to test against in this sandbox): the
   * `Driver` model has NO fcm/apn token column at all. `Driver::
   * routeNotificationForFcm()`/`routeNotificationForApn()` (used by the
   * OrderPing notification, docs/specs_echango_delivery.md §3.2) instead read
   * a `devices()` HasMany relation to `UserDevice`, joined on `user_uuid` (not
   * `driver_uuid`) - a separate core-api model/table entirely. This
   * contradicts the assumption in docs/specs_app_transporteur.md §2.1/§11.1
   * that the BFF "writes the push token onto the Driver record" - it must
   * instead write a UserDevice keyed by the Driver's `user_uuid`.
   *
   * Route confirmed by reading core-api's routes.php: `$router->
   * fleetbaseRoutes('user-devices')`, the same macro used by `/vendors` and
   * `/places` (both take a flat, non-enveloped payload) rather than the
   * custom `/orders`/`/drivers` controllers (which require an enveloped
   * payload, see docs/journal_implementation_bff.md §2.5/§2.12) - a flat
   * payload is used here by that analogy.
   *
   * VALIDATED end-to-end 28/07/2026 via scripts/test-driver-auth.sh against a
   * live local Fleetbase: the flat payload and the response key both work, and
   * the returned UserDevice uuid is persisted. The analogy above held.
   *
   * Still unconfirmed: whether repeat calls with the same token upsert or
   * append a row on the Fleetbase side. It matters in practice - Firebase
   * hands back the same token on every app start, so this route gets called
   * repeatedly, and duplicate rows would mean duplicate pushes.
   */
  async upsertDriverDeviceToken(userUuid: string, token: string, platform: string) {
    try {
      const response = await this.callFleetOps('POST', '/user-devices', {
        user_uuid: userUuid,
        token,
        platform,
        status: 'active',
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Upsert driver device token failed: ${error.message}`);
      throw error;
    }
  }

  // ── Opérations driver (API publique v1) ────────────────────────────────
  // Formes de payload lues dans fleetops server/src/Http/Controllers/Api/v1/
  // {Order,Driver}Controller.php le 28/07/2026, pas supposées.
  //
  // ⚠️ TOUTES ces routes s'adressent par **public_id** (`driver_xxx`,
  // `order_xxx`), jamais par uuid — `findRecordOrFail()` (core-api,
  // HasApiModelBehavior) matche `public_id`/`internal_id` et rien d'autre.
  // Passer un uuid donne un 404 « resource not found » parfaitement
  // trompeur, puisque l'enregistrement existe. Vérifié par test réel le
  // 28/07/2026 (journal §6.7). Les paramètres sont nommés en conséquence.

  /**
   * Push a GPS fix. `track()` accepts latitude/longitude plus optional
   * altitude/heading/speed, and resolves {id} through findRecordOrFail, which
   * takes either a public_id or a uuid.
   */
  async trackDriver(
    driverPublicId: string,
    position: { latitude: number; longitude: number; altitude?: number; heading?: number; speed?: number },
  ) {
    const response = await this.callFleetOpsPublic('POST', `/drivers/${this.seg(driverPublicId)}/track`, position);
    return response.data;
  }

  /**
   * Flip driver availability. Passing `online` sets it explicitly; omitting it
   * makes Fleetbase toggle whatever is current — we always pass it, since a
   * blind toggle would desync if a request were retried.
   */
  async toggleDriverOnline(driverPublicId: string, online: boolean) {
    const response = await this.callFleetOpsPublic('POST', `/drivers/${this.seg(driverPublicId)}/toggle-online`, { online });
    return response.data;
  }

  /**
   * Fiche complète d'un driver, par son public_id.
   *
   * Pourquoi pas la liste : la ressource Fleetbase expose
   * `'online' => data_get($this, 'online', false)`, donc elle renvoie `false`
   * aussi bien pour « hors ligne » que pour « attribut non chargé ». Un
   * `false` lu dans une collection ne distingue pas les deux, et se lit à tort
   * comme une disponibilité. Une fiche unique hydrate l'enregistrement.
   *
   * `v1` et non `int/v1` : le GET par identifiant de `int/v1` ignore le
   * paramètre de chemin et renvoie toute la collection (journal §2.13).
   */
  async getDriverByPublicId(driverPublicId: string) {
    const response = await this.callFleetOpsPublic('GET', `/drivers/${this.seg(driverPublicId)}`);
    return response.data;
  }

  /**
   * Start an order. `assign` is how an adhoc order gets claimed — and it is
   * validated as a **public_id** (the controller requires the `driver_`
   * prefix), NOT the uuid used everywhere else. Hence DriverAccount stores
   * both identifiers.
   */
  async startOrder(orderPublicId: string, assignDriverPublicId?: string) {
    const body = assignDriverPublicId ? { assign: assignDriverPublicId } : {};
    const response = await this.callFleetOpsPublic('POST', `/orders/${this.seg(orderPublicId)}/start`, body);
    return response.data;
  }

  /**
   * The activities the order can legally transition to right now.
   *
   * Needed because the order detail carries no activity data at all — verified
   * 28/07/2026 on a live order: it exposes `order_config_uuid` but neither the
   * flow nor the current step (journal §6.9). This route resolves the flow
   * against the order's current state and returns ready-to-use Activity
   * objects, so neither the BFF nor the app has to reimplement the state
   * machine.
   *
   * Each entry carries at least: code, status, details, complete, and
   * require_pod/pod_method when the step demands proof — which is also how the
   * app knows to route to the POD screen (specs_app_transporteur.md §5).
   *
   * `waypoint` selects a specific stop on a multi-stop order.
   */
  async getNextActivities(orderPublicId: string, waypoint?: string) {
    const response = await this.callFleetOpsPublic(
      'GET',
      `/orders/${this.seg(orderPublicId)}/next-activity`,
      undefined,
      waypoint ? { waypoint } : undefined,
    );
    return response.data;
  }

  /**
   * Advance the order through its state machine. `activity` must be a full
   * Activity object as returned by getNextActivities() — not a status string.
   */
  async updateOrderActivity(orderPublicId: string, activity: any, proof?: string) {
    const body: any = { activity };
    if (proof) body.proof = proof;
    const response = await this.callFleetOpsPublic('POST', `/orders/${this.seg(orderPublicId)}/update-activity`, body);
    return response.data;
  }

  /**
   * Attach photo proof. The controller accepts `photos` as multipart uploads
   * OR as an array of base64 strings — we use base64, which keeps the BFF a
   * plain JSON service with no multipart handling.
   */
  async captureOrderPhoto(orderPublicId: string, photos: string[], remarks?: string, subjectId?: string) {
    const path = subjectId
      ? `/orders/${this.seg(orderPublicId)}/capture-photo/${this.seg(subjectId)}`
      : `/orders/${this.seg(orderPublicId)}/capture-photo`;

    // ── Contournement d'un bug amont Fleetbase ──────────────────────────
    // capturePhoto() résout le bucket ainsi :
    //
    //   $bucket = $request->input("filesystems.disks.{$disk}.bucket",
    //                             config('filesystems.disks.s3.bucket'));
    //
    // La première ligne devrait être `config(...)` : elle lit une clé de la
    // REQUÊTE, jamais présente, donc le repli S3 s'applique toujours — et vaut
    // null sans S3 configuré. `storeProofPhoto()` typant ce paramètre `string`,
    // l'appel meurt en TypeError 500. Tout upload de preuve est donc cassé sur
    // une installation non-S3, quel que soit l'appelant (constaté en réel le
    // 28/07/2026, journal §6.12).
    //
    // Le bug est aussi son propre remède : la valeur venant de la requête, on
    // l'y place. Le disque et le bucket restent surchargeables par
    // environnement pour un déploiement S3 réel.
    // Le bucket doit être NON VIDE : `ConvertEmptyStringsToNull` est dans la
    // pile Laravel, donc une chaîne vide arrive à `null` au contrôleur et
    // reproduit exactement le TypeError qu'on cherche à éviter (constaté au
    // 2e essai, 28/07). Le disque `local` ignore la valeur de toute façon.
    const disk = process.env.FLEETBASE_PROOF_DISK || 'local';
    const bucket = process.env.FLEETBASE_PROOF_BUCKET || 'fleetbase';

    const body: any = {
      photos,
      disk,
      filesystems: { disks: { [disk]: { bucket } } },
    };
    if (remarks) body.remarks = remarks;

    const response = await this.callFleetOpsPublic('POST', path, body);
    return response.data;
  }

  /**
   * Mark an order complete. Distinct from updateActivity: this is the
   * dedicated terminal transition, and it is what the app's "delivered"
   * button maps to.
   */
  async completeOrder(orderPublicId: string) {
    const response = await this.callFleetOpsPublic('POST', `/orders/${this.seg(orderPublicId)}/complete`, {});
    return response.data;
  }

  async getOrderPublic(orderPublicId: string) {
    const response = await this.callFleetOpsPublic('GET', `/orders/${this.seg(orderPublicId)}`);
    return response.data;
  }

  /**
   * Delete a UserDevice, used to retire a push token the driver no longer has.
   *
   * Firebase rotates tokens (reinstall, cleared app data, restored backup) and
   * nothing removes the old record on its own, while
   * Driver::routeNotificationForFcm() returns EVERY device on the user_uuid.
   * Left alone, Fleetbase keeps pushing to dead tokens forever — a failure
   * that produces no error anywhere, just notifications that never arrive.
   *
   * DELETE /{resource}/{id} confirmed as part of what the fleetbaseRoutes()
   * macro generates (core-api RESTRegistrar).
   */
  async deleteUserDevice(userDeviceId: string) {
    const response = await this.callFleetOps('DELETE', `/user-devices/${this.seg(userDeviceId)}`);
    return response.data;
  }

  /**
   * Find a UserDevice by its push token, returning the record so callers can
   * pick whichever identifier the route they need actually resolves.
   *
   * Exists because the mirror only captured a uuid, and record resolution in
   * Fleetbase is not uniform: §6.7 established that `findRecordOrFail()`
   * matches public_id and never uuid. Rather than assume which one DELETE
   * accepts, look the device up and try the public_id first.
   */
  async findUserDeviceByToken(token: string) {
    try {
      const response = await this.callFleetOps('GET', '/user-devices');
      const devices =
        response.data?.user_devices || response.data?.data ||
        (Array.isArray(response.data) ? response.data : []);
      return (devices || []).find((d: any) => d?.token === token) || null;
    } catch (error) {
      this.logger.warn(`UserDevice lookup by token failed: ${error.message}`);
      return null;
    }
  }

  /**
   * List ALL company Position records, unfiltered. Confirmed by reading
   * PositionFilter.php (28/07/2026) that there is no `driver_uuid` (or any
   * per-driver) query filter on this endpoint - it only supports a free-text
   * `query` search, `createdAt`, and automatic company-wide scoping. `GET
   * /int/v1/driver-positions` (previously assumed here) does not exist at
   * all - confirmed 404 ("There is nothing to see here", the masked
   * NotFoundHttpException pattern from docs/journal_implementation_bff.md
   * §2.1). The real resource is the generic `/int/v1/positions` endpoint.
   * Callers MUST filter the result client-side by `driver_uuid`.
   *
   * ⚠️ Plus utilisé par la carte de flotte : télécharger tout l'historique de
   * la compagnie pour n'afficher qu'un point par driver ne tenait pas à
   * l'échelle. `FlotteService.getDriverPositions()` sert désormais le miroir
   * local alimenté par `POST /transporteur/position`. Cette méthode reste pour
   * un besoin d'historique — ne pas la rebrancher sur la carte.
   */
  async getAllPositions() {
    try {
      const response = await this.callFleetOps('GET', '/positions');
      return response.data;
    } catch (error) {
      this.logger.error(`Get all positions failed: ${error.message}`);
      throw error;
    }
  }
}
