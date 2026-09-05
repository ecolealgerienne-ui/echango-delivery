import { Controller, Get, Post, Param, Request } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { Persona } from '../common/decorators/persona.decorator';
import { PhoneParamPipe } from '../common/pipes/phone.pipe';
import { ClientService } from './client.service';

/**
 * 50/heure par commerçant — décision utilisateur (débit de génération de
 * liens, anti-abus, §1.10 de
 * `docs/specs_localisation_client_et_optimisation_parcours.md`). Assez large
 * pour un usage normal (plusieurs commandes par heure), assez serré pour
 * limiter un envoi massif de liens vers des numéros arbitraires.
 */
const THROTTLE_LOCATION_LINK_GENERATE = { default: { limit: 50, ttl: 3_600_000 } };

/**
 * Fiche client géolocalisée, côté commerçant — routes authentifiées.
 *
 * Aucun contrôle d'appartenance de ressource au-delà de `@Persona('merchant')` :
 * la fiche est platform-wide (§1.3), pas rattachée à un commerçant en
 * particulier — n'importe quel commerçant du réseau peut consulter ou
 * proposer une position pour n'importe quel numéro.
 */
@Persona('merchant')
@Controller('commercant/clients')
export class ClientController {
  constructor(private clientService: ClientService) {}

  @Get(':telephone')
  async getClient(@Request() req: any, @Param('telephone', PhoneParamPipe) telephone: string) {
    return this.clientService.getClient(req.user.id, telephone);
  }

  @Throttle(THROTTLE_LOCATION_LINK_GENERATE)
  @Post(':telephone/lien-position')
  async generateLink(@Request() req: any, @Param('telephone', PhoneParamPipe) telephone: string) {
    return this.clientService.generateLink(req.user.id, telephone);
  }

  @Post(':telephone/confirmer')
  async confirm(@Request() req: any, @Param('telephone', PhoneParamPipe) telephone: string) {
    return this.clientService.confirmPending(req.user.id, telephone);
  }

  @Post(':telephone/rejeter')
  async reject(@Request() req: any, @Param('telephone', PhoneParamPipe) telephone: string) {
    return this.clientService.rejectPending(req.user.id, telephone);
  }
}
