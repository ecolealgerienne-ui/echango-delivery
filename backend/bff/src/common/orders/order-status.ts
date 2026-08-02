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

/** Les orthographes qu'une annulation peut prendre chez Fleetbase. */
export const CANCELLED_ORDER_STATUSES = ['canceled', 'cancelled'];

/**
 * Cette course s'est-elle terminée par une **annulation** ?
 *
 * ── Pourquoi ce prédicat, alors que la constante existait déjà ────────────
 *
 * `order-reconciler.service.ts` importait `TERMINAL_ORDER_STATUSES`, s'en
 * servait deux fois — puis, dix lignes plus bas, réénumérait
 * `status === 'canceled' || status === 'cancelled'` à la main pour choisir sa
 * notification (revue du 01/08/2026, A5).
 *
 * Le jour où une quatrième graphie est ajoutée à la constante — **le motif même
 * de son existence**, Fleetbase en émettant déjà deux —, le filtre de la ligne
 * 109 la reconnaîtrait et la notification cesserait : le commerçant ne serait
 * plus prévenu de l'annulation de sa livraison, sans erreur ni journal. La
 * panne décrite dans l'en-tête de ce fichier, reproduite dans le fichier qui
 * importe le correctif.
 */
export function isCancelledOrderStatus(status: unknown): boolean {
  return typeof status === 'string' && CANCELLED_ORDER_STATUSES.includes(status);
}

/**
 * Les statuts qui disent qu'une course a **déjà commencé**.
 *
 * ── Pourquoi ils excluent la réclamation (02/08/2026) ─────────────────────
 *
 * Trouvé par le parcours transporteur joué dans l'application : l'onglet
 * « Opportunités » proposait une course du 30/07 avec un bouton « Accepter »,
 * et le serveur refusait — `400 Order has already started`. Elle passait le
 * prédicat parce qu'elle était `adhoc`, **sans conducteur assigné**, et pas
 * terminale : `started` n'était exclu par rien.
 *
 * Une course commencée mais sans conducteur n'est pas une bizarrerie de
 * laboratoire — elle apparaît dès qu'une acceptation aboutit à moitié, ou
 * qu'un conducteur rend une course déjà démarrée. Ce qui est certain, et
 * mesuré, c'est que Fleetbase la refuse : l'offrir ne peut donc produire qu'un
 * message d'erreur brut là où le transporteur croyait prendre du travail.
 *
 * ⚠️ **Liste des statuts OBSERVÉS, pas une liste blanche des statuts permis.**
 * Le biais de ce fichier est explicite — « une course dont on ignore l'état ne
 * doit pas devenir invisible » — et il est conservé : un statut inconnu reste
 * offert. Renverser ce biais ferait disparaître du travail en silence le jour
 * où Fleetbase ajoute un état, ce qui est le mauvais côté de l'erreur ici.
 */
export const BEGUN_ORDER_STATUSES = ['started', 'enroute', 'driver_enroute'];

/** Cette course a-t-elle déjà commencé ? Un statut inconnu répond **non**. */
export function isBegunOrderStatus(status: unknown): boolean {
  return typeof status === 'string' && BEGUN_ORDER_STATUSES.includes(status);
}

/**
 * Cette course est-elle **libre** ?
 *
 * ── Pourquoi ce prédicat vit ici, et pas dans les deux services ───────────
 *
 * Il était écrit **deux fois** — `isClaimable` côté entreprise,
 * `isClaimableAdhoc` côté transporteur — avec, dans chacun, un commentaire
 * affirmant que les deux devaient rester identiques. C'est le défaut dans sa
 * forme la plus pure : **l'invariant était documenté au lieu d'être appliqué**.
 * Un commentaire ne peut pas échouer.
 *
 * Et il a échoué : les deux copies excluaient `canceled` sans exclure
 * `completed`, si bien qu'une course livrée s'offrait dans « Courses libres ».
 * Corriger le 31/07/2026 a d'abord consisté à partager la constante des statuts
 * terminaux — le symptôme — en laissant les deux copies du prédicat, et le
 * commentaire « il faut qu'elle reste identique » a été **réécrit dans la
 * correction elle-même**.
 *
 * ── Le critère, pour ne pas tout fusionner non plus ───────────────────────
 *
 * La question n'est pas « ces deux bouts de code se ressemblent-ils » mais
 * **« si l'un change, l'autre doit-il changer ? »**. Ici la réponse est un oui
 * sans nuance : les deux populations réclament **les mêmes courses**, donc elles
 * doivent s'accorder sur ce que « libre » veut dire. Une divergence n'est pas
 * une variante, c'est un défaut.
 *
 * À l'inverse, `orderStatusLabel` (commerçant) et `fleetOrderStateKey`
 * (entreprise) se ressemblent et doivent rester séparés : ils répondent à deux
 * questions différentes, et l'un peut changer sans l'autre.
 *
 * ── Ce que le prédicat exige, et pourquoi les deux colonnes ───────────────
 *
 * `driver_assigned_uuid` ET `facilitator_uuid` vides. Un indépendant ne prend
 * pas une course confiée à une entreprise, une entreprise ne prend pas une
 * course déjà démarrée par un indépendant — et les deux écrivent des colonnes
 * différentes, donc aucun conflit ne les départagerait.
 *
 * ⚠️ `adhoc` et non `dispatched` : le second dit « a été diffusée un jour », le
 * premier « l'est encore ».
 */
export function isOrderClaimable(order: any): boolean {
  return (
    order?.adhoc === true &&
    !order?.driver_assigned_uuid &&
    // Ni déjà commencée : cf. `BEGUN_ORDER_STATUSES` ci-dessus.
    !isBegunOrderStatus(order?.status) &&
    !order?.facilitator_uuid &&
    // Tous les statuts terminaux, et non le seul `canceled` : terminer une
    // course n'efface pas `adhoc`, donc rien d'autre ne l'excluait.
    !isTerminalOrderStatus(order?.status)
  );
}
