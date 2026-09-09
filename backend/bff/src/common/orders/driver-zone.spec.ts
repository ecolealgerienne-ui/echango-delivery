/**
 * Ce que ce banc protège : **qu'un filtre ne cache jamais du travail sans le
 * savoir**.
 *
 * La moitié des cas sont donc des cas où le filtre doit **laisser passer** —
 * pas de point d'ancrage, pas de rayon, course sans coordonnées. Ce sont eux
 * qui comptent : un filtre trop large se remarque et s'ajuste, un filtre trop
 * étroit vide une liste sans que personne ne puisse constater ce qui manque.
 *
 * ⚠️ Le filtre spatial de production est celui de Fleetbase (`nearby`/`radius`).
 * `pickupWithinZone` est la revérification en mémoire faite après coup — et le
 * point qu'un banc d'intégration mute pour prouver que le filtre existe.
 */
import {
  DEFAULT_ZONE_RADIUS_KM,
  distanceKm,
  dropoffPoint,
  pickupPoint,
  pickupWilaya,
  pickupWithinZone,
  sameWilaya,
} from './driver-zone';

const order = (opts: {
  province?: string | null;
  coords?: [number, number] | null;
}) => ({
  payload: {
    pickup: {
      province: opts.province ?? undefined,
      location: opts.coords ? { coordinates: opts.coords } : undefined,
    },
  },
});

// Alger centre, et Blida — ~45 km au sud-ouest.
const ALGER = { latitude: 36.7719, longitude: 3.0589 };
const BLIDA = { latitude: 36.4703, longitude: 2.8277 };

// `pickupWilaya`/`sameWilaya` restent exportés : la zone de service ENTREPRISE
// (`flotte`) est toujours une liste de wilayas. Seule la zone CONDUCTEUR est
// passée au point d'ancrage. Ces lectures sont donc encore couvertes.
describe('lire la wilaya d’une course', () => {
  it('la trouve sous le point d’enlèvement', () => {
    expect(pickupWilaya(order({ province: 'Alger' }))).toBe('Alger');
  });

  it('⚠️ la lit d’abord dans `meta` — la LISTE ne sert pas le payload complet', () => {
    expect(pickupWilaya({ meta: { pickup_province: 'Blida' } })).toBe('Blida');
  });

  it('retombe sur le payload quand `meta` ne la porte pas', () => {
    expect(pickupWilaya({ ...order({ province: 'Oran' }), meta: {} })).toBe('Oran');
  });

  it('rend null quand elle manque, jamais une chaîne vide', () => {
    expect(pickupWilaya(order({}))).toBeNull();
    expect(pickupWilaya(order({ province: '   ' }))).toBeNull();
    expect(pickupWilaya(null)).toBeNull();
  });
});

describe('lire le point d’enlèvement', () => {
  it('rend la position, longitude d’abord côté Fleetbase', () => {
    expect(pickupPoint(order({ coords: [3.0589, 36.7719] }))).toEqual(ALGER);
  });

  it('⚠️ [0, 0] est une ABSENCE, pas un point', () => {
    expect(pickupPoint(order({ coords: [0, 0] }))).toBeNull();
  });

  it('rend null quand les coordonnées manquent ou sont incomplètes', () => {
    expect(pickupPoint(order({}))).toBeNull();
    expect(pickupPoint({ payload: { pickup: { location: { coordinates: [3] } } } })).toBeNull();
  });
});

describe('lire le point de dépose (optimisation de parcours)', () => {
  const dropoffOrder = (coords?: [number, number] | null) => ({
    payload: {
      dropoff: {
        location: coords ? { coordinates: coords } : undefined,
      },
    },
  });

  it('rend la position, longitude d’abord côté Fleetbase', () => {
    expect(dropoffPoint(dropoffOrder([3.0589, 36.7719]))).toEqual(ALGER);
  });

  it('⚠️ [0, 0] est une ABSENCE, pas un point — même défaut qu’à l’enlèvement', () => {
    expect(dropoffPoint(dropoffOrder([0, 0]))).toBeNull();
  });

  it('rend null quand les coordonnées manquent ou sont incomplètes', () => {
    expect(dropoffPoint(dropoffOrder())).toBeNull();
    expect(dropoffPoint({ payload: { dropoff: { location: { coordinates: [3] } } } })).toBeNull();
  });

  it('ne se confond pas avec le point d’enlèvement de la même course', () => {
    const enlevementSeul = order({ coords: [3.0589, 36.7719] });
    expect(pickupPoint(enlevementSeul)).toEqual(ALGER);
    expect(dropoffPoint(enlevementSeul)).toBeNull();
  });
});

