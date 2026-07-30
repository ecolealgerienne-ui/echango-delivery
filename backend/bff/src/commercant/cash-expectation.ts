/**
 * Les statuts pour lesquels de l'argent est réellement attendu à une porte.
 *
 * ── Ce que cette liste répare ───────────────────────────────────────────────
 *
 * La première version de « à encaisser aux portes » filtrait par exclusion —
 * *tout sauf terminé et annulé* — et comptait donc les **brouillons**. Constaté
 * à l'écran : deux commandes jamais publiées, sans transporteur, annoncées
 * comme 2400 DZD attendus. Un brouillon n'engage personne ; le commerçant peut
 * le supprimer, en changer le montant, ne jamais le publier. Annoncer sa somme
 * comme attendue, c'est refaire à l'envers l'erreur que cette lecture corrige.
 *
 * ── Pourquoi une liste FERMÉE ───────────────────────────────────────────────
 *
 * Une liste d'autorisation, et non d'exclusion : un statut inconnu — nouveau
 * chez Fleetbase, ou venu d'une configuration de flux qu'on n'utilise pas
 * encore — ne sera **pas** compté. Sur une somme d'argent, le sens de l'échec
 * se choisit : oublier un montant réel se voit dans la liste des livraisons,
 * en annoncer un imaginaire ne se voit nulle part.
 *
 * ── Pourquoi dans son propre fichier ────────────────────────────────────────
 *
 * Pour que le test importe **la** liste et non une copie. Une liste de statuts
 * recopiée dans un test est le pire des deux mondes : elle passe au vert en
 * décrivant une règle que le code n'applique plus.
 */
export const EXPECTS_CASH_AT_DOOR = ['dispatched', 'started', 'enroute'];
