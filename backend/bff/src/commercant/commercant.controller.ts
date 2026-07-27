import { Controller, Get, Post, Param, Body, Request, Query } from '@nestjs/common';
import { CommerçantService } from './commercant.service';
import { CreateOrderDto, ListOrdersQueryDto } from './dto/create-order.dto';
import { SaveAddressDto } from './dto/address.dto';

@Controller('commercant')
export class CommerçantController {
  constructor(private commercantService: CommerçantService) {}

  @Get('commandes')
  async getOrders(@Request() req: any, @Query() query: ListOrdersQueryDto) {
    return this.commercantService.getOrders(req.user.id, query);
  }

  @Get('commandes/:id')
  async getOrderDetail(@Request() req: any, @Param('id') orderId: string) {
    return this.commercantService.getOrderDetail(req.user.id, orderId);
  }

  @Post('commandes')
  async createOrder(@Request() req: any, @Body() dto: CreateOrderDto) {
    return this.commercantService.createOrder(req.user.id, dto);
  }

  @Post('commandes/:id/annuler')
  async cancelOrder(@Request() req: any, @Param('id') orderId: string) {
    return this.commercantService.cancelOrder(req.user.id, orderId);
  }

  @Get('commandes/:id/suivi')
  async getOrderTracking(@Request() req: any, @Param('id') orderId: string) {
    return this.commercantService.getOrderTracking(req.user.id, orderId);
  }

  @Get('adresses')
  async getAddresses(@Request() req: any) {
    return this.commercantService.getAddresses(req.user.id);
  }

  @Post('adresses')
  async saveAddress(@Request() req: any, @Body() dto: SaveAddressDto) {
    return this.commercantService.saveAddress(req.user.id, dto);
  }
}
