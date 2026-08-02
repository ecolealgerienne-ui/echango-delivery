import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Response } from 'express';

import { ErrorCode } from '../errors/error-codes';

/**
 * ⚠️ **`@Catch()` sans argument : TOUTES les exceptions, pas seulement les HTTP.**
 *
 * La version précédente était `@Catch(HttpException)`. Une `TypeError`, une
 * erreur Prisma, un `JSON.parse` raté ne passaient donc pas par ici : ils
 * sortaient par le gestionnaire par défaut de Nest, **sans `code`**. Côté
 * application, `_parseResponse` lit `data['code'] ?? AppError.unknown` — donc
 * toute panne imprévue arrivait en « erreur inconnue », au moment précis où
 * l'utilisateur aurait eu le plus besoin qu'on lui dise quoi faire.
 *
 * C'était la règle 3 percée sur son chemin le plus obscur : les refus délibérés
 * portaient tous leur code, et les vraies pannes n'en portaient aucun.
 */
@Catch()
export class HttpExceptionFilter implements ExceptionFilter {
  private readonly logger = new Logger(HttpExceptionFilter.name);

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest();

    // ── Ce qui n'est pas une HttpException ────────────────────────────────
    //
    // ⚠️ **Le message d'origine ne sort PAS.** Une erreur Prisma cite des noms
    // de colonnes, une erreur Axios une URL interne avec ses paramètres : les
    // relayer renseignerait un curieux sur la forme du système. Le détail va
    // au journal, où il sert au diagnostic ; le client reçoit un code stable
    // qu'il sait traduire.
    if (!(exception instanceof HttpException)) {
      const status = HttpStatus.INTERNAL_SERVER_ERROR;
      const body = {
        statusCode: status,
        timestamp: new Date().toISOString(),
        path: request.url,
        message: 'Une erreur inattendue est survenue.',
        code: ErrorCode.SERVER_UNEXPECTED,
        // Le seul fil entre l'écran de quelqu'un et nos journaux. Sans lui, un
        // signalement se réduit à « ça a échoué vers 18 h ».
        ...(request.requestId ? { requestId: request.requestId } : {}),
      };
      // `error` en niveau, avec la pile : ce filet ne doit jamais être discret.
      // L'y voir signifie qu'un chemin d'erreur n'avait pas été prévu.
      this.logger.error(
        `[${request.requestId || '-'}] ${request.method} ${request.url} — exception non HTTP`,
        exception instanceof Error ? exception.stack : String(exception),
      );
      response.status(status).json(body);
      return;
    }

    const status = exception.getStatus();
    const exceptionResponse = exception.getResponse() as any;

    const errorResponse = {
      statusCode: status,
      timestamp: new Date().toISOString(),
      path: request.url,
      message: exceptionResponse.message || exception.message,
      error: exceptionResponse.error,
      // ── `code` : un identifiant stable que le client peut tester ─────────
      //
      // Ce filtre reconstruisait un objet à quatre champs et **jetait tout le
      // reste**. Une exception levée avec `{ code, message }` perdait donc son
      // `code` en chemin, en silence.
      //
      // Ce n'était pas seulement gênant pour le refus de connexion d'un
      // commerçant non validé : côté application, `_parseResponse` lit
      // `data['code'] ?? AppError.unknown`, et traite à part les seuls 401 et
      // 404. **Toute autre erreur serveur arrivait donc en `unknown`** — la
      // taxonomie de codes du client n'avait jamais rien reçu à distinguer.
      //
      // Ajouté ici plutôt que dans chaque exception : le filtre est le seul
      // endroit qui voit passer toutes les erreurs, et un oubli y serait
      // global plutôt que ponctuel.
      ...(typeof exceptionResponse?.code === 'string'
        ? { code: exceptionResponse.code }
        : {}),
      // `fields` : uniquement posé par `validationExceptionFactory` — les noms
      // de champs invalides, jamais traduits, à l'usage de qui lit les logs ou
      // le réseau. Le même principe de passthrough que `code` : le filtre ne
      // doit pas décider ce qu'une exception a le droit de porter.
      ...(Array.isArray(exceptionResponse?.fields)
        ? { fields: exceptionResponse.fields }
        : {}),
    };

    this.logger.error(`${request.method} ${request.url}`, errorResponse);

    response.status(status).json(errorResponse);
  }
}
