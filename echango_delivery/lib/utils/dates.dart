/// Les dates telles qu'elles s'affichent, décidées à un seul endroit.
///
/// ── Ce que la recopie avait produit ───────────────────────────────────────
///
/// Mesuré le 31/07/2026 : **cinq façons différentes** d'écrire une date dans
/// `lib/screens/`, dont deux fausses.
///
///  1. `_formatDate` (transporteur) et `_formatDateTime` (commerçant) —
///     **identiques caractère pour caractère**, deux noms. Trouvées par
///     comparaison des corps de fonction, pas par lecture.
///  2. `_scheduleTile` (création de commande) — `${day}/${month}` **sans
///     rembourrage** : « 5/8 à 09h30 » là où le reste de l'application écrit
///     « 05/08 à 09h30 ».
///  3. `cash_screen` — `toLocal().toString().split(' ')[0]`, donc
///     « 2026-07-31 », format ISO au milieu d'un écran en jj/MM.
///  4. ⚠️ `transporteur/order_detail` — `createdAt.toString()` **sans
///     `toLocal()`**. `readDate` rend un `DateTime` UTC, donc « Créée le »
///     s'affichait une heure trop tôt, juste au-dessus d'une date d'échec que
///     la même classe localisait correctement. Le commerçant, lui, avait le
///     `toLocal()` — même donnée, deux heures différentes selon l'écran.
///
/// C'est la règle 5 dans sa forme la plus banale : personne n'a décidé de ces
/// écarts, ils sont ce que produit la recopie.
///
/// ── `toLocal()` est dans chaque fonction, pas chez l'appelant ─────────────
///
/// Toutes les dates du serveur arrivent en UTC (`readDate` ⇒ `DateTime.parse`
/// d'une chaîne ISO en `Z`). Laisser l'appelant y penser, c'est le défaut n°4
/// ci-dessus. Sur une date déjà locale — celle d'un sélecteur, par exemple —
/// `toLocal()` ne fait rien : l'appeler systématiquement ne coûte donc que le
/// droit de ne plus y penser.
library;

import 'dart:ui' show Locale;

String _two(int n) => n.toString().padLeft(2, '0');

/// « 31/07 à 15h23 » — jour et heure, sans l'année.
///
/// Le format des évènements récents, où l'année n'apprend rien.
String formatDayTime(DateTime date) {
  final d = date.toLocal();
  return '${_two(d.day)}/${_two(d.month)} à ${_two(d.hour)}h${_two(d.minute)}';
}

/// « 31/07/2026 » — le jour seul, année comprise.
String formatDay(DateTime date) {
  final d = date.toLocal();
  return '${_two(d.day)}/${_two(d.month)}/${d.year}';
}

/// « 31/07/2026 à 15h23 » — la forme complète.
///
/// Pour ce qui doit être daté sans ambiguïté : création, dernière mise à jour.
/// Remplace `toString().split('.')[0]`, qui rendait « 2026-07-31 14:23:05 » —
/// un horodatage de journal serveur, pas une date lisible, et en UTC.
String formatFull(DateTime date) {
  final d = date.toLocal();
  return '${formatDay(d)} à ${_two(d.hour)}h${_two(d.minute)}';
}

/// « il y a 12 min », puis la date au-delà d'une semaine.
///
/// Répond à une autre question que les précédentes — *depuis combien de temps*
/// plutôt que *quand* —, d'où une fonction distincte et non un paramètre. Elle
/// retombe sur [formatDay] pour que le basculement ne change pas de format.
///
/// ── Pourquoi celle-ci prend une locale, et les trois autres non ───────────
///
/// Parce qu'elle est la seule à produire des **mots**. `formatDayTime`,
/// `formatDay` et `formatFull` ne rendent que des chiffres et deux séparateurs :
/// elles se lisent aussi bien dans les deux langues. Celle-ci écrit « il y a »,
/// ce qu'un écran arabe ne peut pas afficher.
///
/// ⚠️ **La locale est exigée, pas optionnelle.** Un paramètre facultatif qui
/// vaut « français » par défaut aurait laissé chaque nouvel appelant introduire
/// silencieusement une phrase française dans un écran arabe — et personne
/// n'aurait relu. Le compilateur pose la question à chaque site, ce qu'un
/// commentaire ne sait pas faire (règle 5).
String formatRelative(DateTime date, Locale locale) {
  final ar = locale.languageCode == 'ar';
  final delta = DateTime.now().difference(date.toLocal());

  if (delta.inMinutes < 1) return ar ? 'الآن' : 'à l\'instant';
  if (delta.inMinutes < 60) {
    return ar ? 'منذ ${delta.inMinutes} د' : 'il y a ${delta.inMinutes} min';
  }
  if (delta.inHours < 24) {
    return ar ? 'منذ ${delta.inHours} س' : 'il y a ${delta.inHours} h';
  }
  if (delta.inDays < 7) {
    return ar ? 'منذ ${delta.inDays} ي' : 'il y a ${delta.inDays} j';
  }
  return formatDay(date);
}
