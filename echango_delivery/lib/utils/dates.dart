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

/// L'heure seule, dans la convention de la langue.
///
/// ⚠️ **C'est ici que se trouvait l'erreur** (corrigée le 01/08/2026). Le
/// commentaire de [formatRelative] affirmait que les trois autres fonctions
/// « ne rendent que des chiffres et deux séparateurs » et « se lisent aussi
/// bien dans les deux langues ». C'était faux de deux d'entre elles : « 15**h**23 »
/// est une convention française, et le « **à** » qui la précède est une
/// préposition française. Un écran arabe affichait donc « 05/08 à 15h23 ».
///
/// Seule [formatDay] tenait la promesse, n'étant que des chiffres et des
/// barres obliques. Elle reste sans locale, et c'est délibéré : lui en imposer
/// une pour l'uniformité obligerait chaque appelant à en fournir une là où
/// aucune décision de langue n'existe.
String _hourMinute(DateTime d, Locale locale) =>
    locale.languageCode == 'ar'
        ? '${_two(d.hour)}:${_two(d.minute)}'
        : '${_two(d.hour)}h${_two(d.minute)}';

/// Le mot qui relie une date à son heure — « à » en français, rien en arabe.
String _at(Locale locale) => locale.languageCode == 'ar' ? ' ' : ' à ';

/// « 31/07 à 15h23 » — jour et heure, sans l'année.
///
/// Le format des évènements récents, où l'année n'apprend rien.
String formatDayTime(DateTime date, Locale locale) {
  final d = date.toLocal();
  return '${_two(d.day)}/${_two(d.month)}${_at(locale)}${_hourMinute(d, locale)}';
}

/// « 31/07/2026 » — le jour seul, année comprise.
///
/// La seule des quatre qui n'a pas besoin de locale : que des chiffres.
String formatDay(DateTime date) {
  final d = date.toLocal();
  return '${_two(d.day)}/${_two(d.month)}/${d.year}';
}

/// « 31/07/2026 à 15h23 » — la forme complète.
///
/// Pour ce qui doit être daté sans ambiguïté : création, dernière mise à jour.
/// Remplace `toString().split('.')[0]`, qui rendait « 2026-07-31 14:23:05 » —
/// un horodatage de journal serveur, pas une date lisible, et en UTC.
String formatFull(DateTime date, Locale locale) {
  final d = date.toLocal();
  return '${formatDay(d)}${_at(locale)}${_hourMinute(d, locale)}';
}

/// « il y a 12 min », puis la date au-delà d'une semaine.
///
/// Répond à une autre question que les précédentes — *depuis combien de temps*
/// plutôt que *quand* —, d'où une fonction distincte et non un paramètre. Elle
/// retombe sur [formatDay] pour que le basculement ne change pas de format.
///
/// ── Pourquoi une locale, comme [formatDayTime] et [formatFull] ────────────
///
/// Parce qu'elle produit des **mots** — « il y a » —, ce qu'un écran arabe ne
/// peut pas afficher.
///
/// ⚠️ Ce commentaire affirmait jusqu'au 01/08/2026 que les trois autres
/// fonctions s'en passaient parce qu'elles « ne rendent que des chiffres ».
/// C'était vrai de [formatDay] seule ; les deux autres écrivaient « à » et
/// « h ». La phrase était le seul endroit où le manque était visible, et elle
/// le niait — un commentaire qui se trompe est pire qu'aucun commentaire,
/// parce qu'il fait cesser de chercher.
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
