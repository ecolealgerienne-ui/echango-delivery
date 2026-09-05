import { Injectable, PipeTransform } from '@nestjs/common';
import { badRequest } from '../errors/http-errors';

/**
 * Forme d'un jeton de lien de localisation : `crypto.randomBytes(32)` encodé
 * en base64url (`ClientService.generateLink`) — alphabet `A-Za-z0-9_-`, 43
 * caractères sans le padding `=`.
 */
export const LOCATION_TOKEN_PATTERN = /^[A-Za-z0-9_-]{20,64}$/;

/**
 * Valide la FORME d'un jeton pris dans l'URL publique, avant toute requête en
 * base — ne tranche pas s'il existe ou s'il est encore valide (ça, c'est
 * `ClientService.resolveLinkState`, la même fonction pour la page et la
 * soumission, règle 5). Sans ce filtre, une valeur arbitraire (espaces,
 * `../`, longueur démesurée) atteindrait directement une requête Prisma sur
 * une route publique non authentifiée.
 */
@Injectable()
export class LocationTokenPipe implements PipeTransform<string, string> {
  transform(value: string): string {
    if (typeof value !== 'string' || !LOCATION_TOKEN_PATTERN.test(value)) {
      badRequest('validation.invalid_id', 'Lien invalide');
    }
    return value;
  }
}
