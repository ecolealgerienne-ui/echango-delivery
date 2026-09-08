import {
  ArrayMaxSize,
  IsArray,
  IsBooleanString,
  IsInt,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
} from 'class-validator';
import { Type } from 'class-transformer';

export class ListFleetOrdersQueryDto {
  @IsOptional()
  @IsString()
  status?: string;

  /**
   * ⚠️ **Bornées dans les deux sens.** Sans `@Min`, `?limit=-1` fait basculer
   * Prisma en « les N derniers » ; sans `@Max`, `?limit=1000000` charge et
   * projette tout l'historique, depuis un simple compte valide, et
   * l'amplification pénalise ensuite tout le monde via le plafond global de
   * débit (revue du 01/08/2026, S3).
   *
   * 100 est le plafond que Fleetbase applique de son côté : au-delà, la page
   * demandée n'existe de toute façon pas.
   */
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  page?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}

// Les valeurs de tri reconnues vivent avec la logique qui les applique.
// ⚠️ Pas de `@IsIn` sur le champ `sort` ci-dessous : une valeur inconnue n'est
// pas un refus, `sortOpportunities()` retombe sur l'ordre naturel — motif complet
// dans `opportunity-filters.ts`.
export { FLEET_OPPORTUNITY_SORTS } from '../../common/orders/opportunity-filters';

/**
 * Filtres et tri de l'onglet « Courses libres » (entreprise).
 *
 * Séparé de `ListFleetOrdersQueryDto` — et non ajouté dedans — parce que ces
 * champs n'ont aucun sens sur `GET /flotte/commandes` : les y accepter (même
 * ignorés) brouillerait le contrat. Règle 13 : un `@Query`, une classe décorée
 * qui dit exactement ce que la route prend.
 */
export class ListClaimableOrdersQueryDto extends ListFleetOrdersQueryDto {
  @IsOptional()
  @IsString()
  @MaxLength(20)
  sort?: string;

  /**
   * Wilaya d'ENLÈVEMENT. Le filtre réutilise `pickupWilaya`/`sameWilaya` du
   * module de zone transporteur (règle 5) : c'est là que le conducteur se rend
   * d'abord, donc la seule des deux qui décide.
   */
  @IsOptional()
  @IsString()
  @MaxLength(60)
  wilaya?: string;

  @IsOptional()
  @IsString()
  @MaxLength(40)
  vehicleType?: string;

  /** `'true'` pour ne garder que les courses sans montant à encaisser à la porte. */
  @IsOptional()
  @IsBooleanString()
  withoutCod?: string;
}

export class AssignDriverDto {
  @IsString()
  driverId: string;
}

/**
 * La zone de service d'une entreprise : les wilayas où elle prend des courses
 * libres. Un tableau **vide efface** la préférence (toutes wilayas).
 *
 * ⚠️ Pas de liste fermée de wilayas ici, délibérément — comme
 * `transporteur.dto.ts` : figer les 58 noms dans le DTO ferait refuser une
 * wilaya renommée ou créée. La borne est la **longueur** (une wilaya au plus
 * 60 caractères, 58 au plus dans la liste).
 */
export class SaveServiceZoneDto {
  @IsArray()
  @ArrayMaxSize(58)
  @IsString({ each: true })
  @MaxLength(60, { each: true })
  wilayas: string[];
}

/**
 * Les conducteurs dont on veut la position, en une seule requête.
 *
 * ── Pourquoi une classe pour un seul champ ─────────────────────────────────
 *
 * Le paramètre était lu en `@Query('driverIds') driverIds?: string`, donc
 * **hors du `ValidationPipe`** — qui ne valide que les classes décorées
 * (règle 13). Une chaîne de dix mille identifiants séparés par des virgules
 * était acceptée telle quelle, découpée, et chaque élément partait interroger
 * Fleetbase. Une requête courte faisait faire beaucoup de travail au BFF, sans
 * qu'aucune borne ne s'y oppose.
 *
 * ⚠️ **Le plafond n'est pas une opinion sur le confort** : c'est ce qui borne
 * le travail qu'un appelant peut déclencher. `MAX_DRIVER_POSITIONS` est aligné
 * sur ce qu'une flotte affiche réellement sur une carte ; au-delà, la question
 * n'est plus « où sont mes conducteurs » mais « combien de temps puis-je faire
 * travailler le serveur ».
 */
export const MAX_DRIVER_POSITIONS = 100;

export class DriverPositionsQueryDto {
  @IsOptional()
  @IsString()
  @MaxLength(MAX_DRIVER_POSITIONS * 40, {
    message: 'Trop d’identifiants demandés en une fois',
  })
  @Matches(/^[A-Za-z0-9_,-]*$/, {
    message: 'driverIds ne doit contenir que des identifiants séparés par des virgules',
  })
  driverIds?: string;

  /**
   * La liste effectivement demandée, bornée et dédoublonnée.
   *
   * ⚠️ **Tronquer plutôt que refuser** serait le mauvais choix : une carte
   * silencieusement incomplète est indiscernable de conducteurs hors ligne
   * (règle 10). Au-delà du plafond, la requête est refusée — la borne de
   * longueur ci-dessus s'en charge avant même d'arriver ici.
   */
  ids(): string[] {
    if (!this.driverIds) return [];
    return Array.from(new Set(this.driverIds.split(',').filter(Boolean)))
      .slice(0, MAX_DRIVER_POSITIONS);
  }
}
