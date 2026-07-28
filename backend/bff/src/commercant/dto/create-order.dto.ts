import { IsString, IsNumber, IsOptional, IsArray, IsInt } from 'class-validator';
import { Type } from 'class-transformer';

export class CreateOrderDto {
  @IsString()
  pickupLocationName: string;

  @IsNumber()
  pickupLatitude: number;

  @IsNumber()
  pickupLongitude: number;

  @IsString()
  pickupContactName: string;

  @IsString()
  pickupContactPhone: string;

  @IsOptional()
  @IsString()
  pickupNotes?: string;

  @IsString()
  dropoffLocationName: string;

  @IsNumber()
  dropoffLatitude: number;

  @IsNumber()
  dropoffLongitude: number;

  @IsString()
  dropoffContactName: string;

  @IsString()
  dropoffContactPhone: string;

  @IsOptional()
  @IsString()
  dropoffNotes?: string;

  @IsOptional()
  @IsArray()
  items?: OrderItemDto[];

  @IsOptional()
  @IsString()
  deliveryInstructions?: string;
}

export class OrderItemDto {
  @IsString()
  description: string;

  @IsNumber()
  quantity: number;

  @IsOptional()
  @IsNumber()
  weight?: number;
}

export class ListOrdersQueryDto {
  @IsOptional()
  @IsString()
  status?: string; // 'pending', 'active', 'completed', 'failed', 'cancelled'

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  page?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  limit?: number;
}