describe('comparer deux wilayas', () => {
  it('ignore la casse — Fleetbase rend les libellés en MAJUSCULES', () => {
    expect(sameWilaya('ALGER', 'Alger')).toBe(true);
    expect(sameWilaya('  alger ', 'ALGER')).toBe(true);
  });

  it('distingue deux wilayas différentes', () => {
    expect(sameWilaya('Alger', 'Blida')).toBe(false);
  });

  it('une absence n’égale rien, pas même une autre absence', () => {
    expect(sameWilaya(null, 'Alger')).toBe(false);
    expect(sameWilaya(null, null)).toBe(false);
  });
});

describe('la distance', () => {
  it('Alger–Blida tourne autour de quarante kilomètres', () => {
    const d = distanceKm(ALGER, BLIDA);
    expect(d).toBeGreaterThan(30);
    expect(d).toBeLessThan(50);
  });

  it('un point avec lui-même vaut zéro', () => {
    expect(distanceKm(ALGER, ALGER)).toBeCloseTo(0, 5);
  });
});

describe('ce que pickupWithinZone laisse passer', () => {
  const dansAlger = order({ coords: [3.0589, 36.7719] });
  const dansBlida = order({ coords: [2.8277, 36.4703] });

  it('garde une course dont l’enlèvement est dans le rayon du point d’ancrage', () => {
    expect(pickupWithinZone(dansAlger, { center: ALGER, radiusKm: 20 })).toBe(true);
  });

  it('écarte une course dont l’enlèvement est hors du rayon', () => {
    // Témoin du cas précédent : sans lui, « écarte toujours » passerait.
    expect(pickupWithinZone(dansBlida, { center: ALGER, radiusKm: 20 })).toBe(false);
  });

  // ── Les cas qui doivent LAISSER PASSER ────────────────────────────────────
  //
  // Ils sont la raison d'être de ce banc. Chacun décrit une chose qu'on ignore,
  // et dans chacun le filtre doit s'abstenir plutôt que de trancher.

  it('⚠️ pas de point d’ancrage ⇒ tout passe', () => {
    expect(pickupWithinZone(dansBlida, null)).toBe(true);
    expect(pickupWithinZone(dansBlida, undefined)).toBe(true);
    expect(pickupWithinZone(dansBlida, { center: null, radiusKm: 20 })).toBe(true);
  });

  it('⚠️ point d’ancrage mais pas de rayon ⇒ tout passe', () => {
    expect(pickupWithinZone(dansBlida, { center: ALGER, radiusKm: null })).toBe(true);
  });

  it('⚠️ course SANS coordonnées ⇒ elle passe, même sous un rayon serré', () => {
    // Le point vient du géocodage : son absence dit « on ne sait pas », pas
    // « ailleurs ». La cacher retirerait du travail pour un champ non rempli.
    const sansPoint = order({ province: 'ALGER' });
    expect(pickupWithinZone(sansPoint, { center: ALGER, radiusKm: 1 })).toBe(true);
  });

  it('⚠️ course dont le point vaut [0, 0] ⇒ elle passe', () => {
    const nulPart = order({ coords: [0, 0] });
    expect(pickupWithinZone(nulPart, { center: ALGER, radiusKm: 1 })).toBe(true);
  });

  it('la limite est inclusive : l’enlèvement pile au point d’ancrage ⇒ gardé', () => {
    expect(pickupWithinZone(dansAlger, { center: ALGER, radiusKm: 0.5 })).toBe(true);
  });
});

describe('le rayon par défaut', () => {
  it('vaut quinze kilomètres', () => {
    expect(DEFAULT_ZONE_RADIUS_KM).toBe(15);
  });

  it('⚠️ n’est PAS appliqué à qui n’a rien choisi', () => {
    // Le défaut est une proposition d'écran. L'appliquer en silence ferait
    // disparaître du travail pour des gens qui n'ont jamais ouvert le réglage.
    const tresLoin = order({ coords: [5.52, 22.78] }); // Tamanrasset
    expect(pickupWithinZone(tresLoin, null)).toBe(true);
  });
});
