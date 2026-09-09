/**
 * La zone de travail d'un transporteur : un point d'ancrage et un rayon autour.
 *
 * ── La décision produit ─────────────────────────────────────────────────────
 *
 * **C'est le transporteur qui choisit sa course**, pas le rayon de diffusion
 * qui choisit pour lui. La liste des courses libres n'a donc pas à s'aligner
 * sur `adhoc_distance`, qui gouverne les sollicitations ; elle s'aligne sur ce
 * que le transporteur a **déclaré vouloir voir**.
 *
 * ── Un seul concept, deux nombres, aucune géographie administrative ─────────
 *
 * La wilaya a été retirée (09/09/2026) : elle imposait une liste des
 * cinquante-huit à tenir accordée avec l'administration algérienne, et couplait
 * le produit à un seul pays. Reste **un point d'ancrage** (`center`, choisi par
 * le transporteur — pas sa position GPS vive, qui peut manquer) et un
 * **rayon**. Le filtre : l'enlèvement d'une course est-il à moins de `radiusKm`
 * de `center` ?
 *
 * Le calcul spatial lui-même est délégué à Fleetbase — `GET /v1/orders?nearby`
 * applique `ST_Distance_Sphere` sur son index. `distanceKm` ci-dessous ne sert
 * plus qu'à l'optimisation de parcours, qui compare à la dépose d'une course
 * déjà tenue.
 *
 * ── L'absence ne cache jamais du travail ───────────────────────────────────
 *
 * ⚠️ Même biais que `isOrderClaimable` pour les statuts inconnus : une course
 * offerte puis refusée est un désagrément, une course jamais montrée est un
 * manque à gagner que personne ne peut constater. Un transporteur **sans point
 * d'ancrage** ne subit aucun filtre de zone — l'écran l'invite à en poser un
 * plutôt que de filtrer sur une valeur qu'il n'a pas choisie.
 */

/** Ce qu'un transporteur a déclaré vouloir voir. */
export interface DriverZone {
  /**
   * Point d'ancrage — le centre du rayon de travail, choisi par le
   * transporteur. `null` = aucune préférence, donc aucun filtrage de zone.
   */
  center: DriverPoint | null;
  /** Rayon en kilomètres autour du point d'ancrage. `null` = pas de limite. */
  radiusKm: number | null;
}

/** Une position, quand on en a une. */
export interface DriverPoint {
  latitude: number;
  longitude: number;
}

/**
 * Rayon proposé par défaut à un transporteur qui règle sa zone pour la première
 * fois — **une valeur d'écran, pas un filtre implicite**.
 *
 * ⚠️ Elle n'est jamais appliquée à quelqu'un qui n'a rien choisi : `zoneAllows`
 * ne filtre que sur ce qui est **déclaré**. La nuance est tout sauf théorique —
 * un défaut appliqué en silence ferait disparaître du travail pour des gens qui
 * n'ont jamais ouvert le réglage, et « le choix revient au transporteur »
 * cesserait d'être vrai pour eux.
 */
export const DEFAULT_ZONE_RADIUS_KM = 15;

/**
 * La wilaya de la course, telle qu'on peut la lire.
 *
 * ⚠️ **L'enlèvement, pas la livraison** (décision du 02/08/2026) : c'est là que
 * le transporteur doit se rendre d'abord, donc c'est la seule des deux qui
 * décide s'il peut prendre la course.
 */
export function pickupWilaya(order: any): string | null {
  // ⚠️ **`meta` d'abord, et c'est ce qui rend le filtre possible.**
  //
  // Le `Place` est la source de la wilaya, mais **la liste des commandes ne la
  // sert pas** : la ressource d'index rend un point d'enlèvement à quinze clés,
  // `province` absente, là où la fiche unitaire en rend trente. Or c'est sur la
  // liste que ce filtre s'applique.
  //
  // La copie posée dans `meta` à la création est donc lue en premier ; le
  // `payload` reste le repli, pour les courses créées avant cette copie et pour
  // tout appelant qui travaille sur une fiche complète.
  const raw =
    order?.meta?.pickup_province
    ?? order?.payload?.pickup?.province
    ?? order?.pickup?.province;
  return typeof raw === 'string' && raw.trim() ? raw.trim() : null;
}

