import { IsString, IsOptional, MaxLength, Matches } from 'class-validator';
import { FLEETBASE_ID_PATTERN } from '../../common/pipes/fleetbase-id.pipe';

export class AddFavouriteDto {
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, {
    message: 'fleetbaseDriverUuid doit être un identifiant Fleetbase valide',
  })
  fleetbaseDriverUuid: string;

  /**
   * Nom au moment de la mise en favori, pour l'afficher sans réinterroger
   * Fleetbase à chaque ouverture de l'écran.
   */
  @IsOptional()
  @IsString()
  @MaxLength(120)
  driverName?: string;
}
