import { Injectable, NestInterceptor, ExecutionContext, CallHandler, Logger } from '@nestjs/common';
import { Observable } from 'rxjs';
import { tap } from 'rxjs/operators';

@Injectable()
export class LoggingInterceptor implements NestInterceptor {
  private readonly logger = new Logger(LoggingInterceptor.name);

  intercept(context: ExecutionContext, next: CallHandler): Observable<any> {
    const request = context.switchToHttp().getRequest();
    const { method, url, ip } = request;
    // ⚠️ Posé par le middleware de `main.ts`, jamais lu directement de
    // l'en-tête : le nettoyage a lieu là-bas, et une valeur brute recopiée ici
    // finirait dans un journal — qu'on lit, et où l'on peut donc injecter.
    const requestId = request.requestId || '-';
    const userAgent = request.get('user-agent');

    const start = Date.now();

    return next.handle().pipe(
      tap((response) => {
        const duration = Date.now() - start;
        this.logger.log(
          `[${requestId}] ${method} ${url} ${ip} - ${userAgent} - ${duration}ms`,
        );
      }),
    );
  }
}
