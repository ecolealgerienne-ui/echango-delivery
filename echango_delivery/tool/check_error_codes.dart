// Vérifie que les ensembles de clés traduites sont strictement identiques :
// les codes d'erreur (`AppError`, table FR, table AR) et **chaque table de
// libellés d'interface** (flotte, caisse).
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
// ── Et pourquoi il sait dire non ───────────────────────────────────────────
//
// `--self-test` l'éprouve sur des tables fabriquées, dont **toutes les formes
// de divergence qu'il doit refuser**. C'est la leçon des deux autres
// vérificateurs du dépôt (`check_spacing`, `check_server_rules`) : les deux se
// trompaient, et **aucune des erreurs n'a été trouvée en les relisant** — elles
// l'ont été en les faisant tourner sur des mutations. Un vérificateur au vert
// n'a montré que sa capacité à dire oui.
//
// Usage :  dart tool/check_error_codes.dart [--self-test]
// Sortie : 0 si tout coïncide, 1 sinon, avec le détail.

import 'dart:io';

// ── Lecture d'une table ────────────────────────────────────────────────────

/// Toute clé de map, quelle que soit sa forme. Une clé peut être seule sur sa
/// ligne (valeur en dessous) ou suivie de sa valeur.
final _keyPattern = RegExp(r"^\s{2}'([^']+)':", multiLine: true);

/// Les segments de chaîne d'une valeur, concaténation adjacente comprise.
final _stringPattern = RegExp(r"'((?:[^'\\]|\\.)*)'");

/// Les variables `{nom}` d'un libellé.
final _varPattern = RegExp(r'\{(\w+)\}');

/// Le corps d'une table, de sa déclaration à son accolade fermante.
String _mapBody(String source, int start) {
  final end = source.indexOf('\n};', start);
  return end < 0 ? source.substring(start) : source.substring(start, end);
}

/// Les clés d'une table, **dans l'ordre du fichier** — les doublons comptent.
List<String> _keysOf(String body) =>
    _keyPattern.allMatches(body).map((m) => m.group(1)!).toList();

/// La valeur de chaque clé, segments recollés.
///
/// ⚠️ Recoller est nécessaire, pas cosmétique : une valeur longue est écrite
/// en plusieurs morceaux adjacents, et ne lire que le premier ferait manquer
/// toute variable située après le premier retour à la ligne.
Map<String, String> _valuesOf(String body) {
  final matches = _keyPattern.allMatches(body).toList();
  final out = <String, String>{};

  for (var i = 0; i < matches.length; i++) {
    final from = matches[i].end;
    final to = i + 1 < matches.length ? matches[i + 1].start : body.length;
    final slice = body.substring(from, to);
    out[matches[i].group(1)!] =
        _stringPattern.allMatches(slice).map((m) => m.group(1)!).join();
  }
  return out;
}

/// Le résultat d'un contrôle : la liste des reproches, vide si tout va bien.
///
/// Rendre des reproches plutôt qu'imprimer permet à `--self-test` de vérifier
/// **ce que le contrôle dit**, et pas seulement qu'il a dit quelque chose.
/// La déclaration exacte d'une table, **accolade comprise**.
///
/// ⚠️ Sans `= {`, `indexOf` matche un PRÉFIXE : `_ar` trouve `_arabe`, et le
/// contrôle repart en silence sur une table qui ne porte plus le nom attendu —
/// donc sur un fichier restructuré qu'il est justement censé refuser. Trouvé en
/// **mutant le vrai fichier**, pas en relisant : les quatre autres mutations
/// étaient refusées, celle-ci passait au vert.
String _decl(String name) => 'const Map<String, String> $name = {';

