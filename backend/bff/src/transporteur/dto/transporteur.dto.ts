import {
  IsString,
  IsOptional,
  IsBoolean,
  IsNumber,
  IsArray,
  IsIn,
  IsObject,
  ArrayMinSize,
  MaxLength,
} from 'class-validator';
import { Type } from 'class-transformer';

export class UpdatePositionDto {
  @Type(() => Number)
  @IsNumber()
  latitude: number;

  @Type(() => Number)
  @IsNumber()
  longitude: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  altitude?: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  heading?: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  speed?: number;
}

export class ToggleOnlineDto {
  // Always explicit. Fleetbase's toggle-online will flip the current value if
  // `online` is omitted, which would desync on a retried request.
  @IsBoolean()
  online: boolean;
}

export class UpdateActivityDto {
  // A full Activity object taken from the order config, not a status string —
  // that is what POST /v1/orders/{id}/update-activity validates against.
  @IsObject()
  activity: Record<string, any>;

  @IsOptional()
  @IsString()
  proof?: string;
}

/**
 * Short, delivery-specific list from docs/specs_app_transporteur.md §4.3 —
 * deliberately not Navigator's 9 generic fleet-ops incident categories.
 * Marked there as "to validate with the business side", so treat this as a
 * starting point rather than settled.
 */
export const DELIVERY_FAILURE_REASONS = [
  'client_absent',
  'adresse_introuvable',
  'colis_refuse',
  'colis_endommage',
  'acces_impossible',
  'autre',
] as const;

export class ReportDeliveryFailureDto {
  @IsIn(DELIVERY_FAILURE_REASONS as unknown as string[])
  reason: string;

  @IsOptional()
  @IsString()
  @MaxLength(1000)
  notes?: string;

  @IsOptional()
  @IsString()
  waypointUuid?: string;

  // Base64-encoded image. The Fleetbase capture-photo controller accepts
  // base64 strings as well as multipart uploads, which keeps this a plain
  // JSON endpoint.
  @IsOptional()
  @IsString()
  photo?: string;
}

export class CapturePhotoDto {
  @IsArray()
  @ArrayMinSize(1)
  @IsString({ each: true })
  photos: string[];

  @IsOptional()
  @IsString()
  @MaxLength(255)
  remarks?: string;

  @IsOptional()
  @IsString()
  subjectId?: string;
}

export class ListDriverOrdersQueryDto {
  @IsOptional()
  @IsString()
  status?: string;

  @IsOptional()
  @IsIn(['assigned', 'adhoc', 'history'])
  type?: string;
}
