import { CashService } from './cash.service';

/**
 * Quelles lignes d'encaissement comptent dans une dette.
 *
 * ── Ce que ce test protège ──────────────────────────────────────────────────
 *
 * `debtBetween()` est la fonction qui décide combien un transporteur doit à un
 * commerçant. Sa clause `where` sur les encaissements vient de changer, et deux
 * régressions y sont possibles, silencieuses toutes les deux :
 *
 *  1. **Compter une déclaration non confirmée du commerçant** — un commerçant
 *     pourrait alors inventer une créance sur un transporteur.
 *  2. **Cesser de compter les lignes d'avant la migration** — elles naissent
 *     avec `confirmedAt` nul, et un filtre naïf `confirmedAt: { not: null }`
 *     ferait disparaître toutes les dettes existantes du jour au lendemain.
 *
 * On teste la clause elle-même, telle qu'elle part vers Prisma, plutôt que son
 * résultat : le client Prisma n'est pas généré dans cet environnement (proxy
 * bloquant `binaries.prisma.sh`), et simuler une base ferait vérifier ma
 * simulation plutôt que le code.
 */
describe('debtBetween — les encaissements retenus', () => {
  /** Applique la clause `where` capturée à une ligne, comme le ferait Prisma. */
  const matches = (where: any, row: any): boolean => {
    if (where.driverId !== row.driverId || where.merchantId !== row.merchantId) return false;
    if (!where.OR) return true;
    return where.OR.some((clause: any) => {
      if (clause.declaredBy !== undefined) return row.declaredBy === clause.declaredBy;
      if (clause.confirmedAt?.not === null) return row.confirmedAt !== null;
      return false;
    });
  };

  let captured: any;

  const service = (): CashService => {
    const prisma: any = {
      cashCollection: {
        aggregate: (args: any) => {
          captured = args.where;
          return Promise.resolve({ _sum: { collectedAmount: 0 } });
        },
      },
      driverEarning: { aggregate: () => Promise.resolve({ _sum: { grossAmount: 0 } }) },
      cashRemittance: { aggregate: () => Promise.resolve({ _sum: { amount: 0 } }) },
    };
    return new CashService(
      prisma,
      { get: (): undefined => undefined } as any,
      {} as any,
      {} as any,
    );
  };

  beforeAll(async () => {
    await service().debtBetween('drv-1', 'mer-1');
  });

  it('compte un encaissement déclaré par le transporteur : c\'est sa propre dette', () => {
    expect(
      matches(captured, {
        driverId: 'drv-1',
        merchantId: 'mer-1',
        declaredBy: 'driver',
        confirmedAt: new Date(),
      }),
    ).toBe(true);
  });

  it('compte une ligne HÉRITÉE, sans confirmation — sinon la migration efface les dettes', () => {
    // Ce que devient une ligne écrite avant l'ajout des colonnes : `declaredBy`
    // prend son défaut `driver`, `confirmedAt` reste nul.
    expect(
      matches(captured, {
        driverId: 'drv-1',
        merchantId: 'mer-1',
        declaredBy: 'driver',
        confirmedAt: null,
      }),
    ).toBe(true);
  });

  it('ne compte PAS une déclaration du commerçant en attente de confirmation', () => {
    expect(
      matches(captured, {
        driverId: 'drv-1',
        merchantId: 'mer-1',
        declaredBy: 'merchant',
        confirmedAt: null,
      }),
    ).toBe(false);
  });

  it('compte une déclaration du commerçant une fois confirmée', () => {
    expect(
      matches(captured, {
        driverId: 'drv-1',
        merchantId: 'mer-1',
        declaredBy: 'merchant',
        confirmedAt: new Date(),
      }),
    ).toBe(true);
  });

  it('reste borné aux deux parties concernées', () => {
    expect(
      matches(captured, {
        driverId: 'drv-2',
        merchantId: 'mer-1',
        declaredBy: 'driver',
        confirmedAt: new Date(),
      }),
    ).toBe(false);
  });
});
