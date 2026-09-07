/**
 * Tri et filtres de l'onglet « Courses libres » (entreprise de transport).
 *
 * ── Pourquoi un module à part, et pas des méthodes privées du service ───────
 *
 * Trois fonctions pures, éprouvées séparément sur des témoins — même parti pris
 * que `dto-hygiene.spec.ts` (« les détecteurs, purs et éprouvables séparément »)
 * et que `driver-zone.ts`. Un filtre d'argent qui vit dans un service ne se
 * teste qu'à travers Fleetbase ; ici il se teste sur un tableau d'objets.
 *
 * ── Le biais, le même que `zoneAllows` ─────────────────────────────────────
 *
 * Un filtre **absent** ne retire rien. Un filtre **posé** qui ne matche aucune
 * course rend une liste vide — c'est un choix explicite de l'utilisateur, que
 * l'écran distingue de « le pool est vide » (`fleet.opportunities.filtered_empty`
 * contre `fleet.opportunities.empty`). On ne retire jamais une course sur une
 * donnée qu'on **ignore** : une course sans wilaya connue, sans type de véhicule
 * ou sans montant reste visible tant qu'un filtre ne la vise pas nommément.
 */

import { pickupWilaya, sameWilaya } from './driver-zone';

/**
 * Les valeurs de tri reconnues.
 *
 * ⚠️ **Volontairement PAS une liste fermée gardée par `check_closed_lists`.**
 * Une valeur inconnue n'est pas un refus : `sortOpportunities` retombe sur
 * l'ordre naturel de Fleetbase. Le pire cas d'une dérive app/serveur est « le
 * tri n'a pas changé », jamais un 400 sur une saisie légitime — contrairement
 * aux motifs de refus, que le serveur, lui, applique vraiment.
 */
export const FLEET_OPPORTUNITY_SORTS = ['soonest', 'best_paid', 'shortest'] as const;
export type FleetOpportunitySort = (typeof FLEET_OPPORTUNITY_SORTS)[number];

export interface OpportunityFilter {
  /** Wilaya d'ENLÈVEMENT — c'est là que le conducteur se rend d'abord. */
  wilaya?: string | null;
  /** Type de véhicule EXIGÉ par la course (égalité, pas l'échelle du pool). */
  vehicleType?: string | null;
  /** Ne garder que les courses sans montant à encaisser à la porte. */
  withoutCod?: boolean;
}

export interface OpportunityFacets {
  wilayas: string[];
  vehicleTypes: string[];
}

const norm = (v: unknown): string =>
  typeof v === 'string' ? v.trim().toLocaleLowerCase() : '';

/**
 * Wilayas et types de véhicule réellement présents dans le pool.
 *
 * ⚠️ Calculé sur l'ensemble **avant** filtrage : les chips de l'app restent
 * stables et ne disparaissent pas dès qu'un filtre est posé.
 */
export function opportunityFacets(orders: any[]): OpportunityFacets {
  const wilayas = new Set<string>();
  const vehicleTypes = new Set<string>();
  for (const o of orders ?? []) {
    const w = pickupWilaya(o);
    if (w) wilayas.add(w);
    const v = o?.meta?.vehicle_type;
    if (typeof v === 'string' && v.trim()) vehicleTypes.add(v.trim());
  }
  return {
    wilayas: [...wilayas].sort((a, b) => a.localeCompare(b)),
    vehicleTypes: [...vehicleTypes].sort((a, b) => a.localeCompare(b)),
  };
}

/** Applique les filtres. Un champ vide n'est pas un filtre. */
export function filterOpportunities(orders: any[], f: OpportunityFilter): any[] {
  const wantWilaya = f.wilaya?.trim() || null;
  const wantVehicle = norm(f.vehicleType) || null;
  const withoutCod = f.withoutCod === true;

  return (orders ?? []).filter((o: any) => {
    // Course sans wilaya connue : on ne sait pas, on laisse passer — comme
    // `zoneAllowsPickup`. Réutilise `pickupWilaya`/`sameWilaya` (règle 5).
    if (wantWilaya) {
      const w = pickupWilaya(o);
      if (w && !sameWilaya(w, wantWilaya)) return false;
    }

    // ⚠️ Égalité EXACTE, pas l'échelle `suits()` du pool transporteur. Le
    // transporteur demande « ma moto peut-elle faire cette course » (un
    // minimum) ; l'entreprise demande « ne montre que les courses qui exigent
    // tel véhicule » (une égalité). Deux questions, deux prédicats — c'est le
    // critère de la règle 5, pas un oubli de factorisation. Une course sans
    // exigence de véhicule est écartée quand ce filtre est posé : c'est ce que
    // « seulement tel véhicule » veut dire.
    if (wantVehicle && norm(o?.meta?.vehicle_type) !== wantVehicle) return false;

    if (withoutCod) {
      const cod = o?.meta?.cod_amount;
      if (typeof cod === 'number' && cod > 0) return false;
    }

    return true;
  });
}

/**
 * Trie une copie. Une valeur inconnue (ou absente) laisse l'ordre d'entrée —
 * l'ordre naturel de Fleetbase, le plus récemment créé d'abord.
 */
export function sortOpportunities(orders: any[], sort?: string | null): any[] {
  const list = [...(orders ?? [])];

  const byDistance = (o: any) =>
    typeof o?.distance === 'number' && o.distance > 0
      ? o.distance
      : Number.POSITIVE_INFINITY;
  const byPrice = (o: any) =>
    typeof o?.meta?.price === 'number' ? o.meta.price : Number.NEGATIVE_INFINITY;
  // `scheduled_at` absent = course immédiate = la plus urgente, donc en tête.
  const bySchedule = (o: any) => {
    const t = typeof o?.scheduled_at === 'string' ? Date.parse(o.scheduled_at) : NaN;
    return Number.isNaN(t) ? Number.NEGATIVE_INFINITY : t;
  };

  switch (sort) {
    case 'best_paid':
      return list.sort((a, b) => byPrice(b) - byPrice(a));
    case 'shortest':
      return list.sort((a, b) => byDistance(a) - byDistance(b));
    case 'soonest':
      return list.sort((a, b) => bySchedule(a) - bySchedule(b));
    default:
      return list;
  }
}
