import { Controller, Get, Post, Param, Body, Query, Request } from '@nestjs/common';
import { FleetbaseIdPipe } from '../common/pipes/fleetbase-id.pipe';
import { FlotteService } from './flotte.service';
import { Persona } from '../common/decorators/persona.decorator';
import { ListFleetOrdersQueryDto, AssignDriverDto } from './dto/order.dto';
import { AddDriverDto } from './dto/driver.dto';
import { CashService, fleetParty } from '../cash/cash.service';
import { FleetRemittanceDto } from './dto/cash.dto';

@Persona('fleet')
@Controller('flotte')
export class FlotteController {
  constructor(
    private flotteService: FlotteService,
    private cash: CashService,
  ) {}

  // ── Caisse ────────────────────────────────────────────────────────────────
  //
  // ⚠️ Ces routes ne sont pas un supplément d'agrément : **sans elles, une dette
  // envers une entreprise n'est confirmable par personne.**
  //
  // Une remise ne réduit la dette qu'après confirmation par l'autre partie.
  // Dès qu'une course porte un facilitateur, le conducteur doit à son
  // entreprise — et si l'entreprise n'a aucune route pour confirmer, la dette
  // reste ouverte indéfiniment, en silence, jusqu'à ce que le plafond bloque le
  // conducteur pour de bon. Le cas est atteignable dès aujourd'hui : il suffit
  // qu'un opérateur rattache une commande à un fournisseur en console.
  //
  // Symétriquement, l'entreprise doit au commerçant, et c'est elle qui déclare
  // ce reversement.

  /** Ce que l'entreprise doit, et ce que ses conducteurs lui doivent. */
  @Get('caisse')
  async cashBalances(@Request() req: any) {
    return this.cash.fleetBalances(this.fleetId(req));
  }

  /** Les encaissements des courses qu'elle a facilitées. */
  @Get('caisse/encaissements')
  async cashCollections(@Request() req: any) {
    return this.cash.listCollections('fleet', this.fleetId(req));
  }

  @Get('caisse/remises')
  async listRemittances(@Request() req: any) {
    return this.cash.listRemittances('fleet', this.fleetId(req));
  }

  /** « J'ai remis X au commerçant », ou « j'ai reçu X de mon conducteur ». */
  @Post('caisse/remises')
  async declareRemittance(@Request() req: any, @Body() dto: FleetRemittanceDto) {
    return this.cash.declareRemittanceTo(
      fleetParty(this.fleetId(req)),
      dto.counterpartyId,
      dto.amount,
    );
  }

  /** Confirme une remise déclarée par l'autre partie — jamais une des siennes. */
  @Post('caisse/remises/:id/confirmer')
  async confirmRemittance(@Request() req: any, @Param('id', FleetbaseIdPipe) id: string) {
    return this.cash.confirmRemittance('fleet', this.fleetId(req), id);
  }

  @Post('caisse/remises/:id/contester')
  async disputeRemittance(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) id: string,
    @Body() dto: { reason?: string },
  ) {
    return this.cash.disputeRemittance('fleet', this.fleetId(req), id, dto?.reason);
  }

  @Get('commandes')
  async getOrders(@Request() req: any, @Query() query: ListFleetOrdersQueryDto) {
    return this.flotteService.getOrders(this.fleetId(req), query);
  }

  /**
   * Les courses libres, que cette entreprise peut réclamer.
   *
   * C'est la porte qui lui donne un rôle **sans obliger le commerçant à la
   * connaître** — donc sans dépendre des favoris polymorphes.
   */
  @Get('opportunites')
  async getClaimableOrders(@Request() req: any, @Query() query: ListFleetOrdersQueryDto) {
    return this.flotteService.getClaimableOrders(this.fleetId(req), query);
  }

  /** Prendre une course du pool. Le second arrivant reçoit `order.already_taken`. */
  @Post('opportunites/:id/prendre')
  async claimOrder(@Request() req: any, @Param('id', FleetbaseIdPipe) orderId: string) {
    return this.flotteService.claimOrder(this.fleetId(req), orderId);
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
