import { Injectable, BadRequestException, UnauthorizedException, Logger } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import * as bcrypt from 'bcrypt';
import { PrismaService } from '../database/prisma.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { MerchantRegisterDto, MerchantLoginDto } from './dto/register.dto';

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private prisma: PrismaService,
    private jwtService: JwtService,
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
      throw new BadRequestException('Email already registered');
    }

    try {
      // 1. Create Vendor in Fleetbase
      const vendorResponse = await this.fleetbaseClient.createVendor(
        dto.businessName,
        dto.email,
        dto.businessPhone,
      );

      const vendorUuid = vendorResponse.data.uuid || vendorResponse.data.id;

      // 2. Create Customer in Fleetbase
      const customerResponse = await this.fleetbaseClient.createCustomer(
        vendorUuid,
        dto.email,
        dto.firstName,
        dto.lastName,
      );

      const customerUuid = customerResponse.data.uuid || customerResponse.data.id;

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
          emailVerified: true, // TODO: Implement email verification
        },
      });

      // 4. Generate JWT token
      const token = this.jwtService.sign({
        sub: merchant.id,
        email: merchant.email,
        type: 'merchant',
      });

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
      throw new BadRequestException('Failed to register merchant');
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

    // Update last login
    await this.prisma.merchantAccount.update({
      where: { id: merchant.id },
      data: { lastLoginAt: new Date() },
    });

    // Generate JWT token
    const token = this.jwtService.sign({
      sub: merchant.id,
      email: merchant.email,
      type: 'merchant',
    });

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
   * Verify JWT token and return payload
   */
  verifyToken(token: string) {
    try {
      return this.jwtService.verify(token);
    } catch (error) {
      throw new UnauthorizedException('Invalid token');
    }
  }
}
