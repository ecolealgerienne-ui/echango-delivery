import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { JwtModule } from '@nestjs/jwt';
import { PassportModule } from '@nestjs/passport';

import { PrismaModule } from './database/prisma.module';
import { FleetbaseModule } from './fleetbase/fleetbase.module';
import { AuthModule } from './auth/auth.module';
import { CommerçantModule } from './commercant/commercant.module';
import { FlotteModule } from './flotte/flotte.module';
import { CommonModule } from './common/common.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: '.env',
    }),
    JwtModule.register({
      secret: process.env.JWT_SECRET || 'dev-secret',
      signOptions: { expiresIn: process.env.JWT_EXPIRATION || '24h' },
    }),
    PassportModule,
    PrismaModule,
    FleetbaseModule,
    CommonModule,
    AuthModule,
    CommerçantModule,
    FlotteModule,
  ],
})
export class AppModule {}
