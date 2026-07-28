import { Injectable, BadRequestException, UnauthorizedException, Logger, ConflictException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { ConfigService } from '@nestjs/config';
import * as bcrypt from 'bcrypt';
import { PrismaService } from '../database/prisma.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import {
  MerchantRegisterDto,
  MerchantLoginDto,
  FleetRegisterDto,
  FleetLoginDto,
  DriverRegisterDto,
  DriverLoginDto,
} from './dto/register.dto';

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private prisma: PrismaService,
    private jwtService: JwtService,
    private configService: ConfigService,
    private fleetbaseClient: FleetbaseApiClient,
  ) {}

  /**
   * Register a new merchant
   * Creates Echango account + Fleetbase Vendor + Customer
   */
  async registerMerchant(dto: MerchantRegisterDto) {
    // Check if email already exists
    const existing = await this.prisma.merchantAccount.findUnique({
      where: { email: dto.email },
    });

    if (existing) {
      throw new ConflictException('Email already registered');
    }

    try {
      // 1. Create Vendor in Fleetbase
      this.logger.log(`Creating Vendor in Fleetbase for ${dto.businessName}`);
      const vendorResponse = await this.fleetbaseClient.createVendor(
        dto.businessName,
        dto.email,
        dto.businessPhone,
      );

      const vendorUuid = vendorResponse.vendor?.uuid || vendorResponse.vendor?.id;
      if (!vendorUuid) {
        throw new Error('Vendor UUID not returned from Fleetbase');
      }

      // 2. Create Customer in Fleetbase
      this.logger.log(`Creating Customer in Fleetbase for vendor ${vendorUuid}`);
      const customerResponse = await this.fleetbaseClient.createCustomer(
        vendorUuid,
        dto.email,
        dto.firstName,
        dto.lastName,
      );

      const customerUuid = customerResponse.personnel?.contact_uuid || customerResponse.personnel?.contact?.uuid;
      if (!customerUuid) {
        throw new Error('Customer UUID not returned from Fleetbase');
      }

      // 3. Create MerchantAccount in BFF database
      const hashedPassword = await bcrypt.hash(dto.password, 10);

      const merchant = await this.prisma.merchantAccount.create({
        data: {
          email: dto.email,
          password: hashedPassword,
          firstName: dto.firstName,
          lastName: dto.lastName,
          businessName: dto.businessName,
          phone: dto.phone,
          businessPhone: dto.businessPhone,
          fleetbaseVendorUuid: vendorUuid,
          fleetbaseCustomerUuid: customerUuid,
          emailVerified: true, // TODO: Email verification in v2
        },
      });

      this.logger.log(`Merchant registered: ${merchant.id}`);

      // 4. Generate JWT token
      const token = this.generateToken(merchant.id, merchant.email, 'merchant');

      return {
        token,
        user: {
          id: merchant.id,
          email: merchant.email,
          businessName: merchant.businessName,
        },
      };
    } catch (error) {
      this.logger.error(`Merchant registration failed: ${error.message}`, error);
      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      throw new BadRequestException(
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to register merchant: ${detail}`
          : 'Failed to register merchant',
      );
    }
  }

  /**
   * Login merchant with email/password
   */
  async loginMerchant(dto: MerchantLoginDto) {
    const merchant = await this.prisma.merchantAccount.findUnique({
      where: { email: dto.email },
    });

    if (!merchant) {
      throw new UnauthorizedException('Invalid email or password');
    }

    const passwordMatches = await bcrypt.compare(dto.password, merchant.password);

    if (!passwordMatches) {
      throw new UnauthorizedException('Invalid email or password');
    }

    if (!merchant.emailVerified) {
      throw new UnauthorizedException('Email not verified');
    }

    if (!merchant.active) {
      throw new UnauthorizedException('Account is inactive');
    }

    // Update last login
    await this.prisma.merchantAccount.update({
      where: { id: merchant.id },
      data: { lastLoginAt: new Date() },
    });

    this.logger.log(`Merchant logged in: ${merchant.id}`);

    // Generate JWT token
    const token = this.generateToken(merchant.id, merchant.email, 'merchant');

    return {
      token,
      user: {
        id: merchant.id,
        email: merchant.email,
        businessName: merchant.businessName,
      },
    };
  }

  /**
   * Register a new fleet manager ("petite flotte" persona).
   * Creates Echango account + Fleetbase Vendor only - no Customer/personnel,
   * no dedicated Fleetbase User (Option A, docs/specs_bff.md §2): the fleet
   * manager authenticates purely against the BFF, which then acts as a
   * service account against FleetOps, scoping every call by this Vendor's
   * uuid as facilitator_uuid/vendor_uuid (filtered client-side, see
   * docs/journal_implementation_bff.md §2.8 - Fleetbase does not enforce
   * these filters server-side).
   */
  async registerFleet(dto: FleetRegisterDto) {
    const existing = await this.prisma.fleetAccount.findUnique({
      where: { email: dto.email },
    });

    if (existing) {
      throw new ConflictException('Email already registered');
    }

    try {
      this.logger.log(`Creating Vendor in Fleetbase for fleet ${dto.businessName}`);
      const vendorResponse = await this.fleetbaseClient.createVendor(
        dto.businessName,
        dto.email,
        dto.businessPhone,
      );

      const vendorUuid = vendorResponse.vendor?.uuid || vendorResponse.vendor?.id;
      if (!vendorUuid) {
        throw new Error('Vendor UUID not returned from Fleetbase');
      }

      const hashedPassword = await bcrypt.hash(dto.password, 10);

      const fleet = await this.prisma.fleetAccount.create({
        data: {
          email: dto.email,
          password: hashedPassword,
          firstName: dto.firstName,
          lastName: dto.lastName,
          businessName: dto.businessName,
          phone: dto.phone,
          businessPhone: dto.businessPhone,
          fleetbaseVendorUuid: vendorUuid,
        },
      });

      this.logger.log(`Fleet account registered: ${fleet.id}`);

      const token = this.generateToken(fleet.id, fleet.email, 'fleet');

      return {
        token,
        user: {
          id: fleet.id,
          email: fleet.email,
          businessName: fleet.businessName,
        },
      };
    } catch (error) {
      this.logger.error(`Fleet registration failed: ${error.message}`, error);
      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      throw new BadRequestException(
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to register fleet account: ${detail}`
          : 'Failed to register fleet account',
      );
    }
  }

  /**
   * Login fleet manager with email/password
   */
  async loginFleet(dto: FleetLoginDto) {
    const fleet = await this.prisma.fleetAccount.findUnique({
      where: { email: dto.email },
    });

    if (!fleet) {
      throw new UnauthorizedException('Invalid email or password');
    }

    const passwordMatches = await bcrypt.compare(dto.password, fleet.password);

    if (!passwordMatches) {
      throw new UnauthorizedException('Invalid email or password');
    }

    if (!fleet.active) {
      throw new UnauthorizedException('Account is inactive');
    }

    await this.prisma.fleetAccount.update({
      where: { id: fleet.id },
      data: { lastLoginAt: new Date() },
    });

    this.logger.log(`Fleet manager logged in: ${fleet.id}`);

    const token = this.generateToken(fleet.id, fleet.email, 'fleet');

    return {
      token,
      user: {
        id: fleet.id,
        email: fleet.email,
        businessName: fleet.businessName,
      },
    };
  }

  /**
   * Register (link) an Echango driver account to an already-provisioned
   * Fleetbase Driver. Unlike merchant/fleet registration, this never creates
   * anything in Fleetbase itself - the Driver must already exist (manual
   * provisioning, docs/specs_app_transporteur.md §2.1/§13 Q8). We still
   * verify the given uuid resolves to a real Driver before linking, rather
   * than trusting it blindly, and capture its `user_uuid` (needed later to
   * route push tokens through UserDevice, see fleetbase-api.client.ts
   * upsertDriverDeviceToken).
   *
   * Uses getAllDrivers() + a client-side find rather than a single-record
   * GET: docs/journal_implementation_bff.md §2.13 found that `GET
   * /drivers/{uuid}` ignores the path param entirely and returns the full
   * company driver list regardless, so a per-id lookup would silently "find"
   * any uuid, including typos - fetching everything and matching ourselves
   * is the only way to actually confirm the uuid is real.
   */
  async registerDriver(dto: DriverRegisterDto) {
    try {
      // Ces deux vérifications sont volontairement DANS le try : hors du try,
      // une erreur Prisma (table absente, client non régénéré) échappe au
      // filtre d'exceptions — qui ne capture que les HttpException — et sort
      // en 500 "Internal server error" sans le moindre indice exploitable.
      const existingEmail = await this.prisma.driverAccount.findUnique({
        where: { email: dto.email },
      });

      if (existingEmail) {
        throw new ConflictException('Email already registered');
      }

      const existingUuid = await this.prisma.driverAccount.findUnique({
        where: { fleetbaseDriverUuid: dto.fleetbaseDriverUuid },
      });

      if (existingUuid) {
        throw new ConflictException('This driver is already linked to an account');
      }

      const response = await this.fleetbaseClient.getAllDrivers();
      const drivers = response?.drivers || response?.data || (Array.isArray(response) ? response : []);
      const fleetbaseDriver = (drivers || []).find((d: any) => d?.uuid === dto.fleetbaseDriverUuid);

      if (!fleetbaseDriver) {
        throw new BadRequestException('Unknown Fleetbase driver UUID - ask an operator to verify provisioning');
      }

      const hashedPassword = await bcrypt.hash(dto.password, 10);

      const driver = await this.prisma.driverAccount.create({
        data: {
          email: dto.email,
          password: hashedPassword,
          firstName: dto.firstName,
          lastName: dto.lastName,
          phone: dto.phone,
          fleetbaseDriverUuid: dto.fleetbaseDriverUuid,
          fleetbaseUserUuid: fleetbaseDriver.user_uuid || null,
          fleetbaseDriverPublicId: fleetbaseDriver.public_id || null,
        },
      });

      this.logger.log(`Driver account registered: ${driver.id}`);

      const token = this.generateToken(driver.id, driver.email, 'transporteur');

      return {
        token,
        user: {
          id: driver.id,
          email: driver.email,
          firstName: driver.firstName,
          lastName: driver.lastName,
        },
      };
    } catch (error) {
      if (error instanceof BadRequestException || error instanceof ConflictException) {
        throw error;
      }
      this.logger.error(`Driver registration failed: ${error.message}`, error);

      // Deux pannes d'installation très probables tant que la tranche driver
      // n'a jamais tourné, et indiscernables l'une de l'autre dans un 500 nu.
      // P2021 = table absente ; `driverAccount` undefined = client Prisma pas
      // régénéré depuis l'ajout du modèle. Les deux se corrigent côté dev, pas
      // côté appelant — autant le dire explicitement.
      if (error?.code === 'P2021' || /driverAccount/.test(error?.message ?? '')) {
        throw new BadRequestException(
          'Table DriverAccount introuvable ou client Prisma obsolète. ' +
            'Lancer : npm run prisma:generate && npm run prisma:migrate',
        );
      }

      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      throw new BadRequestException(
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to register driver: ${detail}`
          : 'Failed to register driver',
      );
    }
  }

  /**
   * Login driver with email/password
   */
  async loginDriver(dto: DriverLoginDto) {
    const driver = await this.prisma.driverAccount.findUnique({
      where: { email: dto.email },
    });

    if (!driver) {
      throw new UnauthorizedException('Invalid email or password');
    }

    const passwordMatches = await bcrypt.compare(dto.password, driver.password);

    if (!passwordMatches) {
      throw new UnauthorizedException('Invalid email or password');
    }

    if (!driver.active) {
      throw new UnauthorizedException('Account is inactive');
    }

    await this.prisma.driverAccount.update({
      where: { id: driver.id },
      data: { lastLoginAt: new Date() },
    });

    this.logger.log(`Driver logged in: ${driver.id}`);

    const token = this.generateToken(driver.id, driver.email, 'transporteur');

    return {
      token,
      user: {
        id: driver.id,
        email: driver.email,
        firstName: driver.firstName,
        lastName: driver.lastName,
      },
    };
  }

  /**
   * Register a driver's push token. Kept separate from the merchant
   * registerDeviceToken below (different Prisma model - DriverDeviceToken vs
   * DeviceToken - since DeviceToken is hard-wired to MerchantAccount).
   *
   * Also mirrors the token to Fleetbase as a UserDevice record so the native
   * OrderPing FCM/APN channel (docs/specs_echango_delivery.md §3.2) can reach
   * this device directly (see fleetbase-api.client.ts
   * upsertDriverDeviceToken for the full discovery notes on why this targets
   * UserDevice rather than the Driver record). The mirror is best-effort: if
   * it fails, the local token is still saved and REST polling keeps working,
   * only native push delivery is affected - so we log and continue rather
   * than failing the whole request.
   */
  async registerDriverDeviceToken(driverId: string, token: string, platform: string) {
    const driver = await this.prisma.driverAccount.findUnique({
      where: { id: driverId },
    });

    if (!driver) {
      throw new BadRequestException('Driver not found');
    }

    const existing = await this.prisma.driverDeviceToken.findUnique({
      where: { token },
    });

    let record = existing;

    if (existing) {
      if (existing.driverId !== driverId) {
        record = await this.prisma.driverDeviceToken.update({
          where: { id: existing.id },
          data: { driverId, active: true },
        });
      }
    } else {
      record = await this.prisma.driverDeviceToken.create({
        data: { driverId, token, platform },
      });
    }

    if (driver.fleetbaseUserUuid && !record.fleetbaseUserDeviceUuid) {
      try {
        const response = await this.fleetbaseClient.upsertDriverDeviceToken(
          driver.fleetbaseUserUuid,
          token,
          platform,
        );
        const userDeviceUuid = response?.user_device?.uuid || response?.data?.uuid;

        if (userDeviceUuid) {
          record = await this.prisma.driverDeviceToken.update({
            where: { id: record.id },
            data: { fleetbaseUserDeviceUuid: userDeviceUuid },
          });
        }
      } catch (error) {
        this.logger.warn(
          `Failed to mirror device token to Fleetbase UserDevice for driver ${driverId}: ${error.message}`,
        );
      }
    }

    return record;
  }

  /**
   * Register device token for push notifications
   */
  async registerDeviceToken(merchantId: string, token: string, platform: string) {
    const merchant = await this.prisma.merchantAccount.findUnique({
      where: { id: merchantId },
    });

    if (!merchant) {
      throw new BadRequestException('Merchant not found');
    }

    // Check if token already exists
    const existing = await this.prisma.deviceToken.findUnique({
      where: { token },
    });

    if (existing) {
      // Update if merchant changed
      if (existing.merchantId !== merchantId) {
        await this.prisma.deviceToken.update({
          where: { id: existing.id },
          data: { merchantId },
        });
      }
      return existing;
    }

    // Create new device token
    return this.prisma.deviceToken.create({
      data: {
        merchantId,
        token,
        platform,
      },
    });
  }

  /**
   * Verify JWT token and return payload
   */
  verifyToken(token: string) {
    try {
      return this.jwtService.verify(token);
    } catch (error) {
      throw new UnauthorizedException('Invalid or expired token');
    }
  }

  /**
   * Generate JWT token
   */
  private generateToken(userId: string, email: string, type: 'merchant' | 'fleet' | 'transporteur') {
    // Must be a number (seconds), not a bare numeric string: jsonwebtoken's `ms`
    // dependency interprets a unitless string like "86400" as milliseconds (~86s),
    // not seconds, silently producing tokens that expire almost immediately.
    const expiresIn = parseInt(this.configService.get('JWT_EXPIRATION') || '86400', 10);
    return this.jwtService.sign(
      {
        sub: userId,
        email,
        type,
      },
      { expiresIn },
    );
  }
}
