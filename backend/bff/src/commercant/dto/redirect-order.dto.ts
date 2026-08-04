import { IsOptional, IsString, Matches } from 'class-validator';

import { FLEETBASE_ID_PATTERN } from '../../common/pipes/fleetbase-id.pipe';

/**
 * Corps de `POST /commercant/commandes/:id/rediriger`.
 *
 * Un seul champ, deux sens : `targetFavouriteUuid` présent → re-cibler ce favori
 * nommé ; absent → diffuser en large au pool réseau. La même mécanique que la
 * création, appliquée après coup tant que personne n'a pris la course.
 */
export class RedirectOrderDto {
  @IsOptional()
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'targetFavouriteUuid invalide' })
  targetFavouriteUuid?: string;
}
