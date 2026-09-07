import {
  filterOpportunities,
  opportunityFacets,
  sortOpportunities,
} from './opportunity-filters';

/**
 * Un filtre d'argent testé sur un tableau d'objets, pas à travers Fleetbase.
 *
 * ⚠️ Chaque bloc porte son **cas négatif dans le même passage** : un filtre qui
 * ne retire jamais rien passerait un test qui ne vérifie que « les bonnes
 * courses restent ».
 */

const order = (over: Record<string, any> = {}): any => ({
  uuid: over.uuid ?? 'o',
  distance: over.distance,
  scheduled_at: over.scheduled_at,
  payload: { pickup: { province: over.wilaya }, dropoff: {} },
  meta: {
    vehicle_type: over.vehicle,
    price: over.price,
    cod_amount: over.cod,
  },
});

describe('filterOpportunities — wilaya d’enlèvement', () => {
  const alger = order({ uuid: 'alger', wilaya: 'Alger' });
  const blida = order({ uuid: 'blida', wilaya: 'Blida' });
  const nowhere = order({ uuid: 'nowhere', wilaya: undefined });

  it('ne garde que la wilaya demandée', () => {
    const kept = filterOpportunities([alger, blida], { wilaya: 'Alger' });
    expect(kept.map((o) => o.uuid)).toEqual(['alger']);
  });

  it('témoin négatif : sans filtre, les deux restent', () => {
    expect(filterOpportunities([alger, blida], {})).toHaveLength(2);
  });

  it('insensible à la casse — Fleetbase rend « ALGER »', () => {
    const upper = order({ uuid: 'up', wilaya: 'ALGER' });
    expect(filterOpportunities([upper], { wilaya: 'alger' })).toHaveLength(1);
  });

  it('une course sans wilaya connue reste visible (on ne sait pas ≠ ailleurs)', () => {
    expect(filterOpportunities([nowhere], { wilaya: 'Alger' })).toHaveLength(1);
  });
});

describe('filterOpportunities — type de véhicule (égalité EXACTE)', () => {
  const moto = order({ uuid: 'moto', vehicle: 'moto' });
  const utilitaire = order({ uuid: 'util', vehicle: 'utilitaire' });
  const anyVehicle = order({ uuid: 'any', vehicle: undefined });

  it('ne garde que le type exigé', () => {
    const kept = filterOpportunities([moto, utilitaire], { vehicleType: 'moto' });
    expect(kept.map((o) => o.uuid)).toEqual(['moto']);
  });

  it('n’applique PAS l’échelle du pool : « utilitaire » demandé exclut « moto »', () => {
    const kept = filterOpportunities([moto, utilitaire], {
      vehicleType: 'utilitaire',
    });
    expect(kept.map((o) => o.uuid)).toEqual(['util']);
  });

  it('une course sans exigence est écartée quand ce filtre est posé', () => {
    expect(filterOpportunities([anyVehicle], { vehicleType: 'moto' })).toHaveLength(
      0,
    );
  });

  it('témoin négatif : sans filtre, tout reste', () => {
    expect(
      filterOpportunities([moto, utilitaire, anyVehicle], {}),
    ).toHaveLength(3);
  });
});

describe('filterOpportunities — sans encaissement', () => {
  const withCod = order({ uuid: 'cod', cod: 2000 });
  const zeroCod = order({ uuid: 'zero', cod: 0 });
  const noCod = order({ uuid: 'none', cod: undefined });

  it('retire les courses à encaisser, garde 0 et absent', () => {
    const kept = filterOpportunities([withCod, zeroCod, noCod], {
      withoutCod: true,
    });
    expect(kept.map((o) => o.uuid).sort()).toEqual(['none', 'zero']);
  });

  it('témoin négatif : withoutCod=false ne retire rien', () => {
    expect(
      filterOpportunities([withCod, zeroCod, noCod], { withoutCod: false }),
    ).toHaveLength(3);
  });
});

describe('filterOpportunities — filtres combinés', () => {
  it('applique wilaya ET véhicule ET withoutCod ensemble', () => {
    const target = order({ uuid: 'ok', wilaya: 'Alger', vehicle: 'moto', cod: 0 });
    const wrongWilaya = order({ uuid: 'w', wilaya: 'Oran', vehicle: 'moto', cod: 0 });
    const wrongVehicle = order({ uuid: 'v', wilaya: 'Alger', vehicle: 'voiture', cod: 0 });
    const hasCod = order({ uuid: 'c', wilaya: 'Alger', vehicle: 'moto', cod: 500 });

    const kept = filterOpportunities([target, wrongWilaya, wrongVehicle, hasCod], {
      wilaya: 'Alger',
      vehicleType: 'moto',
      withoutCod: true,
    });
    expect(kept.map((o) => o.uuid)).toEqual(['ok']);
  });
});

describe('sortOpportunities', () => {
  const a = order({ uuid: 'a', price: 100, distance: 9000, scheduled_at: '2026-09-10T10:00:00Z' });
  const b = order({ uuid: 'b', price: 900, distance: 2000, scheduled_at: '2026-09-08T10:00:00Z' });
  const c = order({ uuid: 'c', price: 500, distance: 5000 /* immédiate */ });

  it('best_paid : prix décroissant', () => {
    expect(sortOpportunities([a, b, c], 'best_paid').map((o) => o.uuid)).toEqual([
      'b',
      'c',
      'a',
    ]);
  });

  it('shortest : trajet croissant', () => {
    expect(sortOpportunities([a, b, c], 'shortest').map((o) => o.uuid)).toEqual([
      'b',
      'c',
      'a',
    ]);
  });

  it('soonest : une course immédiate (sans date) passe devant', () => {
    expect(sortOpportunities([a, b, c], 'soonest').map((o) => o.uuid)).toEqual([
      'c',
      'b',
      'a',
    ]);
  });

  it('valeur inconnue ou absente : ordre d’entrée conservé', () => {
    expect(sortOpportunities([a, b, c], undefined).map((o) => o.uuid)).toEqual([
      'a',
      'b',
      'c',
    ]);
    expect(sortOpportunities([a, b, c], 'n’importe quoi').map((o) => o.uuid)).toEqual(
      ['a', 'b', 'c'],
    );
  });

  it('ne mute pas le tableau reçu', () => {
    const input = [a, b, c];
    sortOpportunities(input, 'best_paid');
    expect(input.map((o) => o.uuid)).toEqual(['a', 'b', 'c']);
  });
});

describe('opportunityFacets', () => {
  it('dédoublonne et trie wilayas et véhicules, calculé avant filtrage', () => {
    const orders = [
      order({ wilaya: 'Oran', vehicle: 'moto' }),
      order({ wilaya: 'Alger', vehicle: 'utilitaire' }),
      order({ wilaya: 'Alger', vehicle: 'moto' }),
      order({ wilaya: undefined, vehicle: undefined }),
    ];
    expect(opportunityFacets(orders)).toEqual({
      wilayas: ['Alger', 'Oran'],
      vehicleTypes: ['moto', 'utilitaire'],
    });
  });

  it('tableau vide → facettes vides, pas d’erreur', () => {
    expect(opportunityFacets([])).toEqual({ wilayas: [], vehicleTypes: [] });
  });
});
