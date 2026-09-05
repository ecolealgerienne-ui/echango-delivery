import { Controller, Get, Post, Put, Delete, Param, Body, Request, Query, Res } from '@nestjs/common';
import type { Response } from 'express';
import { FleetbaseIdPipe } from '../common/pipes/fleetbase-id.pipe';
import { CommerçantService } from './commercant.service';
import { Persona } from '../common/decorators/persona.decorator';
import { CreateOrderDto, ListOrdersQueryDto } from './dto/create-order.dto';
import { RedirectOrderDto } from './dto/redirect-order.dto';
import { UpdateOrderPositionDto } from './dto/update-order-position.dto';
import { SaveAddressDto } from './dto/address.dto';
import { GeocodeQueryDto, ReverseGeocodeQueryDto } from './dto/geocode.dto';
import { AddFavouriteDto } from './dto/favourite.dto';
import { DriverSearchDto } from './dto/driver-search.dto';
import { QuoteRequestDto } from './dto/quote.dto';
import { GeocodingService } from '../common/geocoding/geocoding.service';
import { NotificationsService } from '../notifications/notifications.service';

// Seul des trois contrôleurs à ne pas vérifier le persona jusqu'ici (revue
// E4) : un jeton transporteur ou flotte y était structurellement valide.
@Persona('merchant')
@Controller('commercant')
export class CommerçantController {
  constructor(
    private commercantService: CommerçantService,
    private geocoding: GeocodingService,
    private notifications: NotificationsService,
  ) {}

  // ── Encaissements ────────────────────────────────────────────────────────
  //
  // Sept routes vivaient ici : soldes, remises, confirmations, contestations,
  // et la régularisation d'une livraison close hors application. Retirées le
  // 03/08/2026 avec le registre de caisse — tenir des soldes est de la
  // trésorerie, pas de la logistique (`docs/registre_caisse_precis.md`).
  //
  // Il en reste **une**, et c'est une lecture. Elle sert ce que les commandes
  // de ce commerçant disent de l'argent : attendu à la porte, déclaré perçu par
  // le transporteur, ou terminé sans qu'aucune déclaration n'existe. Aucun
  // solde, aucune dette, aucune confirmation : la matière du rapprochement,
  // que le commerçant fait avec son transporteur.
  //
  // ⚠️ La source est Fleetbase seule. C'est la règle 1 tenue pour de bon — la
  // version précédente croisait Fleetbase et une base locale, donc pouvait
  // servir deux réponses pour la même course.
  @Get('encaissements')
  async collections(@Request() req: any) {
    return this.commercantService.collectionsOnMyOrders(req.user.id);
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

  /**
   * Cherche un transporteur du réseau par nom ou téléphone.
   *
   * Une recherche, pas un annuaire : au-delà de dix correspondances, le serveur
   * demande de préciser plutôt que d'en montrer dix. Une liste tronquée qu'on
   * balaie en changeant une lettre serait l'annuaire qu'on refuse d'ouvrir.
   */
  @Get('transporteurs/recherche')
  async searchDrivers(@Request() req: any, @Query() query: DriverSearchDto) {
    return this.commercantService.searchDrivers(req.user.id, query.q);
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
      dto.partyType ?? 'driver',
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
   * Publie un brouillon : déclenche le dispatch (favori ou pool commun) sur
   * une commande créée sans lui (§ « brouillon », 30/07/2026).
   */
  @Post('commandes/:id/publier')
  async publishOrder(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string) {
    return this.commercantService.publishOrder(req.user.id, orderId);
  }

  /**
   * Change la cible d'une course déjà publiée : un favori nommé, ou le pool
   * commun. Réversible tant que personne ne l'a prise
   * (`docs/plan_ciblage_favori.md`).
   */
  @Post('commandes/:id/rediriger')
  async redirectOrder(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) orderId: string,
    @Body() dto: RedirectOrderDto,
  ) {
    return this.commercantService.redirectOrder(req.user.id, orderId, dto);
  }

  /**
   * Corrige le point de dépose d'une commande déjà créée — typiquement depuis
   * une fiche client mise à jour après coup
   * (`docs/specs_localisation_client_et_optimisation_parcours.md` §1.6).
   */
  @Post('commandes/:id/position')
  async updateOrderPosition(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) orderId: string,
    @Body() dto: UpdateOrderPositionDto,
  ) {
    return this.commercantService.updateOrderDropoffPosition(
      req.user.id,
      orderId,
      dto.latitude,
      dto.longitude,
    );
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

  /**
   * Photo jointe à un signalement d'échec de livraison.
   *
   * ⚠️ La route porte l'uuid de la COMMANDE depuis le 03/08/2026 : servir la
   * preuve exige de la résoudre, donc de traverser le contrôle d'appartenance
   * qui existe déjà. L'application suit sans changement — elle reçoit
   * `photo_url` du serveur et le traite comme une chaîne opaque.
   */
  @Get('commandes/:orderId/preuves/:id')
  async getFailureProof(
    @Request() req: any,
    @Param('orderId', FleetbaseIdPipe) orderId: string,
    @Param('id', FleetbaseIdPipe) id: string,
    @Res() res: Response,
  ) {
    const { data, contentType } = await this.commercantService.getFailureProof(
      req.user.id,
      orderId,
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

  /**
   * Modifie une adresse du carnet.
   *
   * Une adresse enregistrée pré-remplit chaque livraison qui la choisit : un
   * point mal placé ne gêne pas une fois, il se répète.
   */
  @Put('adresses/:id')
  async updateAddress(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Body() dto: SaveAddressDto,
  ) {
    return this.commercantService.updateAddress(req.user.id, id, dto);
  }

  @Delete('adresses/:id')
  async deleteAddress(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.commercantService.deleteAddress(req.user.id, id);
  }
}
