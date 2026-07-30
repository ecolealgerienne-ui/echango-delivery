import { Injectable, CanActivate, ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { PERSONA_KEY } from '../decorators/persona.decorator';
import { forbidden } from '../errors/http-errors';

@Injectable()
export class PersonaGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const required = this.reflector.getAllAndOverride<string[]>(PERSONA_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);

    // Aucune exigence déclarée : le JwtAuthGuard a déjà fait son travail.
    if (!required?.length) {
      return true;
    }

    const { user } = context.switchToHttp().getRequest();

    if (!user?.type || !required.includes(user.type)) {
      forbidden(
        'server.persona_forbidden',
        `This endpoint requires one of: ${required.join(', ')}`,
      );
    }

    return true;
  }
}
