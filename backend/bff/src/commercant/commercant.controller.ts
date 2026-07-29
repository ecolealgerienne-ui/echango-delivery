import { Controller, Get, Post, Delete, Param, Body, Request, Query, Res } from '@nestjs/common';
import type { Response } from 'express';
import { FleetbaseIdPipe } from '../common/pipes/fleetbase-id.pipe';
import { CommerçantService } from './commercant.service';
import { Persona } from '../common/decorators/persona.decorator';
import { CreateOrderDto, ListOrdersQueryDto } from './dto/create-order.dto';
import { SaveAddressDto } from './dto/address.dto';
import { GeocodeQueryDto, ReverseGeocodeQueryDto } from './dto/geocode.dto';
import { AddFavouriteDto } from './dto/favourite.dto';
import { QuoteRequestDto } from './dto/quote.dto';
import { GeocodingService } from '../common/geocoding/geocoding.service';
import { NotificationsService } from '../notifications/notifications.service';
import { CashService } from '../cash/cash.service';
import { MerchantRemittanceDto, DisputeRemittanceDto } from './dto/cash.dto';

// Seul des trois contrôleurs à ne pas vérifier le persona jusqu'ici (revue
// E4) : un jeton transporteur ou flotte y était structurellement valide.
@Persona('merchant')
@Controller('commercant')
export class CommerçantController {
  constructor(
    private commercantService: CommerçantService,
    private geocoding: GeocodingService,
    private notifications: NotificationsService,
    private cash: CashService,
  ) {}

  // ── Encaissements ────────────────────────────────────────────────────────
  //
  // Ce que les transporteurs ont perçu pour ce commerçant et ne lui ont pas
  // encore remis. Echango ne détient jamais ces sommes : la remise est physique
  // entre les deux parties, et l'application n'en tient que le registre
  // (docs/specs_paiement_livraison.md §6, Voie B).

  @Get('encaissements')
  async cashBalances(@Request() req: any) {
    return this.cash.merchantBalances(req.user.id);
  }

  @Get('encaissements/details')
  async cashCollections(@Request() req: any) {
    return this.cash.listCollections('merchant', req.user.id);
  }

  @Get('encaissements/remises')
  async remittances(@Request() req: any) {
    return this.cash.listRemittances('merchant', req.user.id);
  }

  /** « J'ai reçu X de ce transporteur. » En attente de sa confirmation. */
  @Post('encaissements/remises')
  async declareRemittance(@Request() req: any, @Body() dto: MerchantRemittanceDto) {
    return this.cash.declareRemittance('merchant', dto.driverId, req.user.id, dto.amount);
  }

  /** Confirme une remise déclarée par le transporteur — jamais une des siennes. */
  @Post('encaissements/remises/:id/confirmer')
  async confirmRemittance(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.cash.confirmRemittance('merchant', req.user.id, id);
  }

  @Post('encaissements/remises/:id/contester')
  async disputeRemittance(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Body() dto: DisputeRemittanceDto,
  ) {
    return this.cash.disputeRemittance('merchant', req.user.id, id, dto.reason);
  }

  // ── Notifications ────────────────────────────────────────────────────────
  //
  // Relevées par interrogation périodique de l'application : l'envoi push vers
  // un commerçant n'est pas branché (voir NotificationsService). Le journal
  // reste la source de vérité, le push ne sera qu'un accélérateur.

  @Get('notifications')
  async listNotifications(@Request() req: any, @Query('nonLues') unreadOnly?: string) {
    return this.notifications.list(req.user.id, unreadOnly === 'true');
  }

  @Post('notifications/tout-lu')
  async markAllNotificationsRead(@Request() req: any) {
    return this.notifications.markAllRead(req.user.id);
  }

  @Post('notifications/:id/lu')
  async markNotificationRead(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.notifications.markRead(req.user.id, id);
  }

  /**
   * Recherche d'adresse. Relayée par le BFF et non appelée depuis l'app :
   * Nominatim exige un User-Agent identifiant et plafonne le débit, deux
   * choses intenables depuis des milliers d'appareils (voir GeocodingService).
   */
  /**
   * Devis d'une course. Appelé par l'app avant validation.
   *
   * Renvoie `amount: null` tant que le barème n'est pas implémenté — l'app
   * conserve alors sa saisie manuelle. L'appel est en place pour que le jour où
   * la formule arrive, rien n'ait à changer côté client.
   */
  @Post('devis')
  async quote(@Request() req: any, @Body() dto: QuoteRequestDto) {
    return this.commercantService.quoteOrder(req.user.id, dto);
  }

