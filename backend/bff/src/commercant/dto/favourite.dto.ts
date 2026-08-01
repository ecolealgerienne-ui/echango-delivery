import { IsString, IsOptional, MaxLength, Matches, IsIn } from 'class-validator';
import { FLEETBASE_ID_PATTERN } from '../../common/pipes/fleetbase-id.pipe';

export class AddFavouriteDto {
  /**
   * `driver` (défaut) ou `fleet`.
   *
   * ⚠️ **Facultatif avec un défaut, et non obligatoire** : l'application
   * envoie aujourd'hui ce corps sans le champ, et l'exiger casserait l'écran
   * des favoris au premier déploiement du serveur — avant même que l'app soit
   * mise à jour. Le défaut vaut ce que faisaient toutes les requêtes jusqu'ici,
   * donc rien ne change pour un client qui l'ignore.
   */
  @IsOptional()
  @IsIn(['driver', 'fleet'])
  partyType?: 'driver' | 'fleet';

  /**
   * Uuid Fleetbase de la partie : un `Driver`, ou un `Vendor` si
   * `partyType = 'fleet'`. Le nom du champ reste `fleetbaseDriverUuid` parce
   * qu'il est déjà lu par l'application ; le renommer casserait l'écran.
   */
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
