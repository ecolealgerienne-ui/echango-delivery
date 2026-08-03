import { Controller, Get, Post, Put, Body, Param, Query, Request, Res } from '@nestjs/common';
import type { Response } from 'express';
import { FleetbaseIdPipe } from '../common/pipes/fleetbase-id.pipe';
import { TransporteurService } from './transporteur.service';
import {
  UpdatePositionDto,
  ToggleOnlineDto,
  UpdateActivityDto,
  ReportDeliveryFailureDto,
  DeclineOrderDto,
  CashCollectionDto,
  CapturePhotoDto,
  ListDriverOrdersQueryDto,
  UpdateVehicleTypeDto,
  DriverZoneDto,
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

  // ── Caisse : huit routes retirées le 03/08/2026 ──────────────────────────
  //
  // Solde, encaissements, remises et leurs confirmations vivaient ici. Elles
  // tenaient un registre de dettes bilatérales — de la trésorerie, pas de la
  // logistique, et détenir des fonds pour compte de tiers est une activité
  // réglementée qu'un agrégateur n'exerce pas.
  //
  // Ce qui reste du sujet : le montant perçu est déclaré **en clôturant la
  // livraison** (`POST commandes/:id/terminer`) et consigné sur la commande
  // elle-même. Motif complet : `docs/registre_caisse_precis.md`.

  /**
   * La zone de travail : ce que ce transporteur a déclaré vouloir voir.
   *
   * ⚠️ Rend aussi le rayon **proposé par défaut** à qui n'a rien réglé — pour
   * que l'écran le pré-remplisse — sans que ce défaut soit jamais **appliqué**
   * au filtrage. La nuance décide de tout : un défaut appliqué en silence
   * ferait disparaître du travail pour des gens qui n'ont jamais ouvert le
   * réglage, et « le choix revient au transporteur » cesserait d'être vrai.
   */
  @Get('zone')
  async readZone(@Request() req: any) {
    return this.transporteurService.readZone(this.driverId(req));
  }

  @Put('zone')
  async saveZone(@Request() req: any, @Body() dto: DriverZoneDto) {
    return this.transporteurService.saveZone(this.driverId(req), dto);
  }

  // Le contrôle de type est porté par @Persona sur la classe ; il ne reste
  // qu'à extraire l'identifiant.
  private driverId(req: any): string {
    return req.user.id;
  }

  /**
   * Les entreprises pour lesquelles ce conducteur roule, et celles qui le
   * demandent. Un rattachement décide à qui il devra les espèces d'une course.
   */
  @Get('entreprises')
  async listMemberships(@Request() req: any) {
    return this.transporteurService.listMemberships(req.user.id);
  }

  @Post('entreprises/:id/accepter')
  async acceptMembership(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.transporteurService.respondToMembership(req.user.id, id, true);
  }

  @Post('entreprises/:id/refuser')
  async declineMembership(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.transporteurService.respondToMembership(req.user.id, id, false);
  }

  /**
   * Quitter une entreprise à laquelle on est rattaché.
   *
   * ⚠️ `:id` est l'identifiant de **l'adhésion**, pas de l'entreprise — comme
   * sur les deux routes ci-dessus. `listMemberships` rend les deux séparément
   * (`id` et `fleet_id`) ; envoyer le second ici donne un 404 sans indice.
   */
  @Post('entreprises/:id/quitter')
  async leaveFleet(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.transporteurService.leaveFleet(req.user.id, id);
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
  // ⚠️ La route porte l'uuid de la COMMANDE depuis le 03/08/2026. Ce n'est pas
  // cosmétique : servir la preuve exige désormais de résoudre la commande, donc
  // de traverser le contrôle d'assignation qui existe déjà. L'appartenance
  // devient structurelle au lieu de reposer sur un filtre qu'il fallait penser
  // à écrire.
  //
  // L'application suit sans changement : elle reçoit `photo_url` du serveur et
  // le traite comme une chaîne opaque.
  @Get('commandes/:orderId/preuves/:id')
  async getProof(
    @Request() req: any,
    @Param('orderId', FleetbaseIdPipe) orderId: string,
    @Param('id', FleetbaseIdPipe) id: string,
    @Res() res: Response,
  ) {
    const { data, contentType } = await this.transporteurService.getProofImage(
      this.driverId(req),
      orderId,
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

  /**
   * Refus motivé. Sur une course diffusée, elle disparaît de la liste de ce
   * transporteur ; sur une course qui lui était assignée, elle repart au
   * réseau et le commerçant en est informé.
   */
  @Post('commandes/:id/refuser')
  async declineOrder(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Body() dto: DeclineOrderDto,
  ) {
    return this.transporteurService.declineOrder(this.driverId(req), id, dto);
  }

  @Post('commandes/:id/demarrer')
  async startOrder(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.transporteurService.startOrder(this.driverId(req), id);
  }

  /**
   * Clôture la livraison, encaissement compris.
   *
   * Sur une course payée à la réception, le corps DOIT porter le montant perçu :
   * le service refuse la clôture sans lui. « Livré » et « perçu X » sont un seul
   * fait, et les séparer garantirait que le second soit oublié.
   */
  @Post('commandes/:id/terminer')
  async completeOrder(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Body() dto?: CashCollectionDto,
  ) {
    // Corps vide sur une course ordinaire : le DTO n'est appliqué que s'il
    // porte un montant, faute de quoi la validation exigerait `collectedAmount`
    // sur toutes les clôtures.
    const cash = dto && dto.collectedAmount !== undefined ? dto : undefined;
    return this.transporteurService.completeOrder(this.driverId(req), id, cash);
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