  // ── Transporteurs favoris ────────────────────────────────────────────────

  @Get('transporteurs/favoris')
  async listFavourites(@Request() req: any) {
    return this.commercantService.listFavourites(req.user.id);
  }

  /** Transporteurs ayant déjà livré pour ce commerçant, proposables en favori. */
  @Get('transporteurs')
  async listKnownDrivers(@Request() req: any) {
    return this.commercantService.listKnownDrivers(req.user.id);
  }

  @Post('transporteurs/favoris')
  async addFavourite(@Request() req: any, @Body() dto: AddFavouriteDto) {
    return this.commercantService.addFavourite(
      req.user.id,
      dto.fleetbaseDriverUuid,
      dto.driverName,
    );
  }

  @Delete('transporteurs/favoris/:id')
  async removeFavourite(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.commercantService.removeFavourite(req.user.id, id);
  }

  @Get('geocodage')
  async geocode(@Query() query: GeocodeQueryDto) {
    return { data: await this.geocoding.search(query.q) };
  }

  /** Adresse correspondant à un point choisi sur la carte. */
  @Get('geocodage/inverse')
  async reverseGeocode(@Query() query: ReverseGeocodeQueryDto) {
    return this.geocoding.reverse(query.lat, query.lon);
  }

  @Get('commandes')
  async getOrders(@Request() req: any, @Query() query: ListOrdersQueryDto) {
    return this.commercantService.getOrders(req.user.id, query);
  }

  @Get('commandes/:id')
  async getOrderDetail(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string) {
    return this.commercantService.getOrderDetail(req.user.id, orderId);
  }

  /**
   * Champs à reprendre pour recommencer une livraison identique.
   *
   * Ne crée rien : l'application rouvre le formulaire pré-rempli. L'enlèvement
   * programmé n'est volontairement pas repris — celui d'hier est dans le passé.
   */
  @Get('commandes/:id/modele')
  async getOrderTemplate(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string) {
    return this.commercantService.getOrderTemplate(req.user.id, orderId);
  }

  @Post('commandes')
  async createOrder(@Request() req: any, @Body() dto: CreateOrderDto) {
    return this.commercantService.createOrder(req.user.id, dto);
  }

  @Post('commandes/:id/annuler')
  async cancelOrder(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string) {
    return this.commercantService.cancelOrder(req.user.id, orderId);
  }

  /**
   * Dernière position connue du transporteur affecté à cette course.
   *
   * Un point avec sa fraîcheur, pas un itinéraire : l'heure d'arrivée estimée
   * demande un moteur de routage qui n'est pas encore auto-hébergé.
   */
  @Get('commandes/:id/position')
  async getDriverPosition(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string) {
    return this.commercantService.getOrderDriverPosition(req.user.id, orderId);
  }

  /** Preuve de livraison, relayée par le BFF après contrôle d'appartenance. */
  @Get('commandes/:id/preuve')
  async getOrderProof(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) orderId: string,
    @Res() res: Response,
  ) {
    const { data, contentType } = await this.commercantService.getOrderProof(
      req.user.id,
      orderId,
    );
    this.sendImage(res, data, contentType);
  }

  /** Photo jointe à un signalement d'échec de livraison. */
  @Get('preuves/:id')
  async getFailureProof(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Res() res: Response,
  ) {
    const { data, contentType } = await this.commercantService.getFailureProof(
      req.user.id,
      id,
    );
    this.sendImage(res, data, contentType);
  }

  /**
   * `private` dans l'en-tête de cache : une preuve de livraison ne doit jamais
   * être retenue par un intermédiaire partagé.
   */
  private sendImage(res: Response, data: Buffer, contentType: string) {
    res.set({
      'Content-Type': contentType,
      'Content-Length': String(data.length),
      'Cache-Control': 'private, max-age=300',
    });
    res.send(data);
  }

  @Get('commandes/:id/suivi')
  async getOrderTracking(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string) {
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
