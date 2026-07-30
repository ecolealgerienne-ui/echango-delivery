/**
 * Lecture de la position d'un conducteur Fleetbase.
 *
 * ── Pourquoi une fonction, et pas deux lignes recopiées ──────────────────────
 *
 * Deux pièges, et tous deux échouent **en silence** : ils ne lèvent rien, ils
 * affichent un point faux. Les traiter à un seul endroit est la seule façon de
 * garantir qu'ils sont traités partout.
 */

/** Position servie aux applications. `null` quand il n'y en a pas. */
export interface DriverPosition {
  latitude: number;
  longitude: number;
}

/**
 * ⚠️ **Piège 1 — l'ordre.** GeoJSON écrit `[longitude, latitude]`, l'inverse de
 * l'usage courant. Vérifié sur les données réelles (29/07/2026) : le conducteur
 * « Toto » porte `[2.310905, 48.871941]`, soit Paris. Lu à l'envers, ce point
 * tombe au large de la Somalie — sans erreur, sans avertissement, juste une
 * carte fausse.
 *
 * ⚠️ **Piège 2 — `[0, 0]` n'est pas une position, c'est une absence.** C'est la
 * valeur d'un conducteur qui n'a jamais émis (deux sur quatre dans l'instance de
 * test). Mais `0,0` est un point parfaitement valide, dans le golfe de Guinée :
 * servi tel quel, il place des transporteurs en mer et l'écran a l'air de
 * fonctionner. Même motif que partout ailleurs dans ce projet — **une valeur par
 * défaut détruit l'information d'absence**.
 *
 * Le zéro exact est retenu comme sentinelle plutôt qu'un rayon autour : une
 * coordonnée réelle rigoureusement nulle n'existe pas en pratique, et élargir
 * la fenêtre écarterait des positions légitimes.
 */
export function readDriverPosition(driver: any): DriverPosition | null {
  const coordinates = driver?.location?.coordinates;
  if (!Array.isArray(coordinates) || coordinates.length < 2) return null;

  const [longitude, latitude] = coordinates;
  if (typeof longitude !== 'number' || typeof latitude !== 'number') return null;
  if (longitude === 0 && latitude === 0) return null;

  return { latitude, longitude };
}

/**
 * Horodatage servi comme fraîcheur de la position.
 *
 * ⚠️ **C'est un « vu le », pas un « positionné le ».** Le conducteur Fleetbase
 * ne porte **aucun horodatage de position** — vérifié sur une charge utile
 * complète le 29/07/2026 : `location`, `heading`, `altitude`, `speed`, `online`,
 * `status`, et `updated_at`. Rien d'autre.
 *
 * `updated_at` bouge donc aussi quand le conducteur passe en ligne ou qu'un
 * admin le modifie, ce qui rend la fraîcheur **optimiste**. C'est acceptable
 * tant que le libellé côté application dit « vu il y a X » et non « position
 * datant de X » : la valeur est honnête sur ce qu'elle mesure, et le seul écart
 * possible va dans le sens d'une activité réelle du conducteur.
 *
 * Pour savoir si le point vaut quelque chose, `online` est un meilleur signal
 * que l'âge — un transporteur hors ligne n'a pas une position vieille, il n'en
 * a pas.
 */
export function readPositionSeenAt(driver: any): string | null {
  const seen = driver?.updated_at;
  return typeof seen === 'string' ? seen : null;
}
