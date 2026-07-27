import { IsEmail, IsString, MinLength, IsOptional } from 'class-validator';

export class MerchantRegisterDto {
  @IsEmail()
  email: string;

  @IsString()
  @MinLength(8)
  password: string;

  @IsString()
  firstName: string;

  @IsString()
  lastName: string;

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
