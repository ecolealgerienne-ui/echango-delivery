import {
  filterByServiceZone,
  inServiceZone,
  parseServiceWilayas,
  serialiseServiceWilayas,
} from './fleet-zone';
import { FLEET_ZONE_UNSET } from '../../fleetbase/fleet-zone-fields';

/**
 * La zone de service d'une entreprise — pure, éprouvée sur un tableau.
 *
 * Ce que ces lignes décident : **quel bout du pool une entreprise voit**. Un
 * filtre trop large vide la liste en silence ; un filtre ignoré ne filtre rien.
 * Et le stockage refuse la chaîne vide, d'où l'aller-retour par une sentinelle
 * qu'aucune wilaya ne porte.
 */

const order = (wilaya?: string): any => ({
  uuid: wilaya ?? 'none',
  payload: { pickup: { province: wilaya }, dropoff: {} },
  meta: {},
});

describe('parseServiceWilayas', () => {
  it('sépare une chaîne CSV, nettoie et dédoublonne (casse-insensible)', () => {
    expect(parseServiceWilayas(' Alger , Blida ,alger ')).toEqual(['Alger', 'Blida']);
  });

  it('la sentinelle et le vide donnent une liste vide', () => {
    expect(parseServiceWilayas(FLEET_ZONE_UNSET)).toEqual([]);
    expect(parseServiceWilayas('')).toEqual([]);
    expect(parseServiceWilayas('   ')).toEqual([]);
    expect(parseServiceWilayas(null)).toEqual([]);
    expect(parseServiceWilayas(42)).toEqual([]);
  });

  it('accepte aussi un tableau déjà désérialisé (piège champ `array` Fleetbase)', () => {
    expect(parseServiceWilayas(['Oran', 'Oran', '-', ''])).toEqual(['Oran']);
  });
});

describe('serialiseServiceWilayas', () => {
  it('recompose en CSV, nettoie', () => {
    expect(serialiseServiceWilayas([' Alger ', 'Blida', 'alger'])).toBe('Alger, Blida');
  });

  it('une liste vide devient la sentinelle — jamais la chaîne vide', () => {
    expect(serialiseServiceWilayas([])).toBe(FLEET_ZONE_UNSET);
    expect(serialiseServiceWilayas(['', '  ', '-'])).toBe(FLEET_ZONE_UNSET);
  });

  it('aller-retour : ce qu’on sérialise se relit à l’identique', () => {
    const w = ['Alger', 'Tizi Ouzou', 'Béjaïa'];
    expect(parseServiceWilayas(serialiseServiceWilayas(w))).toEqual(w);
  });
});

describe('inServiceZone — le biais : on ne retire que ce qu’on SAIT hors zone', () => {
  it('zone vide : toute course passe', () => {
    expect(inServiceZone(order('Alger'), [])).toBe(true);
    expect(inServiceZone(order(undefined), [])).toBe(true);
  });

  it('course dans une wilaya de la zone : passe (insensible à la casse)', () => {
    expect(inServiceZone(order('ALGER'), ['Alger', 'Blida'])).toBe(true);
  });

  it('course hors zone : écartée', () => {
    expect(inServiceZone(order('Oran'), ['Alger', 'Blida'])).toBe(false);
  });

  it('course SANS wilaya connue : reste visible même zone posée', () => {
    expect(inServiceZone(order(undefined), ['Alger'])).toBe(true);
  });
});

describe('filterByServiceZone', () => {
  const alger = order('Alger');
  const blida = order('Blida');
  const oran = order('Oran');
  const nowhere = order(undefined);

  it('zone vide : la liste passe telle quelle', () => {
    expect(filterByServiceZone([alger, oran, nowhere], [])).toHaveLength(3);
  });

  it('zone = [Alger, Blida] : garde Alger, Blida et la course sans wilaya ; écarte Oran', () => {
    const kept = filterByServiceZone([alger, blida, oran, nowhere], ['Alger', 'Blida']);
    expect(kept.map((o) => o.uuid).sort()).toEqual(['Alger', 'Blida', 'none']);
  });

  it('témoin négatif : sans le filtre, Oran serait encore là', () => {
    expect(filterByServiceZone([oran], []).map((o) => o.uuid)).toEqual(['Oran']);
  });

  it('zone qui ne matche rien : seule la course sans wilaya reste (jamais tout perdre)', () => {
    const kept = filterByServiceZone([alger, oran, nowhere], ['Tamanrasset']);
    expect(kept.map((o) => o.uuid)).toEqual(['none']);
  });
});
