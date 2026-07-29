import { Controller, Get, Post, Delete, Param, Body, Request, Query } from '@nestjs/common';
import { FleetbaseIdPipe } from '../common/pipes/fleetbase-id.pipe';
import { CommerçantService } from './commercant.service';
import { Persona } from '../common/decorators/persona.decorator';
import { CreateOrderDto, ListOrdersQueryDto } from './dto/create-order.dto';
import { SaveAddressDto } from './dto/address.dto';
import { GeocodeQueryDto, ReverseGeocodeQueryDto } from './dto/geocode.dto';
import { AddFavouriteDto } from './dto/favourite.dto';
import { QuoteRequestDto } from './dto/quote.dto';
import { GeocodingService } from '../common/geocoding/geocoding.service';

// Seul des trois contrôleurs à ne pas vérifier le persona jusqu'ici (revue
// E4) : un jeton transporteur ou flotte y était structurellement valide.
@Persona('merchant')
@Controller('commercant')
export class CommerçantController {
  constructor(
    private commercantService: CommerçantService,
    private geocoding: GeocodingService,
  ) {}

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

  @Post('commandes')
  async createOrder(@Request() req: any, @Body() dto: CreateOrderDto) {
    return this.commercantService.createOrder(req.user.id, dto);
  }

  @Post('commandes/:id/annuler')
  async cancelOrder(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string) {
    return this.commercantService.cancelOrder(req.user.id, orderId);
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
