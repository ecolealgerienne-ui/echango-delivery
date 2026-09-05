import { Controller, Get, Post, Param, Body, Res } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import type { Response } from 'express';
import { Public } from '../common/decorators/public.decorator';
import { ClientService } from './client.service';
import { SubmitLocationDto } from './dto/submit-location.dto';
import { renderLocationPage } from './location-page';

/**
 * Page rechargeable pendant les 10 minutes de validité — pas de bruteforce
 * réaliste sur un token de 32 octets aléatoires, la limite n'est qu'un filet
 * contre un rechargement en boucle.
 */
const THROTTLE_LOCATION_LINK_VIEW = { default: { limit: 30, ttl: 60_000 } };
/** Une soumission par personne raisonnable ; le lien est de toute façon à usage unique. */
const THROTTLE_LOCATION_LINK_SUBMIT = { default: { limit: 10, ttl: 60_000 } };

/**
 * Page publique de partage de position — aucune authentification, aucune
 * donnée métier servie (§1.8 de
 * `docs/specs_localisation_client_et_optimisation_parcours.md`). C'est la
 * seule surface de ce lot qu'un inconnu peut atteindre sans jeton : chaque
 * route porte son propre `@Throttle` (règle 12 de CLAUDE.md).
 */
@Public()
@Controller('public/localisation')
export class ClientPublicController {
  constructor(private clientService: ClientService) {}

  @Throttle(THROTTLE_LOCATION_LINK_VIEW)
  @Get(':token')
  async getPage(@Param('token') token: string, @Res() res: Response) {
    const { state } = await this.clientService.resolveLinkState(token);
    res.type('html').send(renderLocationPage(state, token));
  }

  @Throttle(THROTTLE_LOCATION_LINK_SUBMIT)
  @Post(':token')
  async submit(@Param('token') token: string, @Body() dto: SubmitLocationDto) {
    return this.clientService.submitLocation(token, dto.lat, dto.lng);
  }
}
