import { Controller, Get, Post, Param, Body, Request } from '@nestjs/common';
import { FlotteService } from './flotte.service';

@Controller('flotte')
export class FlotteController {
  constructor(private flotteService: FlotteService) {}

  @Get('commandes')
  async getOrders(@Request() _req: any) {
    return this.flotteService.getOrders('fleet-id', 'facilitator-uuid');
  }

  @Get('commandes/:id')
  async getOrderDetail(@Request() _req: any, @Param('id') orderId: string) {
    return this.flotteService.getOrderDetail('fleet-id', 'facilitator-uuid', orderId);
  }

  @Get('drivers')
  async getDrivers(@Request() _req: any) {
    return this.flotteService.getDrivers('fleet-id', 'fleet-uuid');
  }

  @Post('drivers')
  async addDriver(@Request() _req: any, @Body() driverData: any) {
    return this.flotteService.addDriver('fleet-id', 'fleet-uuid', driverData);
  }

  @Get('drivers/positions')
  async getDriverPositions(@Request() _req: any) {
    return this.flotteService.getDriverPositions('fleet-id', []);
  }

  @Post('commandes/:id/assigner')
  async assignDriver(@Request() _req: any, @Param('id') orderId: string, @Body() body: any) {
    return this.flotteService.assignDriver('fleet-id', 'facilitator-uuid', orderId, body.driverId);
  }
}
