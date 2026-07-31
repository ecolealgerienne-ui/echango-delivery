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

  /**
   * Commune, telle que le géocodage inverse l'a rendue au moment où le
   * commerçant a posé son point.
   *
   * Facultative, et pas seulement par prudence : elle n'existe que si le
   * commerçant est passé par la carte. Elle est enregistrée parce qu'elle est
   * la seule composante d'adresse **exploitable sans découper une chaîne** —
   * tri par commune, recherche, et affichage court d'une course. Sans elle, il
   * ne reste que l'adresse formatée, dont tout usage structuré repose sur une
   * heuristique de segmentation.
   */
  @IsOptional()
  @IsString()
  city?: string;

  /** Wilaya. */
  @IsOptional()
  @IsString()
  province?: string;

  /** Daïra. */
  @IsOptional()
  @IsString()
  district?: string;

  /** Quartier. */
  @IsOptional()
  @IsString()
  neighborhood?: string;

  @IsOptional()
  @IsString()
  postalCode?: string;

  /**
   * Code ISO-2 en majuscules — `DZ`, pas « Algérie ».
   *
   * La colonne `country` de `Place` stocke un code, que l'accesseur
   * `country_name` résout en nom. Y écrire le nom laisserait ce dernier vide.
   */
  @IsOptional()
  @IsString()
  country?: string;

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
