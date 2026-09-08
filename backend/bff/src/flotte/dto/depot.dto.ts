import {
  IsNumber,
  IsOptional,
  IsString,
  MaxLength,
  Min,
  Max,
} from 'class-validator';

/**
 * Un dépôt d'un transporteur national.
 *
 * ── Ce qu'un dépôt EST (spec §2.3) ─────────────────────────────────────────
 *
 * Un `Place` Fleetbase possédé par le `Vendor` du transporteur
 * (`owner_type: 'fleet-ops:vendor'`), marqué `meta.is_depot = true`. C'est le
 * patron **exact** du carnet d'adresses d'un commerçant, avec un marqueur de
 * type en `meta` — `Place` n'a pas de colonne `type` native, on suit
 * `meta.is_default`.
 *
 * ── Ce qui est obligatoire, et pourquoi ───────────────────────────────────
 *
 * - le **point** : un dépôt sans coordonnées ne peut être ni une origine ni une
 *   destination de course (une position à `(0,0)` mène au large du golfe de
 *   Guinée — règle 10) ;
 * - le **téléphone** et le **contact** : le conducteur appelle en arrivant au
 *   dépôt ; sans numéro, une porte fermée est un échec qu'on ne peut que
 *   constater.
 *
 * Commune / quartier / wilaya viennent du géocodage inverse, jamais d'une
 * saisie — donc facultatifs (même parti pris que `CreateOrderDto.pickupProvince`
 * et `SaveServiceZoneDto` : aucune liste fermée de wilayas).
 */
export class SaveDepotDto {
  @IsString()
  @MaxLength(120)
  name: string;

  @IsNumber()
  @Min(-90)
  @Max(90)
  latitude: number;

  @IsNumber()
  @Min(-180)
  @Max(180)
  longitude: number;

  @IsString()
  @MaxLength(40)
  phone: string;

  @IsString()
  @MaxLength(120)
  contactName: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  city?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  neighborhood?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  province?: string;

  @IsOptional()
  @IsString()
  @MaxLength(20)
  postalCode?: string;
}
