import { BadRequestException, HttpException, HttpStatus } from '@nestjs/common';

import { ErrorCode } from '../errors/error-codes';
import { HttpExceptionFilter } from './http-exception.filter';

/**
 * Le filet des erreurs imprévues (règle 3).
 *
 * ── Le trou que ces cas ferment ─────────────────────────────────────────────
 *
 * Le filtre était déclaré `@Catch(HttpException)`. Une `TypeError`, une erreur
 * Prisma, un `JSON.parse` raté ne passaient donc pas par lui : ils sortaient
 * par le gestionnaire par défaut de Nest, **sans `code`**. Côté application,
 * `_parseResponse` lit `data['code'] ?? AppError.unknown` — toute panne
 * imprévue arrivait donc en « erreur inconnue », au moment précis où
 * l'utilisateur aurait eu le plus besoin qu'on lui dise quoi faire.
 *
 * ⚠️ **Éprouvé ici plutôt qu'en service, et il faut dire pourquoi.** La
 * tentative de le déclencher en réel — casser `/health` le temps d'une requête
 * — **n'a pas pris effet** : la route a continué de répondre 200, donc cet
 * essai-là ne prouvait rien. Plutôt que de le présenter comme une vérification,
 * on appelle ici le vrai filtre avec une vraie exception. Ce que ces cas ne
 * couvrent pas, en revanche, c'est que Nest le branche bien sur tout —
 * `@Catch()` sans argument s'y charge, et le contrat est celui de Nest.
 */
describe('le filtre d’exception', () => {
  const invoke = (exception: unknown) => {
    const json = jest.fn();
    const status = jest.fn().mockReturnValue({ json });
    const host: any = {
      switchToHttp: () => ({
        getResponse: () => ({ status }),
        getRequest: () => ({ url: '/x', method: 'GET', requestId: 'req-42' }),
      }),
    };
    // Le vrai filtre, pas une copie — sans quoi ce test ne vérifierait que
    // lui-même (règle 5).
    new HttpExceptionFilter().catch(exception as any, host);
    return { status: status.mock.calls[0][0], body: json.mock.calls[0][0] };
  };

  it('donne un code à une exception NON HTTP', () => {
    const { status, body } = invoke(new TypeError('x.y is not a function'));
    expect(status).toBe(HttpStatus.INTERNAL_SERVER_ERROR);
    expect(body.code).toBe(ErrorCode.SERVER_UNEXPECTED);
  });

  it('ne relaie PAS le message d’origine', () => {
    // Une erreur Prisma cite des colonnes, une erreur Axios une URL interne
    // avec ses paramètres : les relayer renseignerait un curieux sur la forme
    // du système. Le détail va au journal.
    const { body } = invoke(new Error('connect ECONNREFUSED 10.0.0.7:3306 · table Order'));
    expect(JSON.stringify(body)).not.toContain('ECONNREFUSED');
    expect(JSON.stringify(body)).not.toContain('Order');
  });

  it('porte l’identifiant de corrélation — le seul fil vers nos journaux', () => {
    expect(invoke(new Error('boum')).body.requestId).toBe('req-42');
  });

  it('tolère ce qui n’est même pas une Error', () => {
    // `throw 'texte'` et `throw {}` existent dans du code tiers ; le filet ne
    // doit pas tomber en essayant de lire une pile absente.
    expect(invoke('juste une chaîne').body.code).toBe(ErrorCode.SERVER_UNEXPECTED);
    expect(invoke({ bizarre: true }).body.code).toBe(ErrorCode.SERVER_UNEXPECTED);
    expect(invoke(null).body.code).toBe(ErrorCode.SERVER_UNEXPECTED);
  });

  it('laisse INTACTES les exceptions HTTP — c’est le témoin', () => {
    // Sans ce cas, un filtre qui écraserait TOUT en `server.unexpected`
    // passerait les quatre premiers : les refus métier perdraient leur code et
    // le test ne le verrait pas.
    const { status, body } = invoke(
      new BadRequestException({ code: 'order.cod_requires_price', message: 'Indiquez le prix' }),
    );
    expect(status).toBe(HttpStatus.BAD_REQUEST);
    expect(body.code).toBe('order.cod_requires_price');
    expect(body.message).toBe('Indiquez le prix');
  });

  it('relaie les champs invalides de la validation', () => {
    const { body } = invoke(
      new HttpException({ code: 'validation.failed', fields: ['email'] }, 400),
    );
    expect(body.fields).toEqual(['email']);
  });
});
