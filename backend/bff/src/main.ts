import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { json, urlencoded } from 'express';
import { AppModule } from './app.module';
import { validationExceptionFactory } from './common/errors/validation-exception-factory';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  // Taille de corps explicite.
  //
  // Express plafonne le JSON à 100 ko par défaut — or les preuves de livraison
  // et les photos d'échec transitent en base64 : une photo de téléphone pèse
  // 1 à 4 Mo une fois encodée. La fonctionnalité, pourtant validée côté
  // serveur, était donc inutilisable en conditions réelles (revue archi #4).
  // Le test qui passait au vert envoyait un PNG 1×1 : il ne pouvait pas le
  // révéler.
  //
  // Cette borne va de pair avec celles des DTO (@ArrayMaxSize/@MaxLength sur
  // les photos) : la borne HTTP protège le processus, la borne DTO renvoie une
  // erreur de validation lisible plutôt qu'un 413 opaque.
  const bodyLimit = process.env.MAX_REQUEST_BODY || '10mb';
  app.use(json({ limit: bodyLimit }));
  app.use(urlencoded({ extended: true, limit: bodyLimit }));

  app.enableCors({
    origin: [
      process.env.MERCHANT_APP_URL || 'http://localhost:3000',
      process.env.FLEET_APP_URL || 'http://localhost:3001',
    ],
    credentials: true,
  });

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
      // Sans ceci, un DTO invalide renvoie les messages `class-validator` bruts
      // — toujours en anglais, jamais de `code` — le seul point d'entrée HTTP
      // resté hors du registre après la conversion des 122 exceptions métier
      // (`common/errors/`).
      exceptionFactory: validationExceptionFactory,
    }),
  );

  const port = process.env.PORT || 3001;
  await app.listen(port);

  const logger = new Logger('Bootstrap');
  logger.log(`BFF à l'écoute sur le port ${port} (env: ${process.env.NODE_ENV || 'non défini'})`);
}

bootstrap();
