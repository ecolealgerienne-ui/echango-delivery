import { Injectable, Logger } from '@nestjs/common';
import axios, { AxiosInstance } from 'axios';

@Injectable()
export class FleetbaseApiClient {
  private readonly logger = new Logger(FleetbaseApiClient.name);
  private readonly apiClient: AxiosInstance;

  constructor() {
    const baseURL = process.env.FLEETBASE_API_URL || 'http://localhost:8000/api';
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
        this.logger.error(`Fleetbase API error: ${error.message}`, error);
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
      url: `/v1${path}`,
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
   * Create a Customer contact for a merchant in Fleetbase
   */
  async createCustomer(vendorUuid: string, email: string, firstName: string, lastName: string) {
    try {
      const response = await this.callFleetOps('POST', '/customers', {
        vendor_uuid: vendorUuid,
        email,
        first_name: firstName,
        last_name: lastName,
        type: 'customer', // Polymorphic type
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Customer creation failed: ${error.message}`);
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
   * Get orders scoped to a facilitator (fleet)
   */
  async getFleetOrders(facilitatorUuid: string, page = 1, limit = 25) {
    try {
      const response = await this.callFleetOps('GET', '/orders', undefined, {
        facilitator_uuid: facilitatorUuid,
        page,
        limit,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Get fleet orders failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Assign a driver to an order
   */
  async assignDriverToOrder(orderId: string, driverUuid: string) {
    try {
      const response = await this.callFleetOps('PATCH', `/orders/${orderId}`, {
        driver_assigned_uuid: driverUuid,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Assign driver failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Get drivers for a fleet
   */
  async getFleetDrivers(fleetUuid: string) {
    try {
      const response = await this.callFleetOps('GET', `/fleets/${fleetUuid}/drivers`);
      return response.data;
    } catch (error) {
      this.logger.error(`Get fleet drivers failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Get driver positions
   */
  async getDriverPositions(driverIds: string[]) {
    try {
      const response = await this.callFleetOps('GET', '/driver-positions', undefined, {
        driver_ids: driverIds.join(','),
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Get driver positions failed: ${error.message}`);
      throw error;
    }
  }
}
