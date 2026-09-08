/**
 * La zone de service d'une **entreprise de transport** : les wilayas où elle
 * prend des courses libres.
 *
 * ── Le pendant de `driver-zone.ts`, avec deux différences assumées ──────────
 *
 * 1. **Plusieurs wilayas**, pas une seule — une entreprise en dessert plusieurs.
 * 2. **Pas de rayon** — une entreprise n'a pas de position unique ; le filtre
 *    est la wilaya, et rien d'autre.
 *
 * ── Le même biais que `zoneAllowsPickup` (règle 10) ────────────────────────
 *
 * Une zone vide ne filtre rien. Une course **sans wilaya connue** reste
 * visible même quand la zone est posée : le champ vient du géocodage inverse,
 * jamais d'une saisie — l'absence dit « on ne sait pas », pas « ailleurs ». On
 * ne retire de la liste que ce qu'on **sait** être hors zone. Une course
 * offerte puis écartée est un désagrément ; une course jamais montrée est un
 * manque à gagner que personne ne peut constater.
 */

import { pickupWilaya, sameWilaya } from './driver-zone';
import { FLEET_ZONE_UNSET } from '../../fleetbase/fleet-zone-fields';

/**
 * Sépare la valeur stockée (wilayas séparées par des virgules, ou la
 * sentinelle) en une liste nettoyée et dédoublonnée, en préservant l'ordre.
 */
export function parseServiceWilayas(raw: unknown): string[] {
  if (Array.isArray(raw)) {
    return dedupe(
      raw
        .filter((w): w is string => typeof w === 'string')
        .map((w) => w.trim())
        .filter((w) => w && w !== FLEET_ZONE_UNSET),
    );
  }
  if (typeof raw !== 'string') return [];
  const trimmed = raw.trim();
  if (!trimmed || trimmed === FLEET_ZONE_UNSET) return [];
  return dedupe(
    trimmed
      .split(',')
      .map((w) => w.trim())
      .filter((w) => w && w !== FLEET_ZONE_UNSET),
  );
}

/**
 * Recompose la liste pour le stockage. Une liste vide devient la sentinelle —
 * Fleetbase refusant la chaîne vide, et l'omission conservant l'ancienne valeur.
 */
export function serialiseServiceWilayas(wilayas: string[]): string {
  const cleaned = dedupe(
    (wilayas ?? [])
      .filter((w): w is string => typeof w === 'string')
      .map((w) => w.trim())
      .filter((w) => w && w !== FLEET_ZONE_UNSET),
  );
  return cleaned.length ? cleaned.join(', ') : FLEET_ZONE_UNSET;
}

/**
 * Cette course entre-t-elle dans la zone de service ?
 *
 * Rend `true` quand rien ne s'y oppose : zone vide, ou wilaya d'enlèvement
 * inconnue, ou wilaya d'enlèvement dans la liste. Réutilise `pickupWilaya` et
 * `sameWilaya` du module de zone conducteur (règle 5) — même lecture, même
 * comparaison insensible à la casse (Fleetbase rend « ALGER »).
 */
export function inServiceZone(order: any, wilayas: string[]): boolean {
  if (!wilayas.length) return true;
  const w = pickupWilaya(order);
  if (!w) return true; // on ne sait pas ⇒ on laisse passer
  return wilayas.some((z) => sameWilaya(w, z));
}

/** Applique la zone de service à une liste de courses. */
export function filterByServiceZone(orders: any[], wilayas: string[]): any[] {
  if (!wilayas.length) return orders ?? [];
  return (orders ?? []).filter((o) => inServiceZone(o, wilayas));
}

function dedupe(list: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const item of list) {
    const key = item.toLocaleLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(item);
  }
  return out;
}
