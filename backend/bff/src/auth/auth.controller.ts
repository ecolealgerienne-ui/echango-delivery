import { Controller, Post, Body, Request } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { AuthService } from './auth.service';
import {
  MerchantRegisterDto,
  MerchantLoginDto,
  FleetRegisterDto,
  FleetLoginDto,
  DriverRegisterDto,
  DriverLoginDto,
  CreateDriverInvitationDto,
} from './dto/register.dto';
import { RegisterDeviceTokenDto } from './dto/device-token.dto';
import { Public } from '../common/decorators/public.decorator';
import { Persona } from '../common/decorators/persona.decorator';

/**
 * Plafonds de débit, ciblés par nature de risque plutôt qu'uniformes.
 *
 * LOGIN : le bruteforce en ligne était illimité (revue E5), et `loginUnified`
 * coûte trois bcrypt par tentative — une requête HTTP achetait ~300 ms de CPU
 * serveur. 5/minute laisse largement place aux fautes de frappe humaines tout
 * en rendant un dictionnaire inexploitable.
 *
 * REGISTER : le risque n'est pas le bruteforce mais la pollution — chaque
 * inscription commerçant ou flotte crée un `Vendor` Fleetbase durable. Un
 * plafond horaire suffit, et reste compatible avec les scripts de test.
 *
 * Un plafond uniforme sur la classe serait plus simple mais casserait les
 * scripts (13 appels d'auth par exécution) sans gain de sécurité : personne ne
 * bruteforce un endpoint d'inscription.
 */
const THROTTLE_LOGIN = { default: { limit: 5, ttl: 60_000 } };
const THROTTLE_REGISTER = { default: { limit: 10, ttl: 3_600_000 } };

@Controller('auth')
export class AuthController {
  constructor(private authService: AuthService) {}

  @Throttle(THROTTLE_REGISTER)
  @Public()
  @Post('merchant/register')
  async registerMerchant(@Body() dto: MerchantRegisterDto) {
    return this.authService.registerMerchant(dto);
  }

  @Throttle(THROTTLE_LOGIN)
  @Public()
  @Post('merchant/login')
  async loginMerchant(@Body() dto: MerchantLoginDto) {
    return this.authService.loginMerchant(dto);
  }

  @Throttle(THROTTLE_REGISTER)
  @Public()
  @Post('flotte/register')
  async registerFleet(@Body() dto: FleetRegisterDto) {
    return this.authService.registerFleet(dto);
  }

  @Throttle(THROTTLE_LOGIN)
  @Public()
  @Post('flotte/login')
  async loginFleet(@Body() dto: FleetLoginDto) {
    return this.authService.loginFleet(dto);
  }

  // Écrit dans DeviceToken, relié à MerchantAccount : sans ce garde, un jeton
  // driver ou flotte visait la mauvaise table (revue E4).
  @Persona('merchant')
  @Post('device-token')
  async registerDeviceToken(@Request() req: any, @Body() dto: RegisterDeviceTokenDto) {
    return this.authService.registerDeviceToken(req.user.id, dto.token, dto.platform);
  }

  /// Connexion unifiée : l'app n'a pas à savoir quel profil est l'utilisateur.
  /// Les endpoints par persona restent en place pour les scripts et les
  /// intégrations existantes.
  @Throttle(THROTTLE_LOGIN)
  @Public()
  @Post('login')
  async loginUnified(@Body() dto: MerchantLoginDto) {
    return this.authService.loginUnified(dto);
  }

  /**
   * Émission d'une invitation transporteur — action opérateur.
   *
   * Réservée au persona `fleet` : c'est le profil qui gère une flotte et
   * provisionne ses transporteurs. Le jeton en clair n'est renvoyé qu'ici, à
   * transmettre hors bande.
   */
  /**
   * Ferme toutes les sessions du compte appelant, y compris celle qui appelle.
   *
   * Aucun persona requis : les trois en ont le même usage — téléphone perdu,
   * doute sur un mot de passe.
   */
  @Post('revoquer-sessions')
  async revokeSessions(@Request() req: any) {
    return this.authService.revokeAllSessions(req.user.id, req.user.type);
  }

  @Persona('fleet')
  @Post('transporteur/invitation')
  async createDriverInvitation(@Request() req: any, @Body() dto: CreateDriverInvitationDto) {
    // `req.user.id` est passé, et ce n'est pas cosmétique : le garde de persona
    // dit **qui** a le droit d'émettre une invitation, jamais **pour quel
    // conducteur**. Sans l'identité de l'appelant, n'importe quel compte flotte
    // pouvait inviter un `Driver` d'une autre flotte — les uuid de conducteurs
    // sortent dans `ORDER_LINK_FIELDS` — et créer son compte applicatif à sa
    // place. Le correctif C2 du 28/07 avait fermé « uuid lu sur une commande » ;
    // l'inscription flotte en libre-service le rouvrait.
    return this.authService.createDriverInvitation(
      req.user.id,
      dto.fleetbaseDriverUuid,
      dto.email,
      dto.validForDays,
    );
  }

  // Publique par nécessité — le transporteur n'a pas encore de compte — mais
  // n'accepte plus qu'un jeton d'invitation émis par un opérateur (revue C2).
  @Throttle(THROTTLE_REGISTER)
  @Public()
  @Post('transporteur/register')
  async registerDriver(@Body() dto: DriverRegisterDto) {
    return this.authService.registerDriver(dto);
  }

  @Throttle(THROTTLE_LOGIN)
  @Public()
  @Post('transporteur/login')
  async loginDriver(@Body() dto: DriverLoginDto) {
    return this.authService.loginDriver(dto);
  }

  @Persona('transporteur')
  @Post('transporteur/device-token')
  async registerDriverDeviceToken(@Request() req: any, @Body() dto: RegisterDeviceTokenDto) {
    return this.authService.registerDriverDeviceToken(req.user.id, dto.token, dto.platform);
  }

  @Post('verify')
  async verifyToken(@Request() req: any) {
    return {
      valid: true,
      user: req.user,
    };
  }
}
