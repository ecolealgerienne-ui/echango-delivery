import {
  ArrayMaxSize,
  ArrayMinSize,
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

import { FLEETBASE_ID_PATTERN } from '../../pipes/fleetbase-id.pipe';
import {
  OrderItemDto,
  POD_METHODS,
  VEHICLE_TYPES,
} from '../../../commercant/dto/create-order.dto';

/**
 * Un arrêt d'une tournée (spec §4).
 *
 * Soit un **dépôt existant** (`depotUuid`), soit un lieu à créer (coordonnées +
 * contact). `type` est déduit si absent : le premier arrêt est un enlèvement,
 * les suivants des livraisons. `items` = les colis pris ou déposés ici ;
 * `codAmount` = les espèces à percevoir à cette porte (le demandeur décide,
 * arrêt par arrêt).
 */
export class TourneeStopDto {
  @IsOptional()
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'depotUuid invalide' })
  depotUuid?: string;

  @IsOptional()
  @IsString()
  @MaxLength(160)
  locationName?: string;

  @IsOptional()
  @IsNumber()
  @Min(-90)
  @Max(90)
  latitude?: number;

  @IsOptional()
  @IsNumber()
  @Min(-180)
  @Max(180)
  longitude?: number;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  contactName?: string;

  @IsOptional()
  @IsString()
  @MaxLength(40)
  contactPhone?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  city?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  province?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  neighborhood?: string;

  @IsOptional()
  @IsString()
  @MaxLength(400)
  notes?: string;

  @IsOptional()
  @IsIn(['pickup', 'dropoff'])
  type?: string;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(20)
  @ValidateNested({ each: true })
  @Type(() => OrderItemDto)
  items?: OrderItemDto[];

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(1)
  @Max(500000)
  codAmount?: number;
}

/**
 * Créer une **tournée multi-arrêt** (spec §4). Une commande Fleetbase à
 * `payload.waypoints[]`, un seul `price` pour toute la route, un `codAmount`
 * par arrêt. Composée entièrement par le demandeur ; le conducteur accepte en
 * bloc.
 */
export class CreateTourneeDto {
  @IsArray()
  @ArrayMinSize(2)
  @ArrayMaxSize(25)
  @ValidateNested({ each: true })
  @Type(() => TourneeStopDto)
  stops: TourneeStopDto[];

  /** Un seul prix pour toute la tournée, à la charge du demandeur. */
  @Type(() => Number)
  @IsNumber()
  @Min(0)
  @Max(500000)
  price: number;

  @IsOptional()
  @IsISO8601()
  scheduledAt?: string;

  @IsOptional()
  @IsIn(VEHICLE_TYPES as unknown as string[])
  vehicleType?: string;

  @IsOptional()
  @IsIn(POD_METHODS as unknown as string[])
  podMethod?: string;

  @IsOptional()
  @IsString()
  @MaxLength(400)
  deliveryInstructions?: string;

  /** Cibler un conducteur (transporteur) OU un favori (commerçant). Le service
   *  n'en lit qu'un selon le persona. */
  @IsOptional()
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'targetUuid invalide' })
  targetUuid?: string;

  @IsOptional()
  @IsBoolean()
  draft?: boolean;
}