/** Le point d'enlèvement, quand la course en porte un. */
export function pickupPoint(order: any): DriverPoint | null {
  const coords =
    order?.payload?.pickup?.location?.coordinates ?? order?.pickup?.location?.coordinates;
  if (!Array.isArray(coords) || coords.length < 2) return null;
  const [longitude, latitude] = coords;
  if (typeof latitude !== 'number' || typeof longitude !== 'number') return null;
  // ⚠️ `[0, 0]` n'est pas une position, c'est une absence — un point au large du
  // golfe de Guinée. Le défaut est déjà documenté pour la position des
  // transporteurs ; le reproduire ici filtrerait sur une distance imaginaire.
  if (latitude === 0 && longitude === 0) return null;
  return { latitude, longitude };
}

/**
 * Le point de dépose, quand la course en porte un.
 *
 * ⚠️ **Miroir exact de `pickupPoint()`, pas une fusion avec elle** — même
 * lecture GeoJSON, même rejet de `[0, 0]` — parce qu'elles répondent à deux
 * questions différentes : `pickupPoint` sert à décider si UNE course entre
 * dans la zone déclarée d'un transporteur qui ne la tient pas encore ;
 * `dropoffPoint` sert, pour l'optimisation de parcours, à situer où UNE
 * course déjà acceptée dépose — le point de départ d'une recherche de
 * courses proches, pas un critère d'éligibilité. Les fusionner en un
 * `orderPoint(order, 'pickup' | 'dropoff')` ajouterait un paramètre modal
 * sans réduire la duplication réelle (règle 5 : rien ici n'a besoin de
 * changer sur les deux à la fois).
 */
export function dropoffPoint(order: any): DriverPoint | null {
  const coords =
    order?.payload?.dropoff?.location?.coordinates ?? order?.dropoff?.location?.coordinates;
  if (!Array.isArray(coords) || coords.length < 2) return null;
  const [longitude, latitude] = coords;
  if (typeof latitude !== 'number' || typeof longitude !== 'number') return null;
  if (latitude === 0 && longitude === 0) return null;
  return { latitude, longitude };
}

/**
 * Deux noms de wilaya désignent-ils la même ?
 *
 * ⚠️ Comparaison **insensible à la casse et aux espaces** : Fleetbase rend les
 * libellés en MAJUSCULES (« ALGER » là où on a écrit « Alger »). Une égalité
 * stricte ne matcherait jamais, et le filtre viderait la liste de quelqu'un qui
 * a pourtant choisi la bonne wilaya.
 */
export function sameWilaya(a: string | null, b: string | null): boolean {
  if (!a || !b) return false;
  return a.trim().toLocaleLowerCase() === b.trim().toLocaleLowerCase();
}

/**
 * Distance en kilomètres entre deux points — formule de haversine.
 *
 * Suffisante ici : on compare à un rayon que le transporteur a choisi à la
 * dizaine de kilomètres près, pas on ne calcule un itinéraire. Une distance
 * routière serait plus juste et demanderait un service de calcul ; ce serait
 * précis pour une décision qui ne l'est pas.
 */
export function distanceKm(a: DriverPoint, b: DriverPoint): number {
  const R = 6371;
  const rad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = rad(b.latitude - a.latitude);
  const dLon = rad(b.longitude - a.longitude);
  const lat1 = rad(a.latitude);
  const lat2 = rad(b.latitude);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * L'enlèvement de cette course est-il dans le rayon d'ancrage du transporteur ?
 *
 * ⚠️ **Le filtre spatial de production, c'est Fleetbase** (`GET /v1/orders?
 * nearby&radius`). Cette fonction est la **revérification en mémoire** faite
 * après coup, dans la ligne du dépôt « le serveur allège, le code décide » :
 * `nearby` matche aussi les points d'étape, ici on ne regarde que l'enlèvement.
 * C'est aussi le point qu'un banc mute pour prouver qu'un filtre existe.
 *
 * Rend `true` quand rien ne s'y oppose — on ne retire que ce qu'on **sait**
 * être hors zone : pas de point d'ancrage, pas de rayon, ou course sans
 * coordonnées ⇒ visible.
 */
export function pickupWithinZone(
  order: any,
  zone: DriverZone | null | undefined,
): boolean {
  if (!zone || !zone.center || zone.radiusKm == null) return true;
  const point = pickupPoint(order);
  if (!point) return true;
  return distanceKm(zone.center, point) <= zone.radiusKm;
}
