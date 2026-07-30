import { Injectable, PipeTransform } from '@nestjs/common';
import { badRequest } from '../errors/http-errors';

/**
 * Motif d'identifiant Fleetbase : uuid (8-4-4-4-12) ou public_id
 * (`order_xxx`, `driver_xxx`…). Ni slash, ni point, ni espace.
 */
export const FLEETBASE_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

/**
 * Valide un identifiant Fleetbase pris dans l'URL.
 *
 * Les `@Param('id')` partent interpolés dans une URL Fleetbase appelée avec le
 * token de service, qui a tous les droits sur l'organisation. Sans validation,
 * une valeur comme `../../autre-ressource` détourne la requête vers une route
 * que le contrôle d'appartenance n'a jamais examinée (revue E3/M8).
 *
 * Un pipe plutôt qu'un décorateur de validation : `@Param` n'est pas couvert
 * par le `ValidationPipe` global tant qu'il n'est pas typé par un DTO.
 */
@Injectable()
export class FleetbaseIdPipe implements PipeTransform<string, string> {
  transform(value: string): string {
    if (typeof value !== 'string' || !FLEETBASE_ID_PATTERN.test(value)) {
      badRequest('validation.invalid_id', 'Identifiant invalide');
    }
    return value;
  }
}
