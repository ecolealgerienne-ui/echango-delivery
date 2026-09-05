import { Injectable, PipeTransform } from '@nestjs/common';
import { badRequest } from '../errors/http-errors';
import { normalizePhone } from '../phone/phone';

/**
 * Normalise et valide un numéro de téléphone pris dans l'URL.
 *
 * Rend directement la forme `+213XXXXXXXXX` — les appelants (`ClientService`)
 * n'ont donc plus à renormaliser eux-mêmes : une seule fonction fait autorité
 * (`normalizePhone`), un seul endroit l'applique à la frontière HTTP (règle 5
 * de CLAUDE.md, même raisonnement que `FleetbaseIdPipe`).
 */
@Injectable()
export class PhoneParamPipe implements PipeTransform<string, string> {
  transform(value: string): string {
    const phone = normalizePhone(value);
    if (!phone) badRequest('client.phone_invalid', 'Numéro de téléphone invalide');
    return phone as string;
  }
}
