import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { json, urlencoded } from 'express';
import { NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { validationExceptionFactory } from './common/errors/validation-exception-factory';

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule);

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

  // ── Confiance au proxy — sans quoi les plafonds de débit sont GLOBAUX ──────
  //
  // `ThrottlerGuard` clef son compteur sur `req.ip`. Express ne renseigne
  // `req.ip` depuis `X-Forwarded-For` que si `trust proxy` est activé : derrière
  // le nginx prévu pour le VPS, `req.ip` vaut l'adresse du proxy, **la même pour
  // tout le monde**. Six requêtes sur `/auth/login` coupaient alors
  // l'authentification de toute la plateforme, et le plafond global de 120/min
  // devenait un déni de service à un curl (revue du 01/08/2026, S2).
  //
  // ⚠️ **Et le piège jumeau est pire.** `trust proxy: true` fait confiance à
  // n'importe quel `X-Forwarded-For`, donc un attaquant change d'adresse à
  // chaque requête et le plafond anti-force-brute de `/auth/login` **disparaît
  // purement**. Passer d'un déni de service à une absence de protection n'est
  // pas une correction.
  //
  // D'où une valeur explicite et jamais `true` : le NOMBRE de proxys entre
  // Internet et ce processus (1 pour un nginx unique), ou une liste d'adresses
  // de confiance. Express ne retient alors que le saut correspondant, et
  // l'en-tête forgé par le client est ignoré.
  //
  // Absente, la valeur vaut 0 : `req.ip` est l'adresse de la socket, ce qui est
  // **juste en développement** et le reste tant qu'il n'y a pas de proxy.
  const trustProxy = process.env.TRUST_PROXY;
  if (trustProxy) {
    const hops = Number(trustProxy);
    app.set('trust proxy', Number.isFinite(hops) && hops > 0 ? hops : trustProxy);
    Logger.log(`Confiance au proxy : ${trustProxy}`, 'Bootstrap');
  }

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
