import {
  Controller,
  Get,
  Post,
  Body,
  Param,
  Query,
  Request,
  ForbiddenException,
} from '@nestjs/common';
import { TransporteurService } from './transporteur.service';
import {
  UpdatePositionDto,
  ToggleOnlineDto,
  UpdateActivityDto,
  ReportDeliveryFailureDto,
  CapturePhotoDto,
  ListDriverOrdersQueryDto,
} from './dto/transporteur.dto';

/**
 * Driver-facing API for the Flutter app (docs/specs_app_transporteur.md §3-5).
 *
 * Every route is JWT-protected by the global guard. On top of that, each one
 * asserts the token belongs to a driver: the three personas share one JWT
 * issuer, so without this a merchant token would be structurally valid here
 * and would resolve `req.user.id` against the wrong table.
 */
@Controller('transporteur')
export class TransporteurController {
  constructor(private readonly transporteurService: TransporteurService) {}

  private driverId(req: any): string {
    if (req.user?.type !== 'transporteur') {
      throw new ForbiddenException('This endpoint requires a driver account');
    }
    return req.user.id;
  }

  @Get('profil')
  async getProfile(@Request() req: any) {
    return this.transporteurService.getProfile(this.driverId(req));
  }

  @Post('position')
  async updatePosition(@Request() req: any, @Body() dto: UpdatePositionDto) {
    return this.transporteurService.updatePosition(this.driverId(req), dto);
  }

  @Post('statut')
  async toggleOnline(@Request() req: any, @Body() dto: ToggleOnlineDto) {
    return this.transporteurService.toggleOnline(this.driverId(req), dto);
  }

  @Get('commandes')
  async listOrders(@Request() req: any, @Query() query: ListDriverOrdersQueryDto) {
    return this.transporteurService.listOrders(this.driverId(req), query);
  }

  @Get('commandes/:id')
  async getOrder(@Request() req: any, @Param('id') id: string) {
    return this.transporteurService.getOrder(this.driverId(req), id);
  }

  @Post('commandes/:id/accepter')
  async acceptOrder(@Request() req: any, @Param('id') id: string) {
    return this.transporteurService.acceptOrder(this.driverId(req), id);
  }

  @Post('commandes/:id/demarrer')
  async startOrder(@Request() req: any, @Param('id') id: string) {
    return this.transporteurService.startOrder(this.driverId(req), id);
  }

  @Post('commandes/:id/terminer')
  async completeOrder(@Request() req: any, @Param('id') id: string) {
    return this.transporteurService.completeOrder(this.driverId(req), id);
  }

  @Get('commandes/:id/activites-suivantes')
  async getNextActivities(
    @Request() req: any,
    @Param('id') id: string,
    @Query('waypoint') waypoint?: string,
  ) {
    return this.transporteurService.getNextActivities(this.driverId(req), id, waypoint);
  }

  @Post('commandes/:id/activite')
  async updateActivity(@Request() req: any, @Param('id') id: string, @Body() dto: UpdateActivityDto) {
    return this.transporteurService.updateActivity(this.driverId(req), id, dto);
  }

  @Post('commandes/:id/preuve')
  async capturePhoto(@Request() req: any, @Param('id') id: string, @Body() dto: CapturePhotoDto) {
    return this.transporteurService.capturePhoto(this.driverId(req), id, dto);
  }

  @Post('commandes/:id/echec')
  async reportFailure(
    @Request() req: any,
    @Param('id') id: string,
    @Body() dto: ReportDeliveryFailureDto,
  ) {
    return this.transporteurService.reportDeliveryFailure(this.driverId(req), id, dto);
  }
}
