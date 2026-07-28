import { Controller, Post, Body, Request } from '@nestjs/common';
import { AuthService } from './auth.service';
import { MerchantRegisterDto, MerchantLoginDto, FleetRegisterDto, FleetLoginDto } from './dto/register.dto';
import { RegisterDeviceTokenDto } from './dto/device-token.dto';
import { Public } from '../common/decorators/public.decorator';

@Controller('auth')
export class AuthController {
  constructor(private authService: AuthService) {}

  @Public()
  @Post('merchant/register')
  async registerMerchant(@Body() dto: MerchantRegisterDto) {
    return this.authService.registerMerchant(dto);
  }

  @Public()
  @Post('merchant/login')
  async loginMerchant(@Body() dto: MerchantLoginDto) {
    return this.authService.loginMerchant(dto);
  }

  @Public()
  @Post('flotte/register')
  async registerFleet(@Body() dto: FleetRegisterDto) {
    return this.authService.registerFleet(dto);
  }

  @Public()
  @Post('flotte/login')
  async loginFleet(@Body() dto: FleetLoginDto) {
    return this.authService.loginFleet(dto);
  }

  @Post('device-token')
  async registerDeviceToken(@Request() req: any, @Body() dto: RegisterDeviceTokenDto) {
    return this.authService.registerDeviceToken(req.user.id, dto.token, dto.platform);
  }

  @Post('verify')
  async verifyToken(@Request() req: any) {
    return {
      valid: true,
      user: req.user,
    };
  }
}
