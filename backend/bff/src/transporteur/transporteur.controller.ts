import { Controller, Get, Post, Body, Param, Query, Request, Res } from '@nestjs/common';
import type { Response } from 'express';
import { FleetbaseIdPipe } from '../common/pipes/fleetbase-id.pipe';
import { TransporteurService } from './transporteur.service';
import { CashService, driverParty, merchantParty } from '../cash/cash.service';
import {
  UpdatePositionDto,
  ToggleOnlineDto,
  UpdateActivityDto,
  ReportDeliveryFailureDto,
  DeclineOrderDto,
  CashCollectionDto,
  DeclareRemittanceDto,
  DisputeRemittanceDto,
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
  constructor(
    private readonly transporteurService: TransporteurService,
    private readonly cash: CashService,
  ) {}

  // ── Caisse ───────────────────────────────────────────────────────────────
  //
  // Le transporteur conserve les espèces qu'il encaisse ; ces routes servent le
  // compte de ce qu'il doit, commerçant par commerçant. La dette n'est pas une
  // somme unique due à la plateforme mais une série de dettes bilatérales, et
  // c'est ainsi qu'elle se règle — un commerçant à la fois, au prochain
  // enlèvement (docs/specs_paiement_livraison.md §6, Voie B).

  @Get('caisse')
  async cashBalances(@Request() req: any) {
    return this.cash.driverBalances(this.driverId(req));
  }

  @Get('caisse/encaissements')
  async cashCollections(@Request() req: any) {
    return this.cash.listCollections('driver', this.driverId(req));
  }

  /**
   * Confirme un encaissement que le COMMERÇANT a déclaré à sa place.
   *
   * Ce cas naît d'une livraison close hors application : le registre n'a rien
   * enregistré, le commerçant a signalé le montant, et c'est cette confirmation
   * qui le rend comptable — avant elle, il ne compte dans aucune dette.
   *
   * La rémunération est écrite dans le même geste, côté service : la course
   * n'en avait pas non plus, et les séparer laisserait entre les deux un état
   * où la dette est fausse.
   */
  @Post('caisse/encaissements/:id/confirmer')
  async confirmCollection(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    // Aucun corps : la rémunération vient de la COMMANDE, jamais du
    // transporteur. La lui faire saisir au moment où il confirme une dette lui
    // laisserait fixer ce qu'il retient dessus.
    return this.transporteurService.confirmDeclaredCollection(this.driverId(req), id);
  }

  /** « Je n'ai pas encaissé cette livraison », ou « pas ce montant ». */
  @Post('caisse/encaissements/:id/contester')
  async disputeCollection(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Body() dto: DisputeRemittanceDto,
  ) {
    return this.cash.disputeCollection(this.driverId(req), id, dto.reason);
  }

  @Get('caisse/remises')
  async cashRemittances(@Request() req: any) {
    return this.cash.listRemittances('driver', this.driverId(req));
  }

  /** « J'ai remis X à ce commerçant. » Reste en attente jusqu'à sa confirmation. */
  @Post('caisse/remises')
  async declareRemittance(@Request() req: any, @Body() dto: DeclareRemittanceDto) {
    // `dto.merchantId` garde son nom — il est gelé par le contrôle de
    // référence — mais désigne désormais **la contrepartie**, que le serveur
    // type lui-même : le commerçant, ou le facilitateur du conducteur.
    return this.cash.declareRemittanceTo(
      driverParty(this.driverId(req)),
      dto.merchantId,
      dto.amount,
    );
  }

  /** Confirme une remise déclarée par le commerçant — jamais une des siennes. */
  @Post('caisse/remises/:id/confirmer')
  async confirmRemittance(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.cash.confirmRemittance('driver', this.driverId(req), id);
  }

  @Post('caisse/remises/:id/contester')
  async disputeRemittance(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Body() dto: DisputeRemittanceDto,
  ) {
    return this.cash.disputeRemittance('driver', this.driverId(req), id, dto.reason);
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
