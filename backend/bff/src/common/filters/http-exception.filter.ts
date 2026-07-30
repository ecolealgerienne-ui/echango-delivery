import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
  Logger,
} from '@nestjs/common';
import { Response } from 'express';

@Catch(HttpException)
export class HttpExceptionFilter implements ExceptionFilter {
  private readonly logger = new Logger(HttpExceptionFilter.name);

  catch(exception: HttpException, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest();
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
