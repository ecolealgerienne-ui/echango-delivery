import { IsString, MinLength, MaxLength, IsLatitude, IsLongitude } from 'class-validator';
import { Type } from 'class-transformer';

export class GeocodeQueryDto {
  /**
   * Minimum trois caractères : en deçà, Nominatim renvoie du bruit et chaque
   * frappe consommerait un appel du quota partagé.
   */
  @IsString()
  @MinLength(3)
  @MaxLength(200)
  q: string;
}

export class ReverseGeocodeQueryDto {
  @Type(() => Number)
  @IsLatitude()
  lat: number;

  @Type(() => Number)
  @IsLongitude()
  lon: number;
}
