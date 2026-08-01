import { ConfigService } from '@nestjs/config';

/**
 * La durée de validité d'un jeton, **dite une seule fois**.
 *
 * ── Le défaut que ceci ferme (revue du 01/08/2026, A8) ───────────────────
 *
 * Le défaut `'86400'` était écrit deux fois : `app.module.ts` **signe** le
 * jeton avec, `auth.service.ts` **annonce** `expires_in` au client avec. Les
 * modifier séparément fait mentir l'API sur l'expiration de son propre jeton —
 * et c'est le genre d'écart qu'aucune erreur ne signale : l'application
 * planifierait son rafraîchissement sur une valeur fausse, et la session
 * tomberait en plein geste.
 *
 * Le critère de la règle 5 répond sans ambiguïté : si l'une change, l'autre
 * doit changer.
 */
export const JWT_EXPIRATION_DEFAULT_SECONDS = 86400;

export function jwtExpirationSeconds(configService: ConfigService): number {
  const configured = parseInt(
    configService.get<string>('JWT_EXPIRATION') || String(JWT_EXPIRATION_DEFAULT_SECONDS),
    10,
  );
  return Number.isFinite(configured) && configured > 0
    ? configured
    : JWT_EXPIRATION_DEFAULT_SECONDS;
}
