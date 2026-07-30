import { IsString, MaxLength, MinLength } from 'class-validator';

/**
 * Recherche d'un transporteur dans le réseau, pour le mettre en favori.
 *
 * ── Pourquoi une recherche et non un annuaire ───────────────────────────────
 *
 * Un annuaire parcourable livrerait la composition du réseau à quiconque crée
 * un compte — un concurrent inclus. Et il n'aiderait pas : trente noms qu'on ne
 * connaît pas n'apprennent rien, on choisirait au hasard.
 *
 * La recherche sert le seul cas réel : le commerçant **connaît déjà** la
 * personne — le coursier lui a laissé son numéro, un confrère l'a recommandé.
 * Il tape ce qu'il sait.
 *
 * Trois caractères minimum : en dessous, une requête d'une lettre redevient un
 * parcours d'annuaire déguisé.
 */
export class DriverSearchDto {
  @IsString()
  @MinLength(3, {
    message: 'Saisissez au moins 3 caractères du nom ou du téléphone',
  })
  @MaxLength(60)
  q: string;
}
