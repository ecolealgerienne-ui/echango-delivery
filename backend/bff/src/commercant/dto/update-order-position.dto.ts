import { IsLatitude, IsLongitude } from 'class-validator';

/**
 * Corps de `POST /commercant/commandes/:id/position`
 * (`docs/specs_localisation_client_et_optimisation_parcours.md` §1.6).
 *
 * Corrige le point de dépose d'une commande déjà créée — typiquement depuis
 * une fiche client (`Client`) mise à jour après coup. `@IsLatitude()`/
 * `@IsLongitude()` acceptent directement des nombres JSON, sans `@Type()`
 * (utile seulement pour des chaînes de `@Query`, cf. `ReverseGeocodeQueryDto`).
 */
export class UpdateOrderPositionDto {
  @IsLatitude()
  latitude: number;

  @IsLongitude()
  longitude: number;
}
