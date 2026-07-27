import { Controller, Get, Post, Param, Body, Request } from '@nestjs/common';
import { FlotteService } from './flotte.service';

@Controller('flotte')
export class FlotteController {
  constructor(private flotteService: FlotteService) {}

  @Get('commandes')
  async getOrders(@Request() req: any) {
    // TODO: Get fleet context from request
    return this.flotteService.getOrders('fleet-id', 'facilitator-uuid');
  }

  @Get('commandes/:id')
  async getOrderDetail(@Request() req: any, @Param('id') orderId: string) {
    // TODO: Get fleet context from request
    return this.flotteService.getOrderDetail('fleet-id', 'facilitator-uuid', orderId);
  }

  @Get('drivers')
  async getDrivers(@Request() req: any) {
    // TODO: Get fleet context from request
    return this.flotteService.getDrivers('fleet-id', 'fleet-uuid');
  }

  @Post('drivers')
  async addDriver(@Request() req: any, @Body() driverData: any) {
    // TODO: Get fleet context from request
    return this.flotteService.addDriver('fleet-id', 'fleet-uuid', driverData);
  }

  @Get('drivers/positions')
  async getDriverPositions(@Request() req: any) {
    // TODO: Get fleet context and driver IDs from request
    return this.flotteService.getDriverPositions('fleet-id', []);
  }

  @Post('commandes/:id/assigner')
  async assignDriver(@Request() req: any, @Param('id') orderId: string, @Body() body: any) {
    // TODO: Get fleet context from request
    return this.flotteService.assignDriver('fleet-id', 'facilitator-uuid', orderId, body.driverId);
  }
}
