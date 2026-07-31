/**
 * Reconnaître deux fois la même personne à partir d'un email ou d'un téléphone.
 *
 * ── Pourquoi un module à part, et pas deux méthodes privées ────────────────
 *
 * Règle 5 du projet : un invariant s'applique, il ne se documente pas. Ces deux
 * fonctions vivaient dans `FlotteService`, et leur test en portait **une copie**
 * — le fichier de test le disait lui-même, en invoquant la dépendance à Prisma
 * (dont le client ne peut pas être généré dans l'environnement de développement)
 * et en affirmant que « la copie est fidèle ».
 *
 * ⚠️ **Elle ne l'était déjà plus.** Le service commençait par
 * `if (typeof stored !== 'string' || !stored.trim()) return false;` ; la copie
 * du test, non. Un `null` en base — cas courant, `email` et `phone` étant tous
 * deux facultatifs sur un conducteur — passait donc par un chemin que le test
 * ne parcourait pas. C'est exactement ce que la règle annonce : un test qui
 * recopie ce qu'il vérifie ne vérifie que lui-même, et il serait resté vert
 * pendant que les deux versions divergeaient.
 *
 * Le module n'importe rien : il est donc importable par le test comme par le
 * service, et l'obstacle Prisma disparaît sans qu'on ait à le contourner.
 *
 * ── Ce que ces fonctions décident ─────────────────────────────────────────
 *
 * Le refus de créer un conducteur déjà présent dans le réseau
 * (`driver.already_in_network`). Une comparaison trop stricte laisse passer le
 * doublon que la fonctionnalité existe pour empêcher ; une comparaison trop
 * lâche refuse une création légitime. Les deux erreurs se sont produites.
 */

/**
 * Le numéro d'abonné, débarrassé de son indicatif et de son zéro de tête.
 *
 * ── Pourquoi `endsWith` sur les chiffres bruts ne marchait pas ────────────
 *
 * C'était la première version, et elle échouait sur **l'exemple même de son
 * commentaire** : « 0555 12 34 56 » donne `0555123456`, « +213555123456 »
 * donne `213555123456`, et le second ne se termine pas par le premier — le
 * zéro de tête du format local n'est pas dans le format international. Or c'est
 * exactement le couple le plus fréquent en Algérie : enregistré en `+213…`,
 * ressaisi en `0…`. Le doublon passait, sur le cas le plus courant du pays.
 *
 * Symétriquement, `endsWith` sur six chiffres déclarait identiques deux numéros
 * distincts partageant leur fin, et refusait une création légitime.
 *
 * On normalise donc vers **les neuf chiffres de l'abonné** : indicatif `213`
 * retiré, zéro de tête retiré, et une longueur exacte exigée plutôt qu'un
 * suffixe. Rend `null` quand ce n'est pas un numéro exploitable — un email, par
 * exemple, que la comparaison littérale de `sameIdentifier` a déjà traité.
 */
export function subscriberNumber(value: string): string | null {
  let digits = value.replace(/\D/g, '');
  if (!digits) return null;

  if (digits.startsWith('00')) digits = digits.slice(2);
  if (digits.startsWith('213')) digits = digits.slice(3);
  if (digits.startsWith('0')) digits = digits.slice(1);

  // Neuf chiffres est la longueur d'un numéro algérien sans son zéro
  // (`555123456`). Tout ce qui n'y correspond pas est trop incertain pour
  // fonder un refus de création.
  return digits.length === 9 ? digits : null;
}

/**
 * Deux identifiants désignent-ils la même chose ?
 *
 * [stored] vient d'un enregistrement Fleetbase et peut valoir n'importe quoi —
 * `null`, un nombre, une chaîne vide : `email` et `phone` sont tous deux
 * facultatifs sur un conducteur. Le type est donc `unknown` et non `string`,
 * pour que le contrôle soit fait ici plutôt qu'espéré chez l'appelant.
 *
 * Les numéros sont comparés **sur leurs chiffres seuls** : « 0555 12 34 56 » et
 * « +213555123456 » sont la même ligne.
 */
export function sameIdentifier(stored: unknown, needle: string): boolean {
  if (typeof stored !== 'string' || !stored.trim()) return false;

  const a = stored.trim().toLowerCase();
  const b = needle.trim().toLowerCase();
  if (a === b) return true;

  const na = subscriberNumber(a);
  const nb = subscriberNumber(b);
  return na !== null && na === nb;
}
