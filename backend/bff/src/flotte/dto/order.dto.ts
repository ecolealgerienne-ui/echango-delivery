import { IsString, IsOptional, IsInt } from 'class-validator';
import { Type } from 'class-transformer';

export class ListFleetOrdersQueryDto {
  @IsOptional()
  @IsString()
  status?: string;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  page?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  limit?: number;
}

export class AssignDriverDto {
  @IsString()
  driverId: string;
}
