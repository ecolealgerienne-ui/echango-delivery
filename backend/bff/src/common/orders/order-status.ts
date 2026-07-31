/**
 * Ce qui met fin à une course, dit à un seul endroit.
 *
 * ── Pourquoi ce fichier existe, et ce que sa dispersion a coûté ────────────
 *
 * Cinq endroits du BFF nommaient les statuts terminaux, et **trois n'étaient
 * pas d'accord** :
 *
 *   `order-reconciler`   ['completed', 'canceled', 'cancelled']   complet
 *   `commercant`         ['completed', 'canceled', 'cancelled']   complet
 *   `transporteur` §704  ['completed', 'canceled']                sans la 2ᵉ orthographe
 *   `transporteur` §1247 `status !== 'canceled'`                  sans `completed`
 *   `flotte` §145        `status !== 'canceled'`                  sans `completed`
 *
 * Les deux derniers sont les prédicats de disponibilité, et leur version courte
 * a produit le défaut constaté à l'écran le 31/07/2026 : **une course LIVRÉE
 * apparaissait dans « Courses libres »**, réclamable par une entreprise comme
 * par un indépendant. Personne ne l'avait vu parce que les deux prédicats sont
 * identiques caractère pour caractère — on avait vérifié qu'ils s'accordaient
 * entre eux, pas qu'ils avaient raison.
 *
 * ── Deux orthographes, et il faut les deux ────────────────────────────────
 *
 * Fleetbase émet `canceled` et `cancelled` selon les chemins. N'en reconnaître
 * qu'une laisse une course annulée passer pour vivante — et, sur les prédicats
 * de disponibilité, la laisse offrir au premier transporteur qui rafraîchit.
 */

export const TERMINAL_ORDER_STATUSES = ['completed', 'canceled', 'cancelled'];

/**
 * Cette course est-elle finie ?
 *
 * ⚠️ Un statut absent ou inconnu répond **non**. C'est le bon côté de l'erreur
 * pour les prédicats de disponibilité — une course dont on ignore l'état ne doit
 * pas devenir invisible —, mais l'inverse serait vrai ailleurs. Les appelants
 * qui décident d'une écriture doivent le savoir.
 */
export function isTerminalOrderStatus(status: unknown): boolean {
  return typeof status === 'string' && TERMINAL_ORDER_STATUSES.includes(status);
}
