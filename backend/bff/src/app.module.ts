import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { JwtModule } from '@nestjs/jwt';
import { ThrottlerModule } from '@nestjs/throttler';

import { validateEnv } from './config/env.validation';
import { HealthModule } from './health/health.module';
import { PrismaModule } from './database/prisma.module';
import { AuditModule } from './common/audit/audit.module';
import { FleetbaseModule } from './fleetbase/fleetbase.module';
import { AuthModule } from './auth/auth.module';
import { CommerçantModule } from './commercant/commercant.module';
import { FlotteModule } from './flotte/flotte.module';
import { TransporteurModule } from './transporteur/transporteur.module';
import { CommonModule } from './common/common.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: '.env',
      // Refuse de démarrer si un secret manque ou est trop faible (C1).
      validate: validateEnv,
    }),
    JwtModule.registerAsync({
      global: true,
      inject: [ConfigService],
      // SEUL point de configuration du secret. `global: true` fait que ce
      // JwtService est celui injecté partout — signature (AuthService) comme
      // vérification (JwtAuthGuard). Avant, AuthModule enregistrait son propre
      // JwtModule avec un repli différent : les deux secrets divergeaient dès
      // que la variable manquait, et toutes les requêtes partaient en 401.
      // Aucune valeur de repli ici : validateEnv a déjà refusé le démarrage.
      useFactory: (configService: ConfigService) => ({
        secret: configService.get<string>('JWT_SECRET'),
        signOptions: {
          expiresIn: parseInt(configService.get('JWT_EXPIRATION') || '86400', 10),
        },
      }),
    }),
    // Limitation de débit globale.
    //
    // Sans elle, les endpoints d'authentification acceptaient un bruteforce en
    // ligne illimité (revue E5) — d'autant plus rentable que la politique de
    // mot de passe s'arrête à 8 caractères, et que `loginUnified` coûte trois
    // bcrypt par tentative : l'attaquant envoie une requête HTTP, le serveur
    // dépense ~300 ms de CPU. Le rapport de forces était inversé.
    //
    // Un plafond serré et spécifique est posé sur /auth via @Throttle, celui-ci
    // sert de filet pour le reste de l'API.
    ThrottlerModule.forRoot([
      { name: 'default', ttl: 60_000, limit: 120 },
    ]),
    PrismaModule,
    AuditModule,
    FleetbaseModule,
    HealthModule,
    CommonModule,
    AuthModule,
    CommerçantModule,
    FlotteModule,
    TransporteurModule,
  ],
})
export class AppModule {}
