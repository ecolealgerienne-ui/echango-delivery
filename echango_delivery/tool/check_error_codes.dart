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

  // ── Libellés d'interface du profil flotte ────────────────────────────────
  //
  // Même contrainte, même vérificateur. Les écrans existants portent ~575
  // chaînes en dur, assumées comme dette ; un écran **neuf** n'a pas à la faire
  // grandir (CLAUDE.md, règle 4). Sans ce contrôle, la table arabe se
  // désynchroniserait dès le premier libellé ajouté à la va-vite — c'est
  // exactement ce qui m'est arrivé deux fois sur les codes d'erreur, le même
  // jour, en insérant une clé par `replace` sur la mauvaise occurrence.
  // ⚠️ **Pas de `existsSync()` permissif.** La version précédente sautait ce
  // contrôle en silence si le fichier était renommé — donc un vérificateur qui
  // annonce « ✅ » sans avoir rien vérifié, ce que ce fichier dénonce en tête.
  final fleetFile = File('lib/i18n/fleet_strings.dart');
  if (!fleetFile.existsSync()) {
    stderr.writeln('lib/i18n/fleet_strings.dart introuvable — contrôle impossible.');
    exit(2);
  }
  {
    final fleet = fleetFile.readAsStringSync();
    final fleetFr = fleet.indexOf('const Map<String, String> _fr');
    final fleetAr = fleet.indexOf('const Map<String, String> _ar');

    if (fleetFr < 0 || fleetAr < 0) {
      stderr.writeln('Tables de libellés flotte introuvables.');
      exit(2);
    }

    final labelsFr = keysOf(fleet.substring(fleetFr, fleetAr));
    final labelsAr = keysOf(fleet.substring(fleetAr));

    duplicates('Libellés flotte FR', labelsFr);
    duplicates('Libellés flotte AR', labelsAr);
    report('Libellés flotte FR sans équivalent AR',
        labelsFr.toSet().difference(labelsAr.toSet()));
    report('Libellés flotte AR sans équivalent FR',
        labelsAr.toSet().difference(labelsFr.toSet()));

    // Annoncé indépendamment du reste : les deux contrôles sont distincts, et
    // masquer celui-ci parce qu'un code d'erreur manque ailleurs ferait croire
    // qu'il n'a pas tourné.
    if (labelsFr.toSet().difference(labelsAr.toSet()).isEmpty &&
        labelsAr.toSet().difference(labelsFr.toSet()).isEmpty) {
      stdout.writeln('✅ ${labelsFr.length} libellés flotte — FR et AR coïncident.');
    }
  }

  if (failed) {
    stdout.writeln('\nLes ensembles doivent être identiques (règle 4).');
    exit(1);
  }

  stdout.writeln(
    '✅ ${declared.length} codes — AppError, FR et AR coïncident exactement.',
  );
}
