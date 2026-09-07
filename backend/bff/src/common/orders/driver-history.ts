/**
 * Combien de courses TERMINÉES l'écran conducteur ramène par chargement, et
 * lesquelles.
 *
 * ── Pourquoi un plafond ────────────────────────────────────────────────────
 *
 * `hydrateOrders` recharge chaque course une par une pour ses champs
 * personnalisés (prix, montant à encaisser). Un transporteur actif depuis
 * quelques semaines accumule des centaines de courses terminées ; les hydrater
 * toutes portait `GET /transporteur/commandes` à 12-17 s — assez pour que le
 * rechargement qui suit une acceptation laisse la fiche sur son indicateur
 * d'attente, et pour faire expirer le parcours d'intégration (constaté le
 * 06/09/2026 sur un conducteur à 177 terminées : endpoint à 17 s).
 *
 * L'onglet « historique » n'a pas de pagination : au-delà d'un écran, c'est du
 * défilement mort. On garde donc les plus récentes, et on n'hydrate qu'elles.
 *
 * ── Ce que le plafond ne touche JAMAIS ─────────────────────────────────────
 *
 * Les courses **en cours** portent une action (accepter, démarrer, terminer,
 * signaler). En manquer une n'est pas « un peu moins d'historique », c'est une
 * course qu'on ne peut plus faire avancer. Elles passent toutes, sans plafond.
 */
export const MAX_DRIVER_HISTORY_ORDERS = 30;

/**
 * Les courses d'un conducteur à hydrater : **toutes celles en cours**, plus les
 * `max` plus récentes parmi les terminées (triées sur `updated_at`, repli
 * `created_at`).
 *
 * `isFinished` est passé en paramètre plutôt que codé ici : la définition d'un
 * statut terminal vit dans `order-status.ts` et ne doit pas être recopiée
 * (règle 5). L'ordre du résultat — en cours d'abord — est celui qu'attend
 * l'appelant qui concatène puis hydrate.
 */
export function selectDriverOrdersToHydrate<T>(
  orders: T[],
  isFinished: (order: T) => boolean,
  max: number = MAX_DRIVER_HISTORY_ORDERS,
): T[] {
  const active = orders.filter((o) => !isFinished(o));

  const recentFinished = orders
    .filter((o) => isFinished(o))
    .sort((a, b) => stamp(b).localeCompare(stamp(a)))
    .slice(0, Math.max(0, max));

  return [...active, ...recentFinished];
}

/** L'horodatage sur lequel trier — `updated_at`, sinon `created_at`, sinon ''. */
function stamp(order: any): string {
  return String(order?.updated_at ?? order?.created_at ?? '');
}
