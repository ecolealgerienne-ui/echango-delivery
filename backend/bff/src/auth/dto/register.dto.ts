import { IsEmail, IsString, MinLength, IsOptional } from 'class-validator';

export class MerchantRegisterDto {
  @IsEmail()
  email: string;

  @IsString()
  @MinLength(8)
  password: string;

  @IsOptional()
  @IsString()
  firstName?: string;

  @IsOptional()
  @IsString()
  lastName?: string;

  @IsString()
  businessName: string;

  @IsOptional()
  @IsString()
  phone?: string;

  @IsOptional()
  @IsString()
  businessPhone?: string;
}

export class MerchantLoginDto {
  @IsEmail()
  email: string;

  @IsString()
  password: string;
}

export class FleetRegisterDto {
  @IsEmail()
  email: string;

  @IsString()
  @MinLength(8)
  password: string;

  @IsOptional()
  @IsString()
  firstName?: string;

  @IsOptional()
  @IsString()
  lastName?: string;

  @IsString()
  businessName: string;

  @IsOptional()
  @IsString()
  phone?: string;

  @IsOptional()
  @IsString()
  businessPhone?: string;
}

export class FleetLoginDto {
  @IsEmail()
  email: string;

  @IsString()
  password: string;
}

// Provisioning is manual (docs/specs_app_transporteur.md §2.1, §13 Q8): an
// Echango operator creates the Fleetbase Driver record first (e.g. via the
// flotte module or the Fleetbase console) and hands the driver its uuid
// out-of-band. Registering here just links an Echango account to that
// already-existing Driver - it never creates one.
export class DriverRegisterDto {
  @IsString()
  fleetbaseDriverUuid: string;

  @IsEmail()
  email: string;

  @IsString()
  @MinLength(8)
  password: string;

  @IsOptional()
  @IsString()
  firstName?: string;

  @IsOptional()
  @IsString()
  lastName?: string;

  @IsOptional()
  @IsString()
  phone?: string;
}

export class DriverLoginDto {
  @IsEmail()
  email: string;

  @IsString()
  password: string;
}
