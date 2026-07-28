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
      const response = await this.callFleetOps('POST', `/vendors/${vendorUuid}/personnels`, {
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
   * Get a single order by uuid. Confirmed working (used for tracking, see
   * commercant.service.ts getOrderTracking).
   */
  async getOrder(orderUuid: string) {
    try {
      const response = await this.callFleetOps('GET', `/orders/${orderUuid}`);
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
