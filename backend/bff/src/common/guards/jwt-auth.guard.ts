import { Injectable, CanActivate, ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { unauthorized } from '../errors/http-errors';
import { JwtService } from '@nestjs/jwt';
import { IS_PUBLIC_KEY } from '../decorators/public.decorator';
import { PrismaService } from '../../database/prisma.service';

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
    private readonly prisma: PrismaService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
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
      unauthorized('auth.missing_token', 'Missing authorization header');
    }

    const [scheme, token] = authHeader.split(' ');

    if (scheme !== 'Bearer' || !token) {
      unauthorized('auth.missing_token', 'Invalid authorization scheme');
    }

    let payload: any;
    try {
      // `algorithms` explicite : sans contrainte, la bibliothèque accepte tout
      // algorithme annoncé par le jeton lui-même. Le défaut de `jsonwebtoken`
      // écarte déjà `alg:none`, mais le rendre explicite coûte une ligne et
      // supprime la dépendance à ce défaut.
      payload = this.jwtService.verify(token, { algorithms: ['HS256'] });
    } catch {
      unauthorized('auth.token_invalid', 'Invalid or expired token');
    }

    await this.assertSessionStillValid(payload);

    request.user = {
      id: payload.sub,
      email: payload.email,
      type: payload.type,
    };
    return true;
  }

  /**
   * Rejette un jeton dont la session a été révoquée depuis son émission.
   *
   * Le contrôle vit ici plutôt que dans chaque service : les trois modules
   * relisent déjà leur compte à chaque requête, mais rien ne garantit qu'un
   * quatrième persona ou une nouvelle route y penserait. Un contrôle de
   * sécurité qu'il faut se rappeler d'appeler finit par être oublié.
   *
   * Coût : une requête par appel authentifié. Acceptable à cette échelle, et
   * c'est le prix d'une révocation qui prend effet immédiatement plutôt qu'au
   * bout des 24 h de validité du jeton.
   *
   * Un jeton émis avant l'ajout du champ n'a pas de `tv` : il est accepté, la
   * comparaison portant alors sur la valeur par défaut. Les sessions en cours
   * ne sont donc pas coupées par le déploiement.
   */
  private async assertSessionStillValid(payload: any): Promise<void> {
    const claimed = typeof payload?.tv === 'number' ? payload.tv : 0;

    const account = await this.loadAccount(payload?.type, payload?.sub);

    // Compte inconnu ou désactivé : le jeton ne vaut plus rien, quelle que
    // soit sa signature.
    if (!account || account.active === false) {
      unauthorized('auth.token_invalid', 'Invalid or expired token');
    }

    if ((account.tokenVersion ?? 0) !== claimed) {
      unauthorized('auth.session_revoked', 'Session révoquée, reconnectez-vous');
    }
  }

  private async loadAccount(type: string, id: string) {
    const select = { active: true, tokenVersion: true };

    switch (type) {
      case 'transporteur':
        return this.prisma.driverAccount.findUnique({ where: { id }, select });
      case 'merchant':
        return this.prisma.merchantAccount.findUnique({ where: { id }, select });
      case 'fleet':
        return this.prisma.fleetAccount.findUnique({ where: { id }, select });
      default:
        // Type absent ou inconnu : refuser plutôt que laisser passer un jeton
        // qu'aucune table ne revendique.
        return null;
    }
  }
}
