import { Injectable, BadRequestException, UnauthorizedException, Logger, ConflictException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { ConfigService } from '@nestjs/config';
import * as bcrypt from 'bcrypt';
import { PrismaService } from '../database/prisma.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { MerchantRegisterDto, MerchantLoginDto, FleetRegisterDto, FleetLoginDto } from './dto/register.dto';

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
  private generateToken(userId: string, email: string, type: 'merchant' | 'fleet') {
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
