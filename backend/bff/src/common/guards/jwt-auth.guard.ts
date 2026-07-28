import {
  Injectable,
  CanActivate,
  ExecutionContext,
  UnauthorizedException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { IS_PUBLIC_KEY } from '../decorators/public.decorator';

/**
 * Vérifie le jeton Bearer et pose `request.user`.
 *
 * N'étend plus `AuthGuard('jwt')` : la version précédente surchargeait
 * `canActivate` sans jamais appeler `super.canActivate()`, si bien que Passport
 * et `JwtStrategy` n'étaient jamais sollicités. La stratégie était donc du code
 * mort — un piège classique, puisqu'une modification faite là en croyant
 * durcir l'authentification n'aurait eu aucun effet (revue F15). La stratégie a
 * été supprimée et l'héritage avec.
 */
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly jwtService: JwtService,
  ) {}

  canActivate(context: ExecutionContext): boolean {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);

    if (isPublic) {
      return true;
    }

    const request = context.switchToHttp().getRequest();
    const authHeader = request.headers.authorization;

    if (!authHeader) {
      throw new UnauthorizedException('Missing authorization header');
    }

    const [scheme, token] = authHeader.split(' ');

    if (scheme !== 'Bearer' || !token) {
      throw new UnauthorizedException('Invalid authorization scheme');
    }

    try {
      // `algorithms` explicite : sans contrainte, la bibliothèque accepte tout
      // algorithme annoncé par le jeton lui-même. Le défaut de `jsonwebtoken`
      // écarte déjà `alg:none`, mais le rendre explicite coûte une ligne et
      // supprime la dépendance à ce défaut.
      const payload = this.jwtService.verify(token, { algorithms: ['HS256'] });
      request.user = {
        id: payload.sub,
        email: payload.email,
        type: payload.type,
      };
      return true;
    } catch {
      throw new UnauthorizedException('Invalid or expired token');
    }
  }
}
