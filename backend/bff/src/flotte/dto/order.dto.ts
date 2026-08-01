import { IsInt, IsOptional, IsString, Max, Min } from 'class-validator';
import { Type } from 'class-transformer';

export class ListFleetOrdersQueryDto {
  @IsOptional()
  @IsString()
  status?: string;

  /**
   * ⚠️ **Bornées dans les deux sens.** Sans `@Min`, `?limit=-1` fait basculer
   * Prisma en « les N derniers » ; sans `@Max`, `?limit=1000000` charge et
   * projette tout l'historique, depuis un simple compte valide, et
   * l'amplification pénalise ensuite tout le monde via le plafond global de
   * débit (revue du 01/08/2026, S3).
   *
   * 100 est le plafond que Fleetbase applique de son côté : au-delà, la page
   * demandée n'existe de toute façon pas.
   */
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  page?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}

export class AssignDriverDto {
  @IsString()
  driverId: string;
}
