import { Controller, Get, Post, Body, Param, Query, Request, Res } from '@nestjs/common';
import type { Response } from 'express';
import { FleetbaseIdPipe } from '../common/pipes/fleetbase-id.pipe';
import { TransporteurService } from './transporteur.service';
import {
  UpdatePositionDto,
  ToggleOnlineDto,
  UpdateActivityDto,
  ReportDeliveryFailureDto,
  CapturePhotoDto,
  ListDriverOrdersQueryDto,
  UpdateVehicleTypeDto,
} from './dto/transporteur.dto';
import { Persona } from '../common/decorators/persona.decorator';

/**
 * Driver-facing API for the Flutter app (docs/specs_app_transporteur.md §3-5).
 *
 * Every route is JWT-protected by the global guard. On top of that, each one
 * asserts the token belongs to a driver: the three personas share one JWT
 * issuer, so without this a merchant token would be structurally valid here
 * and would resolve `req.user.id` against the wrong table.
 */
@Persona('transporteur')
@Controller('transporteur')
export class TransporteurController {
  constructor(private readonly transporteurService: TransporteurService) {}

  // Le contrôle de type est porté par @Persona sur la classe ; il ne reste
  // qu'à extraire l'identifiant.
  private driverId(req: any): string {
    return req.user.id;
  }

  @Get('profil')
  async getProfile(@Request() req: any) {
    return this.transporteurService.getProfile(this.driverId(req));
  }

  @Post('vehicule')
  async updateVehicleType(@Request() req: any, @Body() dto: UpdateVehicleTypeDto) {
    return this.transporteurService.updateVehicleType(this.driverId(req), dto.vehicleType);
  }

  @Post('position')
  async updatePosition(@Request() req: any, @Body() dto: UpdatePositionDto) {
    return this.transporteurService.updatePosition(this.driverId(req), dto);
  }

  @Post('statut')
  async toggleOnline(@Request() req: any, @Body() dto: ToggleOnlineDto) {
    return this.transporteurService.toggleOnline(this.driverId(req), dto);
  }

  /**
   * Photo d'un signalement d'échec, servie par le BFF.
   *
   * L'app ne reçoit jamais l'URL Fleetbase : elle pointe sur un hôte qui n'est
   * joignable que depuis le serveur, et ces URL de stockage ne sont protégées
   * par aucune authentification.
   */
  @Get('preuves/:id')
  async getProof(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Res() res: Response,
  ) {
    const { data, contentType } = await this.transporteurService.getProofImage(
      this.driverId(req),
      id,
    );
    res.set({
      'Content-Type': contentType,
      'Content-Length': String(data.length),
      // Preuve de livraison : jamais mise en cache par un intermédiaire.
      'Cache-Control': 'private, max-age=300',
    });
    res.send(data);
  }

  @Get('commandes')
  async listOrders(@Request() req: any, @Query() query: ListDriverOrdersQueryDto) {
    return this.transporteurService.listOrders(this.driverId(req), query);
  }

  @Get('commandes/:id')
  async getOrder(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.transporteurService.getOrder(this.driverId(req), id);
  }

  @Post('commandes/:id/accepter')
  async acceptOrder(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.transporteurService.acceptOrder(this.driverId(req), id);
  }

  @Post('commandes/:id/demarrer')
  async startOrder(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.transporteurService.startOrder(this.driverId(req), id);
  }

  @Post('commandes/:id/terminer')
  async completeOrder(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.transporteurService.completeOrder(this.driverId(req), id);
  }

  @Get('commandes/:id/activites-suivantes')
  async getNextActivities(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Query('waypoint') waypoint?: string,
  ) {
    return this.transporteurService.getNextActivities(this.driverId(req), id, waypoint);
  }

  @Post('commandes/:id/activite')
  async updateActivity(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string, @Body() dto: UpdateActivityDto) {
    return this.transporteurService.updateActivity(this.driverId(req), id, dto);
  }

  @Post('commandes/:id/preuve')
  async capturePhoto(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string, @Body() dto: CapturePhotoDto) {
    return this.transporteurService.capturePhoto(this.driverId(req), id, dto);
  }

  @Post('commandes/:id/echec')
  async reportFailure(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Body() dto: ReportDeliveryFailureDto,
  ) {
    return this.transporteurService.reportDeliveryFailure(this.driverId(req), id, dto);
  }
}
