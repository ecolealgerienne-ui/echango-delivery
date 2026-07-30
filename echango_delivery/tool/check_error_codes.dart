// Vérifie que les trois ensembles de clés d'erreur sont strictement identiques :
// `AppError`, la table française et la table arabe.
//
// ── Pourquoi ce contrôle vit dans le dépôt ─────────────────────────────────
//
// La règle 4 du projet l'exige, et `CLAUDE.md` le dit « vérifiable par
// script » — mais aucun script n'existait, il était refait à la main à chaque
// fois. Le 30/07/2026 celui que j'avais improvisé filtrait les clés sur
// `[a-z_]+\.[a-z_]+`, donc il **ne voyait pas `not_found`**, qui n'a pas de
// point. Il a signalé un manque inexistant, j'ai ajouté l'entrée, et le
// résultat a été une clé en double — que `dart analyze` a refusée.
//
// Un vérificateur qui ne voit pas tout ne rassure pas : il déplace l'erreur.
// D'où la règle appliquée ici : **la clé, c'est ce que Dart considère comme
// une clé**, sans présumer de sa forme.
//
// Usage :  dart tool/check_error_codes.dart
// Sortie : 0 si les trois ensembles coïncident, 1 sinon, avec le détail.

import 'dart:io';

void main() {
  final errors = File('lib/errors/app_error.dart').readAsStringSync();
  final translator = File('lib/errors/error_translator.dart').readAsStringSync();

  // Valeurs des constantes d'`AppError` — c'est le code qui circule sur le
  // réseau, pas le nom Dart.
  final declared = RegExp(r"static const String \w+ =\s*'([^']+)'|"
          r"static const String \w+ =\s*\n\s*'([^']+)'")
      .allMatches(errors)
      .map((m) => m.group(1) ?? m.group(2)!)
      .toSet();

  final frStart = translator.indexOf('const Map<String, String> _fr');
  final arStart = translator.indexOf('const Map<String, String> _ar');
  if (frStart < 0 || arStart < 0) {
    stderr.writeln('Tables _fr / _ar introuvables — le fichier a changé de forme.');
    exit(2);
  }

  // Toute clé de map, quelle que soit sa forme. Une clé peut être seule sur sa
  // ligne (valeur en dessous) ou suivie de sa valeur.
  final keyPattern = RegExp(r"^\s{2}'([^']+)':", multiLine: true);

  List<String> keysOf(String body) =>
      keyPattern.allMatches(body).map((m) => m.group(1)!).toList();

  final fr = keysOf(translator.substring(frStart, arStart));
  final ar = keysOf(translator.substring(arStart));

  var failed = false;

  void report(String label, Set<String> missing) {
    if (missing.isEmpty) return;
    failed = true;
    stdout.writeln('❌ $label : ${(missing.toList()..sort()).join(', ')}');
  }

  // Doublons d'abord : `dart analyze` les refuse, autant les nommer ici où le
  // message dit *quelle* clé, ce que l'analyseur ne fait pas.
  void duplicates(String label, List<String> keys) {
    final seen = <String>{};
    final dupes = <String>{};
    for (final k in keys) {
      if (!seen.add(k)) dupes.add(k);
    }
    report('$label — clés en double', dupes);
  }

  duplicates('FR', fr);
  duplicates('AR', ar);

  final frSet = fr.toSet();
  final arSet = ar.toSet();

  report('Codes d\'AppError sans traduction FR', declared.difference(frSet));
  report('Codes d\'AppError sans traduction AR', declared.difference(arSet));
  report('Traductions FR sans code dans AppError', frSet.difference(declared));
  report('Traductions AR sans code dans AppError', arSet.difference(declared));

  if (failed) {
    stdout.writeln('\nLes trois ensembles doivent être identiques (règle 4).');
    exit(1);
  }

  stdout.writeln(
    '✅ ${declared.length} codes — AppError, FR et AR coïncident exactement.',
  );
}
