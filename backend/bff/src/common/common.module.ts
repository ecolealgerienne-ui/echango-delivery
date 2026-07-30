import { Module } from '@nestjs/common';
import { APP_GUARD, APP_INTERCEPTOR, APP_FILTER } from '@nestjs/core';
import { ThrottlerGuard } from '@nestjs/throttler';
import { JwtAuthGuard } from './guards/jwt-auth.guard';
import { PersonaGuard } from './guards/persona.guard';
import { HttpExceptionFilter } from './filters/http-exception.filter';
import { LoggingInterceptor } from './interceptors/logging.interceptor';

@Module({
  providers: [
    // ThrottlerGuard AVANT JwtAuthGuard : le débit doit être borné avant tout
    // travail coûteux, sinon un attaquant fait dépenser des cycles de
    // vérification de jeton à chaque requête rejetée.
    {
      provide: APP_GUARD,
      useClass: ThrottlerGuard,
    },
    {
      provide: APP_GUARD,
      useClass: JwtAuthGuard,
    },
    // Après JwtAuthGuard : il lit `request.user` que celui-ci vient de poser.
    {
      provide: APP_GUARD,
      useClass: PersonaGuard,
    },
    {
      provide: APP_INTERCEPTOR,
      useClass: LoggingInterceptor,
    },
    {
      provide: APP_FILTER,
      useClass: HttpExceptionFilter,
    },
  ],
})
export class CommonModule {}
