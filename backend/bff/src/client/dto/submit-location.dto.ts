import { IsLatitude, IsLongitude } from 'class-validator';

/**
 * Corps de `POST /public/localisation/:token`
 * (`docs/specs_localisation_client_et_optimisation_parcours.md` §1.6, règle
 * 13 de CLAUDE.md : toute entrée publique traverse un DTO décoré — la plus
 * exposée du lot, puisqu'elle n'exige aucune authentification).
 */
export class SubmitLocationDto {
  @IsLatitude()
  lat: number;

  @IsLongitude()
  lng: number;
}
