/**
 * Ce que ce banc protège : **qu'un filtre ne cache jamais du travail sans le
 * savoir**.
 *
 * La moitié des cas sont donc des cas où le filtre doit **laisser passer** —
 * absence de wilaya, absence de position, absence de préférence. Ce sont eux
 * qui comptent : un filtre trop large se remarque et s'ajuste, un filtre trop
 * étroit vide une liste sans que personne ne puisse constater ce qui manque.
 */
import {
  DriverZone,
  DEFAULT_ZONE_RADIUS_KM,
  distanceKm,
  dropoffPoint,
  pickupPoint,
  pickupWilaya,
  sameWilaya,
  zoneAllows,
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

describe('lire la wilaya d’une course', () => {
  it('la trouve sous le point d’enlèvement', () => {
    expect(pickupWilaya(order({ province: 'Alger' }))).toBe('Alger');
  });

  it('⚠️ la lit d’abord dans `meta` — la LISTE ne sert pas le payload complet', () => {
    // Mesuré : la ressource d'index rend un point d'enlèvement à quinze clés,
    // `province` absente, là où la fiche unitaire en rend trente. Le filtre
    // s'appliquant sur la liste, sans cette copie il ne verrait jamais rien —
    // et laisserait donc tout passer, en silence.
    expect(pickupWilaya({ meta: { pickup_province: 'Blida' } })).toBe('Blida');
  });

  it('retombe sur le payload quand `meta` ne la porte pas', () => {
    // Les courses créées avant que la copie existe, et tout appelant qui
    // travaille sur une fiche complète.
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
    // Le défaut déjà corrigé ailleurs : un couple nul est un point au large du
    // golfe de Guinée. Le prendre pour une position ferait filtrer sur une
    // distance imaginaire — et cacherait toutes les courses à ce transporteur.
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
    // Les deux accesseurs lisent des chemins différents : une course dont
    // seul l'enlèvement est connu ne doit jamais faire croire à une dépose.
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

describe('ce que la zone laisse passer', () => {
  const dansAlger = order({ province: 'ALGER', coords: [3.0589, 36.7719] });
  const dansBlida = order({ province: 'BLIDA', coords: [2.8277, 36.4703] });

  it('filtre sur la wilaya déclarée', () => {
    // ⚠️ Type explicite : un `null` nu dans un littéral déclenche TS7018,
    // « implicitly has an 'any' type ». Le piège est documenté dans CLAUDE.md
    // et m'a attrapé deux fois dans la même session.
    const zone: DriverZone = { wilaya: 'Alger', radiusKm: null };
    expect(zoneAllows(dansAlger, zone, null)).toBe(true);
    expect(zoneAllows(dansBlida, zone, null)).toBe(false);
  });

  it('filtre sur le rayon quand on connaît la position', () => {
    const zone: DriverZone = { wilaya: null, radiusKm: 20 };
    expect(zoneAllows(dansAlger, zone, ALGER)).toBe(true);
    expect(zoneAllows(dansBlida, zone, ALGER)).toBe(false);
  });

  // ── Les cas qui doivent LAISSER PASSER ────────────────────────────────────
  //
  // Ils sont la raison d'être de ce banc. Chacun décrit une chose qu'on ignore,
  // et dans chacun le filtre doit s'abstenir plutôt que de trancher.

  it('⚠️ aucune préférence ⇒ tout passe', () => {
    expect(zoneAllows(dansBlida, null, ALGER)).toBe(true);
    const aucune: DriverZone = { wilaya: null, radiusKm: null };
    expect(zoneAllows(dansBlida, aucune, ALGER)).toBe(true);
  });

  it('⚠️ course SANS wilaya ⇒ elle passe, même si une wilaya est exigée', () => {
    // La wilaya vient du géocodage, jamais d'une saisie : son absence dit
    // « on ne sait pas », pas « ailleurs ». La cacher retirerait du travail
    // pour un champ que le commerçant n'a pas rempli.
    const sansWilaya = order({ coords: [2.8277, 36.4703] });
    const zone: DriverZone = { wilaya: 'Alger', radiusKm: null };
    expect(zoneAllows(sansWilaya, zone, null)).toBe(true);
  });

  it('⚠️ transporteur SANS position ⇒ le rayon ne s’applique pas', () => {
    // Sinon un transporteur dont on ignore la position ne verrait AUCUNE
    // course — le pire résultat pour une fonctionnalité censée l'aider.
    const zone: DriverZone = { wilaya: null, radiusKm: 5 };
    expect(zoneAllows(dansBlida, zone, null)).toBe(true);
  });

  it('⚠️ course SANS coordonnées ⇒ le rayon ne s’applique pas', () => {
    const sansPoint = order({ province: 'ALGER' });
    const zone: DriverZone = { wilaya: null, radiusKm: 1 };
    expect(zoneAllows(sansPoint, zone, ALGER)).toBe(true);
  });

  it('⚠️ course dont le point vaut [0, 0] ⇒ elle passe', () => {
    const nulPart = order({ province: 'ALGER', coords: [0, 0] });
    expect(zoneAllows(nulPart, { wilaya: 'Alger', radiusKm: 1 }, ALGER)).toBe(true);
  });

  it('les deux filtres se cumulent : il faut satisfaire l’un ET l’autre', () => {
    const zone: DriverZone = { wilaya: 'Alger', radiusKm: 20 };
    // Bonne wilaya mais trop loin — un point d'Alger à 100 km au large.
    const loinDansAlger = order({ province: 'ALGER', coords: [4.5, 37.4] });
    expect(zoneAllows(loinDansAlger, zone, ALGER)).toBe(false);
  });
});

describe('le rayon par défaut', () => {
  it('vaut quinze kilomètres', () => {
    expect(DEFAULT_ZONE_RADIUS_KM).toBe(15);
  });

  it('⚠️ n’est PAS appliqué à qui n’a rien choisi', () => {
    // Le défaut est une proposition d'écran. L'appliquer en silence ferait
    // disparaître du travail pour des gens qui n'ont jamais ouvert le réglage,
    // et « le choix revient au transporteur » cesserait d'être vrai pour eux.
    const treslLoin = order({ province: 'TAMANRASSET', coords: [5.52, 22.78] });
    expect(zoneAllows(treslLoin, null, ALGER)).toBe(true);
  });
});
