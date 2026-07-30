import { IsString, IsNumber, IsOptional, IsBoolean } from 'class-validator';

/**
 * Seuls `name` et `contactPhone` sont obligatoires (décision produit,
 * 30/07/2026) : un commerçant qui enregistre une adresse connaît le nom du
 * lieu et un numéro à appeler, pas forcément l'adresse postale exacte ni la
 * position sur la carte — ces deux-là se complètent souvent après coup, ou au
 * moment de la commande.
 *
 * `latitude`/`longitude` absentes valent `[0, 0]` côté service
 * (`commercant.service.ts`), la même convention « absence, pas une position »
 * déjà posée pour la position transporteur (`common/geo/driver-position.ts`).
 * L'écran carnet d'adresses détecte déjà ce couple et affiche « Position
 * manquante — à compléter ».
 */
export class SaveAddressDto {
  @IsOptional()
  @IsString()
  label?: string; // 'home', 'work', etc.

  @IsString()
  name: string; // Location name

  @IsOptional()
  @IsNumber()
  latitude?: number;

  @IsOptional()
  @IsNumber()
  longitude?: number;

  @IsOptional()
  @IsString()
  address?: string; // Full address string

  @IsOptional()
  @IsString()
  contactName?: string;

  @IsString()
  contactPhone: string;

  @IsOptional()
  @IsString()
  notes?: string;

  /**
   * Adresse principale du commerçant — préremplit le retrait à la création
   * d'une nouvelle livraison. Une seule à la fois : `commercant.service.ts`
   * retire le drapeau de l'ancienne quand une nouvelle est marquée.
   */
  @IsOptional()
  @IsBoolean()
  isDefault?: boolean;
}
