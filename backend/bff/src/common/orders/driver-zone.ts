/**
 * La zone de travail d'un transporteur : sa wilaya, et un rayon autour de lui.
 *
 * ── La décision produit, prise le 02/08/2026 ────────────────────────────────
 *
 * **C'est le transporteur qui choisit sa course**, pas le rayon de diffusion
 * qui choisit pour lui. La liste des courses libres n'a donc pas à s'aligner
 * sur `adhoc_distance`, qui gouverne les sollicitations ; elle s'aligne sur ce
 * que le transporteur a **déclaré vouloir voir**.
 *
 * Deux filtres, et ils ne jouent pas le même rôle :
 *
 * - **la wilaya** est le filtre structurel. Elle est déclarée, elle ne dépend
 *   d'aucun capteur, et c'est l'unité dans laquelle un transporteur algérien
 *   raisonne. Sans elle, il verrait les courses des cinquante-huit wilayas.
 * - **le rayon** est un raffinement opportuniste — « chercher autour ». Il
 *   exige une position, qui peut manquer.
 *
 * Les hiérarchiser dans cet ordre supprime le trou d'une conception à rayon
 * seul : un transporteur dont on ignore la position ne verrait **aucune
 * course**, ce qui est le pire résultat possible pour une fonctionnalité censée
 * l'aider à choisir.
 *
 * ── Deux absences, et elles ne se traitent pas pareil ───────────────────────
 *
 * ⚠️ **Ce qu'on ignore ne doit jamais cacher du travail.** C'est le même biais
 * que `isOrderClaimable` pour les statuts inconnus, et pour la même raison :
 * une course offerte puis refusée est un désagrément, une course jamais montrée
 * est un manque à gagner que personne ne peut constater.
 *
 * Donc, systématiquement :
 *
 * - une course **sans wilaya** reste visible. Le champ vient du géocodage
 *   inverse, jamais d'une saisie : l'absence dit « on ne sait pas », pas
 *   « ailleurs ». Le carnet d'adresses la porte, mais une course créée
 *   autrement peut ne pas l'avoir.
 * - une course **sans coordonnées** reste visible, pour la même raison.
 * - un transporteur **sans préférence** voit tout, jusqu'à ce qu'il choisisse.
 * - un transporteur **sans position** garde son filtre wilaya et perd le
 *   rayon — au lieu de tout perdre.
 */

/** Ce qu'un transporteur a déclaré vouloir voir. */
export interface DriverZone {
  /** Wilaya de travail. `null` = aucune préférence, donc aucun filtrage. */
  wilaya: string | null;
  /** Rayon en kilomètres autour de sa position. `null` = pas de limite. */
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

/**
 * D'où part la course : sa wilaya et son point, quand on les connaît.
 *
 * Existe parce que **deux chemins posent la même question sans avoir la même
 * chose en main**. La liste des opportunités tient une commande Fleetbase
 * complète ; la sollicitation d'un favori, elle, se décide **avant** que la
 * commande existe — il n'y a que le formulaire du commerçant. Les deux doivent
 * pourtant appliquer la même règle, sans quoi un transporteur serait écarté
 * d'une liste et assigné d'office à la même course (règle 5).
 */
export interface OrderPickup {
  wilaya: string | null;
  point: DriverPoint | null;
}

/** Ce qu'on sait du départ d'une course déjà créée. */
export function orderPickup(order: any): OrderPickup {
  return { wilaya: pickupWilaya(order), point: pickupPoint(order) };
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
 * Cette course entre-t-elle dans la zone que le transporteur a déclarée ?
 *
 * Rend `true` quand rien ne s'y oppose — c'est le sens du biais décrit en tête
 * de fichier : on ne retire de la liste que ce qu'on **sait** être hors zone.
 */
export function zoneAllows(
  order: any,
  zone: DriverZone | null | undefined,
  driverPoint: DriverPoint | null | undefined,
): boolean {
  return zoneAllowsPickup(orderPickup(order), zone, driverPoint);
}

/**
 * La même règle, à partir de ce qu'on sait du départ.
 *
 * ⚠️ **C'est ici que la décision vit, et nulle part ailleurs.** Deux chemins
 * l'appliquent — la liste des opportunités et la sollicitation d'un favori — et
 * ils ne doivent pas pouvoir diverger : un transporteur écarté d'une liste et
 * assigné d'office à la même course serait pire que l'absence de filtre, parce
 * que la course lui **resterait** (`driver_assigned_uuid` la sort du pool).
 *
 * Rend `true` quand rien ne s'y oppose — même biais qu'au-dessus : on ne
 * retire que ce qu'on **sait** être hors zone.
 */
export function zoneAllowsPickup(
  pickup: OrderPickup,
  zone: DriverZone | null | undefined,
  driverPoint: DriverPoint | null | undefined,
): boolean {
  if (!zone) return true;

  // ── La wilaya ─────────────────────────────────────────────────────────────
  // Course sans wilaya : on ne sait pas, donc on laisse passer.
  if (zone.wilaya && pickup.wilaya && !sameWilaya(pickup.wilaya, zone.wilaya)) {
    return false;
  }

  // ── Le rayon ──────────────────────────────────────────────────────────────
  // Course sans point, ou transporteur sans position : on ne sait pas, donc on
  // laisse passer — et seule la wilaya aura filtré.
  if (zone.radiusKm != null && driverPoint && pickup.point) {
    if (distanceKm(driverPoint, pickup.point) > zone.radiusKm) return false;
  }

  return true;
}
