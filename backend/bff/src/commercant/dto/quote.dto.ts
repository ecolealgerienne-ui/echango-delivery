import { IsNumber, IsOptional, IsIn, IsISO8601 } from 'class-validator';
import { Type } from 'class-transformer';
import { VEHICLE_TYPES } from './create-order.dto';

/**
 * Demande de devis, avant création de la commande.
 *
 * Volontairement limitée aux paramètres qui influent sur le prix : ni contacts,
 * ni instructions. Un devis n'a pas à connaître le destinataire.
 */
export class QuoteRequestDto {
  @Type(() => Number)
  @IsNumber()
  pickupLatitude: number;

  @Type(() => Number)
  @IsNumber()
  pickupLongitude: number;

  @Type(() => Number)
  @IsNumber()
  dropoffLatitude: number;

  @Type(() => Number)
  @IsNumber()
  dropoffLongitude: number;

  @IsOptional()
  @IsISO8601()
  scheduledAt?: string;

  @IsOptional()
  @IsIn(VEHICLE_TYPES as unknown as string[])
  vehicleType?: string;
}
