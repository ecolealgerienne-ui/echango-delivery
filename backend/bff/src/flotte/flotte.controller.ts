import { Controller, Get, Post, Param, Body, Query, Request } from '@nestjs/common';
import { FleetbaseIdPipe } from '../common/pipes/fleetbase-id.pipe';
import { FlotteService } from './flotte.service';
import { Persona } from '../common/decorators/persona.decorator';
import { ListFleetOrdersQueryDto, AssignDriverDto, DriverPositionsQueryDto } from './dto/order.dto';
import { AddDriverDto } from './dto/driver.dto';
// Réutilisé du module commerçant : la contrainte est la même — au moins trois
// caractères, au plus soixante — et en écrire une copie ferait diverger les deux
// recherches au premier ajustement.
import { DriverSearchDto } from '../commercant/dto/driver-search.dto';

@Persona('fleet')
@Controller('flotte')
export class FlotteController {
  constructor(
    private flotteService: FlotteService,
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


  // ── Caisse : sept routes retirées le 03/08/2026 ──────────────────────────
  //
  // Solde de l'entreprise, encaissements des courses qu'elle facilite, remises
  // et leurs confirmations. Retirées avec le registre de caisse — tenir des
  // soldes est de la trésorerie, pas de la logistique
  // (`docs/registre_caisse_precis.md`).
  //
  // ⚠️ Conséquence assumée : l'entreprise **répond des espèces de ses
  // conducteurs**, et elle en tient le compte chez elle. La plateforme lui dit
  // ce qui a été déclaré à chaque porte, pas ce que chacun lui doit.

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

  /**
   * Le détail d'une course libre, avant de décider.
   *
   * ⚠️ Déclarée **avant** `opportunites/:id/prendre` n'aurait rien changé (Nest
   * apparie sur la méthode ET le chemin), mais elle doit rester avant
   * `commandes/:id` dans l'esprit du lecteur : ce sont deux gardes différentes
   * sur deux populations de courses, et les confondre ouvre l'une par l'autre.
   */
  @Get('opportunites/:id')
  async getClaimableOrderDetail(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) orderId: string,
  ) {
    return this.flotteService.getClaimableOrderDetail(this.fleetId(req), orderId);
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

  /**
   * Chercher un conducteur **déjà dans le réseau**, pour le rattacher.
   *
   * ⚠️ Déclarée avant `drivers/:id/...` n'a pas d'incidence technique, mais
   * `recherche` n'est pas un identifiant : la garder distincte évite qu'un jour
   * quelqu'un la transforme en `drivers/:id` et ouvre l'annuaire par accident.
   */
  @Get('conducteurs/recherche')
  async searchNetworkDrivers(@Request() req: any, @Query() query: DriverSearchDto) {
    return this.flotteService.searchNetworkDrivers(this.fleetId(req), query.q);
  }

  /** Demander le rattachement d'un conducteur existant. Naît `pending`. */
  @Post('conducteurs/:id/adhesion')
  async requestMembership(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) driverUuid: string,
  ) {
    return this.flotteService.requestMembership(this.fleetId(req), driverUuid);
  }

  @Get('adhesions')
  async listMemberships(@Request() req: any) {
    return this.flotteService.listMemberships(this.fleetId(req));
  }

  /**
   * Suspendre ou réactiver un rattachement.
   *
   * Aucune route de suppression, et c'est délibéré : la dette d'un conducteur
   * envers une entreprise survit à leur séparation.
   */
  @Post('adhesions/:id/suspendre')
  async suspendMembership(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) membershipId: string,
  ) {
    return this.flotteService.setMembershipStatus(this.fleetId(req), membershipId, true);
  }

  @Post('adhesions/:id/reactiver')
  async reactivateMembership(
    @Request() req: any,
    @Param('id', FleetbaseIdPipe) membershipId: string,
  ) {
    return this.flotteService.setMembershipStatus(this.fleetId(req), membershipId, false);
  }

  @Post('drivers')
  async addDriver(@Request() req: any, @Body() dto: AddDriverDto) {
    return this.flotteService.addDriver(this.fleetId(req), dto);
  }

  @Get('drivers/positions')
  async getDriverPositions(@Request() req: any, @Query() query: DriverPositionsQueryDto) {
    // ⚠️ Passé par un DTO, pas lu en `@Query('driverIds')` : le
    // `ValidationPipe` ne valide que les classes décorées (règle 13). Avant,
    // une chaîne de dix mille identifiants partait telle quelle interroger
    // Fleetbase, un par un.
    return this.flotteService.getDriverPositions(this.fleetId(req), query.ids());
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
