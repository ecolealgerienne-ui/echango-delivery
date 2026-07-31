/**
 * Le rayon de diffusion d'une course adhoc, en mètres.
 *
 * ── Pourquoi un module, et pas une méthode privée par service ──────────────
 *
 * Règle 5 du projet, dans sa forme la plus littérale : `adhocRadiusMetres()`
 * existait **deux fois, corps identique caractère pour caractère** — une copie
 * dans `CommerçantService` (diffusion à la création et à la publication) et une
 * dans `TransporteurService` (rediffusion d'une course rendue). Et la seconde
 * portait le commentaire qui est précisément le signal que la règle nomme :
 *
 *   « Même valeur que celle appliquée à la création (`CommerçantService`) : une
 *     course rendue doit être proposée exactement comme elle l'aurait été si le
 *     favori n'avait pas été sollicité, **sans quoi le refus changerait
 *     silencieusement sa portée**. »
 *
 * La phrase dit l'invariant, sa raison, et le défaut qu'une divergence
 * produirait. Elle ne peut simplement pas le tenir — un commentaire ne peut pas
 * échouer. Changer le repli d'un seul côté aurait fait qu'un refus de course
 * rétrécit ou élargit sa diffusion sans que rien ne le signale : le
 * transporteur suivant ne la verrait pas, et personne ne saurait pourquoi.
 *
 * ── Ce que ce module ne fait PAS ──────────────────────────────────────────
 *
 * Aucun filtre de proximité. Fleetbase porte nativement `adhoc_distance` et
 * c'est son dispatch géospatial qui l'applique — le BFF ne fait que lui donner
 * la valeur. ⚠️ Conséquence à connaître : ce rayon borne **les pings**, pas la
 * liste « courses libres », que le BFF sert à l'échelle de l'organisation.
 * Les deux ne s'accordent donc pas, et c'est une décision produit ouverte
 * (`docs/rapports_revue_2026-07-28/00_synthese.md`, P1).
 */

/**
 * Le repli quand rien n'est configuré.
 *
 * ⚠️ **Un repli, pas une décision produit.** 15 km couvre une agglomération
 * sans noyer les transporteurs de courses hors de portée. À régler au pilote,
 * avec de vraies distances.
 */
export const DEFAULT_ADHOC_RADIUS_METRES = 15000;

/**
 * Rend le rayon configuré, ou le repli quand la valeur est inexploitable.
 *
 * [configured] arrive d'une variable d'environnement, donc **en chaîne** — d'où
 * le type `unknown` et la conversion ici plutôt qu'espérée chez l'appelant.
 * Toute valeur non finie ou nulle retombe sur le repli : un rayon de zéro ne
 * diffuserait à personne, et un `NaN` envoyé à Fleetbase produirait un refus
 * dont le message ne parlerait pas de configuration.
 */
export function adhocRadiusMetres(configured: unknown): number {
  const value = Number(configured);
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_ADHOC_RADIUS_METRES;
}
