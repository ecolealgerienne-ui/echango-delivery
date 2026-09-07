import {
  MAX_DRIVER_HISTORY_ORDERS,
  selectDriverOrdersToHydrate,
} from './driver-history';

/**
 * Le plafond d'historique de l'écran conducteur, éprouvé sur un tableau.
 *
 * Ce que ces lignes décident n'est pas « combien de courses s'affichent » mais
 * **lesquelles on paie 12-17 s à recharger une par une**. Les cas qui comptent
 * sont les bords : l'exactement-au-plafond, le moins-que-le-plafond, et surtout
 * qu'une course EN COURS n'est jamais sacrifiée pour de l'historique.
 */

type O = { id: string; status: string; updated_at?: string; created_at?: string };
const isFinished = (o: O) => o.status === 'completed' || o.status === 'canceled';

// n courses terminées, horodatées J-1, J-2, … (la 0 est la plus récente).
const finished = (n: number): O[] =>
  Array.from({ length: n }, (_, i) => ({
    id: `f${i}`,
    status: 'completed',
    updated_at: `2026-09-${String(30 - i).padStart(2, '0')}T10:00:00Z`,
  }));

const active = (n: number): O[] =>
  Array.from({ length: n }, (_, i) => ({ id: `a${i}`, status: 'started' }));

describe('selectDriverOrdersToHydrate', () => {
  it('ne plafonne JAMAIS les courses en cours', () => {
    const out = selectDriverOrdersToHydrate([...active(50), ...finished(0)], isFinished);
    expect(out.filter((o) => !isFinished(o))).toHaveLength(50);
  });

  it('plafonne les terminées au maximum, en cours d’abord', () => {
    const out = selectDriverOrdersToHydrate([...active(3), ...finished(40)], isFinished);
    expect(out.filter((o) => !isFinished(o))).toHaveLength(3);
    expect(out.filter(isFinished)).toHaveLength(MAX_DRIVER_HISTORY_ORDERS);
    // Les 3 en cours sortent avant les terminées (l'appelant concatène puis
    // hydrate dans cet ordre).
    expect(out.slice(0, 3).every((o) => !isFinished(o))).toBe(true);
  });

  it('garde les PLUS RÉCENTES parmi les terminées (tri updated_at décroissant)', () => {
    // finished(40) : f0 = 2026-09-30 (la plus récente) … f39 = 2026-08-22.
    const out = selectDriverOrdersToHydrate(finished(40), isFinished, 5);
    expect(out.map((o) => o.id)).toEqual(['f0', 'f1', 'f2', 'f3', 'f4']);
  });

  it('ordre d’entrée quelconque : le tri décide, pas la position', () => {
    const shuffled = [finished(40)[10], finished(40)[0], finished(40)[25], finished(40)[3]];
    const out = selectDriverOrdersToHydrate(shuffled, isFinished, 2);
    expect(out.map((o) => o.id)).toEqual(['f0', 'f3']);
  });

  it('moins de terminées que le plafond : toutes passent', () => {
    const out = selectDriverOrdersToHydrate([...active(1), ...finished(10)], isFinished, 30);
    expect(out.filter(isFinished)).toHaveLength(10);
  });

  it('exactement au plafond : toutes passent, aucune coupée', () => {
    const out = selectDriverOrdersToHydrate(finished(30), isFinished, 30);
    expect(out).toHaveLength(30);
  });

  it('repli sur created_at quand updated_at manque', () => {
    const list: O[] = [
      { id: 'vieux', status: 'completed', created_at: '2026-01-01T00:00:00Z' },
      { id: 'neuf', status: 'completed', created_at: '2026-09-01T00:00:00Z' },
    ];
    expect(selectDriverOrdersToHydrate(list, isFinished, 1).map((o) => o.id)).toEqual([
      'neuf',
    ]);
  });

  it('tableau vide → tableau vide, pas d’erreur', () => {
    expect(selectDriverOrdersToHydrate([], isFinished)).toEqual([]);
  });

  it('témoin négatif : sans plafond effectif, les 40 terminées reviennent', () => {
    const out = selectDriverOrdersToHydrate(finished(40), isFinished, 1000);
    expect(out).toHaveLength(40);
  });
});