List<String> checkLabelTable(String source, String what) {
  final frStart = source.indexOf(_decl('_fr'));
  final arStart = source.indexOf(_decl('_ar'));

  // ⚠️ Pas de tolérance ici. Un fichier renommé ou restructuré doit **arrêter**
  // le contrôle, pas le faire passer : un vérificateur qui annonce « ✅ » sans
  // avoir rien vérifié est exactement ce que ce fichier dénonce en tête.
  if (frStart < 0 || arStart < 0 || arStart < frStart) {
    return ['$what : tables _fr / _ar introuvables — le fichier a changé de forme.'];
  }

  // ⚠️ Bornées à leur accolade fermante, pas au début de la table suivante.
  //
  // Sans ça, la dernière clé d'`_ar` avale tout ce qui suit la table — et
  // `fleet_strings.dart` fait suivre `fleetLabelTables = {'fr': _fr, 'ar': _ar}`,
  // dont les deux chaînes se retrouvaient collées à la valeur de cette clé. Sans
  // conséquence aujourd'hui, mais c'est le genre d'à-peu-près dont un
  // vérificateur ne peut pas se permettre : il fonde ce qu'il affirme.
  final frBody = _mapBody(source, frStart);
  final arBody = _mapBody(source, arStart);
  final fr = _keysOf(frBody);
  final ar = _keysOf(arBody);
  final problems = <String>[];

  void duplicates(String side, List<String> keys) {
    final seen = <String>{};
    final dupes = <String>{};
    for (final k in keys) {
      if (!seen.add(k)) dupes.add(k);
    }
    if (dupes.isNotEmpty) {
      problems.add('$what $side — clés en double : '
          '${(dupes.toList()..sort()).join(', ')}');
    }
  }

  duplicates('FR', fr);
  duplicates('AR', ar);

  final frSet = fr.toSet();
  final arSet = ar.toSet();
  final missingAr = frSet.difference(arSet);
  final missingFr = arSet.difference(frSet);

  if (missingAr.isNotEmpty) {
    problems.add('$what FR sans équivalent AR : '
        '${(missingAr.toList()..sort()).join(', ')}');
  }
  if (missingFr.isNotEmpty) {
    problems.add('$what AR sans équivalent FR : '
        '${(missingFr.toList()..sort()).join(', ')}');
  }

  // ── Les variables, et dans UN SEUL sens ──────────────────────────────────
  //
  // Une variable présente en arabe et absente en français est un défaut
  // certain : l'appelant fournit ce que le français demande, donc le `{foo}`
  // arabe ne serait jamais substitué et **s'afficherait tel quel** à l'écran.
  //
  // L'inverse est légitime, et c'est pourquoi le contrôle est asymétrique :
  // « عملية تسليم واحدة » dit « une livraison » sans reprendre le chiffre. Le
  // refuser obligerait à écrire un arabe fautif pour faire plaisir au script.
  final frValues = _valuesOf(frBody);
  final arValues = _valuesOf(arBody);
  for (final key in arValues.keys) {
    if (!frValues.containsKey(key)) continue;
    final inAr = _varPattern.allMatches(arValues[key]!).map((m) => m.group(1)!).toSet();
    final inFr = _varPattern.allMatches(frValues[key]!).map((m) => m.group(1)!).toSet();
    final extra = inAr.difference(inFr);
    if (extra.isNotEmpty) {
      problems.add('$what « $key » — variable AR que le français ne fournit '
          'pas : ${(extra.toList()..sort()).map((v) => '{$v}').join(', ')}');
    }
  }

  return problems;
}

// ── Programme ──────────────────────────────────────────────────────────────

