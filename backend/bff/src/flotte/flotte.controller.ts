import { Controller, Get, Post, Param, Body, Query, Request } from '@nestjs/common';
import { FleetbaseIdPipe } from '../common/pipes/fleetbase-id.pipe';
import { FlotteService } from './flotte.service';
import { Persona } from '../common/decorators/persona.decorator';
import { ListFleetOrdersQueryDto, AssignDriverDto } from './dto/order.dto';
import { AddDriverDto } from './dto/driver.dto';

@Persona('fleet')
@Controller('flotte')
export class FlotteController {
  constructor(private flotteService: FlotteService) {}

  @Get('commandes')
  async getOrders(@Request() req: any, @Query() query: ListFleetOrdersQueryDto) {
    return this.flotteService.getOrders(this.fleetId(req), query);
  }

  @Get('commandes/:id')
  async getOrderDetail(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string) {
    return this.flotteService.getOrderDetail(this.fleetId(req), orderId);
  }

  @Get('drivers')
  async getDrivers(@Request() req: any) {
    return this.flotteService.getDrivers(this.fleetId(req));
  }

  @Post('drivers')
  async addDriver(@Request() req: any, @Body() dto: AddDriverDto) {
    return this.flotteService.addDriver(this.fleetId(req), dto);
  }

  @Get('drivers/positions')
  async getDriverPositions(@Request() req: any, @Query('driverIds') driverIds?: string) {
    const ids = driverIds ? driverIds.split(',').filter(Boolean) : [];
    return this.flotteService.getDriverPositions(this.fleetId(req), ids);
  }

  @Post('commandes/:id/assigner')
  async assignDriver(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string, @Body() body: AssignDriverDto) {
    return this.flotteService.assignDriver(this.fleetId(req), orderId, body.driverId);
  }

  /**
   * req.user is populated by JwtAuthGuard from the verified token payload
   * (type: 'merchant' | 'fleet'). Reject merchant tokens here so a
   * commerçant account can never call flotte endpoints with its own JWT.
   */
  private fleetId(req: any): string {
    return req.user.id;
  }
}
