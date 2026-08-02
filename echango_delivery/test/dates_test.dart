import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';

import 'package:echango_delivery/utils/dates.dart';

/// Le format des dates, tenu par un contrôle plutôt que par la vigilance.
///
/// ── Ce que ce test empêche de revenir ────────────────────────────────────
///
/// Cinq façons d'écrire une date coexistaient dans `lib/screens/` le
/// 31/07/2026, dont deux fausses. Les deux défauts ont leur cas ici :
///
///  * **l'heure en UTC** — `readDate` rend un `DateTime` UTC, et un
///    `toString()` sans `toLocal()` affichait « Créée le » une heure trop tôt.
///    Le premier test le vérifie sur une date explicitement UTC, ce qui est la
///    seule façon de le voir : sur une date locale, les deux versions
///    s'accordent et le défaut reste invisible ;
///  * **le rembourrage manquant** — « 5/8 » là où le reste de l'application
///    écrit « 05/08 ».
///
/// ⚠️ Les cas emploient un **décalage fixe et explicite** plutôt que
/// `DateTime.now()` : un test qui dépend du fuseau de la machine passe chez
/// l'un et échoue chez l'autre, ce qui ne vérifie plus rien — ça déplace la
/// question.
void main() {
  const fr = Locale('fr');
  const ar = Locale('ar');

  group('formatFull', () {
    test('ne rend pas la forme brute que l’écran affichait', () {
      final utc = DateTime.utc(2026, 7, 31, 14, 23, 5);

      // `toString().split('.')[0]` rendait « 2026-07-31 14:23:05 ». Ces deux
      // contrôles sont vrais quel que soit le fuseau de la machine.
      expect(formatFull(utc, fr), isNot(contains('2026-07-31')));
      expect(formatFull(utc, fr), isNot(contains(':')));
      expect(formatFull(utc, fr), matches(r'^\d{2}/\d{2}/\d{4} à \d{2}h\d{2}$'));
    });

    test('convertit vers l’heure locale', () {
      final utc = DateTime.utc(2026, 7, 31, 14, 23, 5);

      // ⚠️ Ce que ce test peut prouver dépend de la machine, et le dire vaut
      // mieux que l'ignorer. Recalculer l'attendu avec `utc.toLocal()` serait
      // une tautologie : le test rejouerait la conversion qu'il vérifie et
      // resterait vert même si `formatFull` l'oubliait.
      //
      // Hors UTC, l'affirmation a du contenu : l'heure affichée n'est pas
      // l'heure UTC. Sur une machine à UTC+0 il n'y a rien à distinguer, et le
      // cas est explicitement neutralisé plutôt que faussement rassurant.
      final offset = DateTime.now().timeZoneOffset;
      if (offset == Duration.zero) {
        markTestSkipped('machine en UTC : rien à distinguer ici');
        return;
      }
      expect(formatFull(utc, fr), isNot(contains('14h23')));
      expect(formatFull(utc, fr), contains(_two(utc.toLocal().hour)));
    });

    test('n’altère pas une date déjà locale', () {
      final local = DateTime(2026, 7, 5, 9, 4);
      expect(formatFull(local, fr), '05/07/2026 à 09h04');
    });
  });

  group('formatDayTime', () {
    test('rembourre le jour, le mois, l’heure et la minute', () {
      // Le défaut exact du sélecteur d'enlèvement : « 5/8 à 09h30 ».
      expect(formatDayTime(DateTime(2026, 8, 5, 9, 30), fr), '05/08 à 09h30');
      expect(formatDayTime(DateTime(2026, 12, 25, 23, 5), fr), '25/12 à 23h05');
    });

    test('n’écrit pas l’année — c’est ce qui la distingue de formatFull', () {
      expect(formatDayTime(DateTime(2026, 8, 5, 9, 30), fr), isNot(contains('2026')));
    });
  });

  group('formatDay', () {
    test('jour, mois et année rembourrés', () {
      expect(formatDay(DateTime(2026, 1, 2)), '02/01/2026');
    });

    test('la seule des quatre qui n’a pas besoin de locale : que des chiffres',
        () {
      // Si un mot s'y glissait un jour, il faudrait lui donner une locale comme
      // aux trois autres. Ce contrôle est ce qui le dirait.
      expect(formatDay(DateTime(2026, 1, 2)), matches(r'^[\d/]+$'));
    });
  });

  // ── Le français ne doit pas traverser vers l'écran arabe ─────────────────
  //
  // Ces trois cas n'existaient pas avant le 01/08/2026, et c'est pourquoi le
  // défaut a tenu : `formatDayTime` et `formatFull` écrivaient « à » et « h »,
  // deux formes françaises, pendant que le commentaire de `formatRelative`
  // affirmait que ces fonctions « se lisent aussi bien dans les deux langues ».
  // Le test ne pouvait pas contredire le commentaire : il ne testait que le
  // français.
  group('arabe', () {
    test('formatDayTime n’écrit ni « à » ni « h »', () {
      final s = formatDayTime(DateTime(2026, 8, 5, 9, 30), ar);
      expect(s, '05/08 09:30');
      expect(s, isNot(contains('à')));
      expect(s, isNot(contains('h')));
    });

    test('formatFull non plus', () {
      final s = formatFull(DateTime(2026, 7, 5, 9, 4), ar);
      expect(s, '05/07/2026 09:04');
      expect(s, isNot(contains('à')));
    });

    test('les deux langues rendent les mêmes chiffres, dans le même ordre', () {
      final d = DateTime(2026, 8, 5, 9, 30);
      String digits(String s) => s.replaceAll(RegExp(r'[^\d]'), '');
      expect(digits(formatDayTime(d, ar)), digits(formatDayTime(d, fr)));
    });
  });

  group('formatRelative', () {
    test('dit le délai en deçà d’une semaine', () {
      final now = DateTime.now();
      expect(formatRelative(now.subtract(const Duration(seconds: 10)), fr),
          'à l\'instant');
      expect(formatRelative(now.subtract(const Duration(minutes: 12)), fr),
          'il y a 12 min');
      expect(
          formatRelative(now.subtract(const Duration(hours: 5)), fr), 'il y a 5 h');
      expect(
          formatRelative(now.subtract(const Duration(days: 3)), fr), 'il y a 3 j');
    });

    test('retombe sur formatDay au-delà, et pas sur un autre format', () {
      final old = DateTime.now().subtract(const Duration(days: 40));
      expect(formatRelative(old, fr), formatDay(old));
      // Le basculement ne doit pas changer de convention : c'est la raison
      // d'être du repli sur `formatDay` plutôt que sur une chaîne recopiée.
      expect(formatRelative(old, fr), matches(r'^\d{2}/\d{2}/\d{4}$'));
    });

    // ── L'arabe, parce que c'est la raison d'être du paramètre ─────────────
    //
    // C'est la seule des quatre fonctions de ce fichier qui produise des MOTS.
    // Les trois autres ne rendent que des chiffres, donc se lisent dans les
    // deux langues ; celle-ci écrivait « il y a » dans un écran arabe.
    test('rend l’arabe quand la locale le demande', () {
      final now = DateTime.now();
      expect(formatRelative(now.subtract(const Duration(seconds: 10)), ar),
          'الآن');
      expect(formatRelative(now.subtract(const Duration(minutes: 12)), ar),
          'منذ 12 د');
      expect(formatRelative(now.subtract(const Duration(hours: 5)), ar),
          'منذ 5 س');
      expect(formatRelative(now.subtract(const Duration(days: 3)), ar),
          'منذ 3 ي');
    });

    test('la date de repli reste la même dans les deux langues', () {
      // Des chiffres et deux barres obliques : rien à traduire, et deux
      // formats de date selon la langue seraient une divergence gratuite.
      final old = DateTime.now().subtract(const Duration(days: 40));
      expect(formatRelative(old, ar), formatRelative(old, fr));
    });

    test('une locale inconnue ne rend pas une langue au hasard', () {
      // Le repli est le français, langue par défaut du produit — mais il est
      // explicite ici plutôt que déduit d'une lecture du code.
      final now = DateTime.now().subtract(const Duration(minutes: 12));
      expect(formatRelative(now, const Locale('en')), 'il y a 12 min');
    });
  });
}

String _two(int n) => n.toString().padLeft(2, '0');
