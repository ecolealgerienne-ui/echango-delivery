import { IsString, IsNumber, IsOptional } from 'class-validator';

export class SaveAddressDto {
  @IsString()
  label: string; // 'home', 'work', etc.

  @IsString()
  name: string; // Location name

  @IsNumber()
  latitude: number;

  @IsNumber()
  longitude: number;

  @IsString()
  address: string; // Full address string

  @IsOptional()
  @IsString()
  contactName?: string;

  @IsOptional()
  @IsString()
  contactPhone?: string;

  @IsOptional()
  @IsString()
  notes?: string;
}
