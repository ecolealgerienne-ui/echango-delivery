import {
  ArrayMaxSize,
  IsArray,
  IsBoolean,
  IsIn,
  IsISO8601,
  IsNumber,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';

import { FLEETBASE_ID_PATTERN } from '../../common/pipes/fleetbase-id.pipe';
import {
  OrderItemDto,
  POD_METHODS,
  VEHICLE_TYPES,
} from '../../commercant/dto/create-order.dto';

/**
 * Une course créée **par un transporteur national depuis un de ses dépôts**
 * (spec §3.3). L'origine est un dépôt du transporteur (`pickupDepotUuid`,
 * vérifié `assertOwnsDepot`) ; la destination est un client normal.
 *
 * ── Différences avec `CreateOrderDto` (commerçant) ─────────────────────────
 *
 * - **`price` est obligatoire** : c'est le transporteur qui paie son conducteur ;
 * - l'encaissement (`codAmount`) est **autorisé** — le client du transporteur
 *   règle à la porte, comme pour un commerçant (contrairement à une livraison
 *   *vers* un dépôt, où il est interdit) ;
 * - pas de `targetFavouriteUuid` : le transporteur cible **son** conducteur
 *   (`targetDriverUuid`) ou laisse la course confiée (il l'affectera depuis
 *   `/flotte/commandes/:id/assigner`).
 */
export class CreateFleetOrderDto {
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'pickupDepotUuid invalide' })
  pickupDepotUuid: string;

  @IsString()
  dropoffLocationName: string;

  @IsNumber()
  @Min(-90)
  @Max(90)
  dropoffLatitude: number;

  @IsNumber()
  @Min(-180)
  @Max(180)
  dropoffLongitude: number;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  dropoffCity?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  dropoffProvince?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  dropoffNeighborhood?: string;

  @IsString()
  dropoffContactName: string;

  @IsString()
  dropoffContactPhone: string;

  @IsOptional()
  @IsString()
  dropoffNotes?: string;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(20)
  @ValidateNested({ each: true })
  @Type(() => OrderItemDto)
  items?: OrderItemDto[];

  @IsOptional()
  @IsString()
  deliveryInstructions?: string;

  @IsOptional()
  @IsISO8601()
  scheduledAt?: string;

  @IsOptional()
  @IsIn(VEHICLE_TYPES as unknown as string[])
  vehicleType?: string;

  @IsOptional()
  @IsIn(POD_METHODS as unknown as string[])
  podMethod?: string;

  @Type(() => Number)
  @IsNumber()
  @Min(0)
  @Max(500000)
  price: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(1, { message: 'Un encaissement de 0 est une livraison sans encaissement : laissez le champ vide' })
  @Max(500000)
  codAmount?: number;

  @IsOptional()
  @IsBoolean()
  codIncludesDelivery?: boolean;

  /** Un conducteur de CE transporteur, à qui la course est assignée d'emblée. */
  @IsOptional()
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'targetDriverUuid invalide' })
  targetDriverUuid?: string;

  @IsOptional()
  @IsBoolean()
  draft?: boolean;
}
