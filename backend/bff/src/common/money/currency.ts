/**
 * La devise de la plateforme — **une seule décision, un seul endroit**.
 *
 * ── Le défaut qui a rendu ce fichier nécessaire (02/08/2026) ────────────────
 *
 * Le même écran affichait « 777 USD » pour le prix et « À encaisser : 2727 DZD »
 * pour la somme réclamée à la porte. Deux devises pour une seule course, à trois
 * centimètres l'une de l'autre.
 *
 * Ce n'était pas un choix d'affichage : les deux nombres venaient de deux
 * sources qui ne se parlent pas.
 *
 * - **le prix** relayait la devise de Fleetbase ;
 * - **le montant à encaisser** relayait la nôtre, écrite en dur à `DZD` dans le
 *   registre de caisse.
 *
 * Et la devise de Fleetbase valait `USD` par un chemin qu'aucune relecture
 * n'aurait montré : `Order` **a déjà une colonne `currency`**, dont le défaut
 * est `USD`, et notre champ personnalisé porte le **même nom**. Sur la liste,
 * où les valeurs des champs personnalisés sont absentes, le repli « à plat »
 * de `readOrderCustomFields()` lisait `order.currency` — celle de Fleetbase —
 * et l'emportait sur notre `DZD`. Mesuré : une seule collision sur nos treize
 * champs, et c'est celle-là.
 *
 * ── Pourquoi une constante et non le champ Fleetbase (règle 1) ──────────────
 *
 * La règle du dépôt dit que Fleetbase fait foi, et elle tient tant que
 * Fleetbase **peut** porter l'information. Ici il ne le peut pas : **le DZD ne
 * fait pas partie des devises qu'il propose**. Son champ ne dira donc jamais la
 * vérité de cette plateforme — ce n'est pas une source concurrente, c'est une
 * case qu'on ne peut pas remplir.
 *
 * La plateforme est locale à l'Algérie et **mono-devise** : le libellé décrit
 * l'unité dans laquelle tout le monde compte déjà. **Aucune conversion n'est
 * faite ni prévue** — les montants ne changent pas, seul leur nom est corrigé.
 * Le jour où une seconde devise existerait, cette hypothèse tomberait et ce
 * fichier serait le premier endroit à rouvrir.
 */

/**
 * ⚠️ Valeur de repli, jamais une conversion. `CURRENCY` reste réglable pour un
 * déploiement hors Algérie ; à défaut, c'est le DZD.
 */
export const DEFAULT_PLATFORM_CURRENCY = 'DZD';

/**
 * La devise dans laquelle cette plateforme compte.
 *
 * Un seul appelant décide (`CURRENCY`), et tous les autres lisent ici — sans
 * quoi la décision serait recopiée dans le service de tarification, dans le
 * registre de caisse et dans la projection, avec trois occasions de diverger.
 */
export function platformCurrency(configured?: string | null): string {
  const trimmed = typeof configured === 'string' ? configured.trim() : '';
  return trimmed || DEFAULT_PLATFORM_CURRENCY;
}
