import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  NotFoundException,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ErrorCode } from './error-codes';

/**
 * Point de passage unique pour lever une exception HTTP porteuse d'un `code`
 * stable, en plus du message français.
 *
 * ── Pourquoi ça existe ────────────────────────────────────────────────────
 *
 * `HttpExceptionFilter` relaie déjà `code` quand il est présent dans le corps
 * de l'exception (correctif du 29/07/2026). Mais rien n'empêchait un nouveau
 * `throw new BadRequestException('un message')` d'oublier ce champ — et
 * c'était le cas de 122 sites sur 10 fichiers avant cet audit : le message
 * français partait bien jusqu'à l'app, `_parseResponse` lisait
 * `data['code'] ?? AppError.unknown`, et l'app n'avait jamais rien reçu à
 * distinguer pour choisir une traduction.
 *
 * Passer par ces cinq fonctions rend l'oubli visible : un throw direct de
 * `BadRequestException('texte')` ailleurs dans le code se voit à la revue,
 * puisque ce fichier est la seule porte d'entrée documentée.
 *
 * `code` est typé `ErrorCode` (voir `error-codes.ts`), pas `string` : une
 * faute de frappe sur le nom d'un code — `'cash.amont_negative'` — est un
 * refus de compiler, pas un code muet qui atterrit en production sans
 * traduction possible côté client.
 *
 * ── Convention de nommage des codes ──────────────────────────────────────
 *
 * `domaine.motif_en_snake_case`, les mêmes noms que `AppError` côté Flutter
 * (`echango_delivery/lib/errors/app_error.dart`). Les deux listes sont tenues
 * à la main, sans partage de type entre les deux dépôts — la correspondance
 * se vérifie par lecture, comme le reste des contrats entre le BFF et
 * Fleetbase dans ce projet.
 *
 * ── Que se passe-t-il si personne ne traduit un code ? ───────────────────
 *
 * Le client (`translateErrorCode`) retombe sur un message générique localisé
 * plutôt que d'afficher le texte français brut à un utilisateur arabophone.
 * Un code non traduit est donc un défaut silencieux mais jamais un texte
 * dans la mauvaise langue.
 */
export function badRequest(code: ErrorCode, message: string): never {
  throw new BadRequestException({ code, message });
}

export function unauthorized(code: ErrorCode, message: string): never {
  throw new UnauthorizedException({ code, message });
}

export function forbidden(code: ErrorCode, message: string): never {
  throw new ForbiddenException({ code, message });
}

export function notFound(code: ErrorCode, message: string): never {
  throw new NotFoundException({ code, message });
}

export function conflict(code: ErrorCode, message: string): never {
  throw new ConflictException({ code, message });
}

/**
 * 503, et non 400 : l'amont (Fleetbase) est en panne, mais la requête du client
 * est parfaitement valide.
 *
 * Un `4xx` dit « ta requête est fautive », et un client raisonnable en conclut
 * qu'il est inutile de réessayer — exactement le mauvais message quand la seule
 * chose qui cloche est un tiers momentanément injoignable. Un `503` dit « le
 * service est indisponible, réessaie plus tard », ce qui est vrai. Le `code`
 * reste stable pour la traduction ; c'est le STATUT qui mentait
 * (`docs/status_v1.md`, « Un refus amont sort en 400, pas en 503 »).
 */
export function serviceUnavailable(code: ErrorCode, message: string): never {
  throw new ServiceUnavailableException({ code, message });
}
