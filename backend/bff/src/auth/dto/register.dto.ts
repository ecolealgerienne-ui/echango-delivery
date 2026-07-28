import { IsEmail, IsString, MinLength, IsOptional, Matches, IsInt, Min, Max } from 'class-validator';
import { Type } from 'class-transformer';

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
  /**
   * Jeton d'invitation remis par un opérateur Echango, hors bande.
   *
   * Remplace le `fleetbaseDriverUuid` que l'appelant fournissait lui-même :
   * cet uuid est lisible par n'importe quel commerçant sur ses propres
   * commandes, si bien que l'inscription revenait à « premier arrivé, premier
   * servi » sur l'identité d'un transporteur (revue C2). Le driver visé est
   * désormais figé à l'émission de l'invitation, côté serveur.
   */
  @IsString()
  @MinLength(20)
  invitationToken: string;

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

/**
 * Émission d'une invitation transporteur (action opérateur).
 */
export class CreateDriverInvitationDto {
  @IsString()
  @Matches(/^[A-Za-z0-9_-]{1,64}$/, {
    message: 'fleetbaseDriverUuid doit être un identifiant Fleetbase valide',
  })
  fleetbaseDriverUuid: string;

  /** Restreint l'invitation à cet email. Recommandé, non obligatoire. */
  @IsOptional()
  @IsEmail()
  email?: string;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(90)
  validForDays?: number;
}
