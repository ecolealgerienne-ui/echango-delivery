import { Controller, Get, Post, Param, Body, Request } from '@nestjs/common';
import { CommerçantService } from './commercant.service';

@Controller('commercant')
export class CommerçantController {
  constructor(private commercantService: CommerçantService) {}

  @Get('commandes')
  async getOrders(@Request() req: any) {
    return this.commercantService.getOrders(req.user.id);
  }

  @Get('commandes/:id')
  async getOrderDetail(@Request() req: any, @Param('id') orderId: string) {
    return this.commercantService.getOrderDetail(req.user.id, orderId);
  }

  @Post('commandes')
  async createOrder(@Request() req: any, @Body() data: any) {
    return this.commercantService.createOrder(req.user.id, data);
  }

  @Post('commandes/:id/annuler')
  async cancelOrder(@Request() req: any, @Param('id') orderId: string) {
    return this.commercantService.cancelOrder(req.user.id, orderId);
  }

  @Get('commandes/:id/suivi')
  async getOrderTracking(@Request() req: any, @Param('id') orderId: string) {
    return this.commercantService.getOrderTracking(req.user.id, orderId);
  }

  @Post('device-token')
  async registerDeviceToken(@Request() req: any, @Body() body: any) {
    return this.commercantService.registerDeviceToken(
      req.user.id,
      body.token,
      body.platform,
    );
  }

  @Get('adresses')
  async getAddresses(@Request() req: any) {
    return this.commercantService.getAddresses(req.user.id);
  }

  @Post('adresses')
  async saveAddress(@Request() req: any, @Body() address: any) {
    return this.commercantService.saveAddress(req.user.id, address);
  }
}