void main(List<String> args) {
  if (args.contains('--self-test')) {
    _selfTest();
    return;
  }

  var failed = false;
  void report(String label, Set<String> missing) {
    if (missing.isEmpty) return;
    failed = true;
    stdout.writeln('❌ $label : ${(missing.toList()..sort()).join(', ')}');
  }

  // ── Codes d'erreur ────────────────────────────────────────────────────────
  final errors = File('lib/errors/app_error.dart').readAsStringSync();
  final translator = File('lib/errors/error_translator.dart').readAsStringSync();

  // Valeurs des constantes d'`AppError` — c'est le code qui circule sur le
  // réseau, pas le nom Dart.
  final declared = RegExp(r"static const String \w+ =\s*'([^']+)'|"
          r"static const String \w+ =\s*\n\s*'([^']+)'")
      .allMatches(errors)
      .map((m) => m.group(1) ?? m.group(2)!)
      .toSet();

  final codeProblems = checkLabelTable(translator, 'Codes');
  for (final p in codeProblems) {
    failed = true;
    stdout.writeln('❌ $p');
  }

  final frStart = translator.indexOf(_decl('_fr'));
  final arStart = translator.indexOf(_decl('_ar'));
  if (frStart < 0 || arStart < 0) exit(2);
  final frSet = _keysOf(_mapBody(translator, frStart)).toSet();
  final arSet = _keysOf(_mapBody(translator, arStart)).toSet();


  // ── Le registre SERVEUR, seule source des codes qui circulent ─────────────
  //
  // ⚠️ Ce contrôle n'existait pas, et c'est le trou le plus coûteux du
  // vérificateur (revue du 01/08/2026, A6) : il ne comparait que les **trois
  // tables Dart entre elles**. Elles pouvaient donc s'accorder parfaitement en
  // ayant toutes les trois oublié le même code — exactement la situation
  // d'`isClaimable`/`isClaimableAdhoc`, où deux copies d'accord ne prouvaient
  // rien.
  //
  // L'en-tête d'`error-codes.ts` l'admettait d'ailleurs : « la correspondance
  // se vérifie **par lecture**, comme le reste des contrats de ce projet ».
  // Une lecture ne peut pas échouer. Le prochain `badRequest('cash.xxx', …)`
  // ajouté au serveur passait la compilation, passait ce contrôle, et
  // l'utilisateur recevait un message générique dans la situation précise où le
  // code avait été inventé pour lui dire quoi faire.
  //
  // La capacité existait ailleurs : `check_server_rules.dart` lit un fichier
  // TypeScript et un fichier Dart et les compare, avec 22 cas de refus. Elle
  // n'était simplement pas appliquée ici.
  //
  // ⚠️ Le chemin est **explicite et son absence est une erreur**, comme pour les
  // tables de libellés : un fichier déplacé doit faire échouer le contrôle,
  // jamais le faire passer au vert en ne trouvant rien.
  final serverFile = File('../backend/bff/src/common/errors/error-codes.ts');
  if (!serverFile.existsSync()) {
    stderr.writeln('${serverFile.path} introuvable — contrôle impossible.');
    exit(2);
  }
  final serverCodes = RegExp(r"^\s{2}[A-Z0-9_]+:\s*'([^']+)',", multiLine: true)
      .allMatches(serverFile.readAsStringSync())
      .map((m) => m.group(1)!)
      .toSet();

  // Un motif qui ne matche plus rien passerait au vert sans rien vérifier :
  // c'est la forme la plus discrète du contrôle qui ne sait que dire oui.
  if (serverCodes.isEmpty) {
    stderr.writeln('Aucun code lu dans ${serverFile.path} — le motif ne '
        'correspond plus au fichier.');
    exit(2);
  }

  report('Codes du BFF absents d\'AppError', serverCodes.difference(declared));
  // L'inverse n'est PAS une erreur : `app_error.dart` porte en plus des codes
  // client-only documentés (réseau, permissions, capture photo), que le serveur
  // n'a aucune raison de connaître.
  stdout.writeln('✅ ${serverCodes.length} codes du BFF — tous connus du client.');

  report('Codes d\'AppError sans traduction FR', declared.difference(frSet));
  report('Codes d\'AppError sans traduction AR', declared.difference(arSet));
  report('Traductions FR sans code dans AppError', frSet.difference(declared));
  report('Traductions AR sans code dans AppError', arSet.difference(declared));

  // ── Libellés d'interface ──────────────────────────────────────────────────
  //
  // Les écrans existants portent ~575 chaînes en dur, assumées comme dette ; un
  // écran **neuf** n'a pas à la faire grandir (règle 4). Sans ce contrôle, la
  // table arabe se désynchronise dès le premier libellé ajouté à la va-vite —
  // ce qui m'est arrivé deux fois sur les codes d'erreur, le même jour.
  //
  // ⚠️ La liste est **explicite**, pas un balayage de `lib/i18n/`. Un balayage
  // qui ne trouve rien passe au vert : un fichier renommé cesserait d'être
  // vérifié en silence, alors qu'ici il fait échouer le contrôle.
  const tables = {
    'lib/i18n/fleet_strings.dart': 'Libellés flotte',
    'lib/i18n/collections_strings.dart': 'Libellés encaissements',
    'lib/i18n/order_strings.dart': 'Libellés des livraisons',
    'lib/i18n/driver_strings.dart': 'Libellés espace transporteur',
    'lib/i18n/auth_strings.dart': 'Libellés connexion',
    'lib/i18n/common_strings.dart': 'Libellés partagés',
  };

  for (final entry in tables.entries) {
    final file = File(entry.key);
    if (!file.existsSync()) {
      stderr.writeln('${entry.key} introuvable — contrôle impossible.');
      exit(2);
    }

    final problems = checkLabelTable(file.readAsStringSync(), entry.value);
    if (problems.isEmpty) {
      final source = file.readAsStringSync();
      final n = _keysOf(_mapBody(source, source.indexOf(_decl('_fr')))).length;
      // Annoncé indépendamment du reste : masquer ce contrôle parce qu'un code
      // d'erreur manque ailleurs ferait croire qu'il n'a pas tourné.
      stdout.writeln('✅ $n ${entry.value.toLowerCase()} — FR et AR coïncident.');
    } else {
      failed = true;
      for (final p in problems) {
        stdout.writeln('❌ $p');
      }
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

// ── Le vérificateur doit prouver qu'il sait dire NON ───────────────────────

void _selfTest() {
  var failed = 0;

  void expect(String label, List<String> got, {required bool shouldFail}) {
    final ok = shouldFail ? got.isNotEmpty : got.isEmpty;
    stdout.writeln('${ok ? '  ✅' : '  ❌'} $label'
        '${ok ? '' : ' — obtenu : ${got.isEmpty ? 'rien' : got.join(' | ')}'}');
    if (!ok) failed++;
  }

  String table(String fr, String ar) => '''
const Map<String, String> _fr = {
$fr};

const Map<String, String> _ar = {
$ar};
''';

  stdout.writeln('── ce qui doit passer ──');
  expect(
    'deux tables identiques',
    checkLabelTable(
        table("  'a.b': 'Bonjour',\n  'c.d': 'Merci',\n",
            "  'a.b': 'مرحبا',\n  'c.d': 'شكرا',\n"),
        'T'),
    shouldFail: false,
  );
  expect(
    'une clé SANS point (le défaut du 30/07 : elle doit être vue)',
    checkLabelTable(
        table("  'not_found': 'Introuvable',\n", "  'not_found': 'غير موجود',\n"), 'T'),
    shouldFail: false,
  );
  expect(
    'une valeur écrite en plusieurs morceaux',
    checkLabelTable(
        table("  'a.b':\n      'Un texte long '\n          'coupé en deux.',\n",
            "  'a.b': 'نص طويل.',\n"),
        'T'),
    shouldFail: false,
  );
  expect(
    'même variable des deux côtés',
    checkLabelTable(
        table("  'a.b': 'Max {amount}',\n", "  'a.b': 'الحد {amount}',\n"), 'T'),
    shouldFail: false,
  );
  expect(
    'le français a une variable que l’arabe n’emploie pas (singulier arabe)',
    checkLabelTable(
        table("  'a.one': '{count} livraison',\n", "  'a.one': 'عملية واحدة',\n"), 'T'),
    shouldFail: false,
  );

  stdout.writeln('── ce qui doit ÉCHOUER ──');
  expect(
    'une clé absente de l’arabe',
    checkLabelTable(table("  'a.b': 'Bonjour',\n  'c.d': 'Merci',\n", "  'a.b': 'مرحبا',\n"), 'T'),
    shouldFail: true,
  );
  expect(
    'une clé absente du français',
    checkLabelTable(table("  'a.b': 'Bonjour',\n", "  'a.b': 'مرحبا',\n  'c.d': 'شكرا',\n"), 'T'),
    shouldFail: true,
  );
  expect(
    'un doublon côté français',
    checkLabelTable(
        table("  'a.b': 'Bonjour',\n  'a.b': 'Rebonjour',\n", "  'a.b': 'مرحبا',\n"), 'T'),
    shouldFail: true,
  );
  expect(
    'un doublon côté arabe',
    checkLabelTable(
        table("  'a.b': 'Bonjour',\n", "  'a.b': 'مرحبا',\n  'a.b': 'أهلا',\n"), 'T'),
    shouldFail: true,
  );
  expect(
    'une variable arabe que le français ne fournit pas (elle s’afficherait brute)',
    checkLabelTable(
        table("  'a.b': 'Maximum atteint',\n", "  'a.b': 'الحد {amount}',\n"), 'T'),
    shouldFail: true,
  );
  expect(
    'une variable arabe cachée dans le SECOND morceau d’une valeur coupée',
    checkLabelTable(
        table("  'a.b': 'Texte sans variable',\n",
            "  'a.b': 'نص طويل '\n      'جداً {amount}',\n"),
        'T'),
    shouldFail: true,
  );
  expect(
    'un fichier qui a changé de forme',
    checkLabelTable('const Map<String, String> _francais = {};', 'T'),
    shouldFail: true,
  );
  expect(
    'la table arabe RENOMMÉE en _arabe (le préfixe ne doit pas suffire)',
    checkLabelTable(
        "const Map<String, String> _fr = {\n  'a.b': 'B',\n};\n"
        "const Map<String, String> _arabe = {\n  'a.b': 'م',\n};\n",
        'T'),
    shouldFail: true,
  );
  expect(
    'les tables dans le désordre (_ar avant _fr)',
    checkLabelTable(
        "const Map<String, String> _ar = {\n  'a.b': 'م',\n};\n"
        "const Map<String, String> _fr = {\n  'a.b': 'B',\n};\n",
        'T'),
    shouldFail: true,
  );

  if (failed > 0) {
    stdout.writeln('\n$failed cas en échec — le vérificateur ne vérifie pas ce '
        'qu\'il annonce.');
    exit(1);
  }
  stdout.writeln('\n✅ 14 cas — le contrôle sait dire oui ET non.');
}
