import { IsString, IsOptional, IsEmail, IsArray } from 'class-validator';

export class AddDriverDto {
  @IsString()
  name: string;

  @IsOptional()
  @IsEmail()
  email?: string;

  @IsOptional()
  @IsString()
  phone?: string;
}

export class DriverPositionsQueryDto {
  @IsOptional()
  @IsArray()
  driverIds?: string[];
}
