import { IsNumber, IsOptional, IsString, Matches, Max, MaxLength, Min } from 'class-validator';
import { Type } from 'class-transformer';
import { FLEETBASE_ID_PATTERN } from '../../transporteur/dto/transporteur.dto';

/**
 * Remise déclarée par le commerçant : « j'ai reçu X de ce transporteur ».
 *
 * Le sens de déclaration n'est pas imposé — celui qui a son téléphone en main
 * au moment où l'argent change de mains n'est pas toujours le même. Quel que
 * soit le déclarant, c'est l'autre partie qui confirme.
 */
export class MerchantRemittanceDto {
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'driverId invalide' })
  driverId: string;

  @Type(() => Number)
  @IsNumber()
  @Min(1)
  @Max(5000000)
  amount: number;
}

export class DisputeRemittanceDto {
  @IsOptional()
  @IsString()
  @MaxLength(500)
  reason?: string;
}
