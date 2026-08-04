// Vérifie que les LISTES FERMÉES recopiées côté app valent bien celles du BFF.
//
// ── Pourquoi ce script ────────────────────────────────────────────────────
//
// Règle 5 du projet : un invariant s'applique, il ne se documente pas. Trois
// listes de codes fermées vivent des DEUX côtés — motifs de refus d'une course,
// motifs d'échec de livraison, motifs d'écart d'encaissement. Le serveur les
// applique (`@IsIn(...)`, `assertCollectedAmount`), l'app les propose dans un
// sélecteur. Si l'une diverge, rien n'échoue à la compilation : l'app offre en
// silence un code que le serveur refusera en 400 (« validation.failed »), ou en
// omet un que le serveur accepte. `check_server_rules.dart` ne couvre que les
// quatre bornes NUMÉRIQUES ; ces listes n'avaient aucun garde. C'est exactement
// la divergence silencieuse que ce dépôt bâtit des vérificateurs pour empêcher.
//
// ── Ce qu'il compare, et ce qu'il ne compare pas ──────────────────────────
//
// Il compare les codes comme des ENSEMBLES : un code en trop côté app (refusé
// par le serveur) ou un code manquant (jamais proposé) sont les deux vraies
// pannes. L'ORDRE, lui, est cosmétique (ordre d'un menu), et n'est pas vérifié —
// le forcer ferait échouer sur un choix d'ergonomie légitime.
//
// ── Comment il extrait, et les pièges fermés ──────────────────────────────
//
//  * Les commentaires sont blanchis AVANT extraction (en conservant les retours
//    à la ligne) : un code cité en prose dans un `/** … */` ne doit pas compter.
//  * Le bloc de liste est délimité par appariement des crochets `[ ]`, pas par
//    « jusqu'au prochain `]` » : robuste à une liste imbriquée ou à un type
//    générique `<(String, IconData)>` qui précède le `[`.
//  * Seules les chaînes QUOTÉES du bloc sont retenues — côté app la liste de
//    refus est une liste de tuples `('code', Icons.x)`, et les `Icons.x` ne sont
//    pas quotés, donc naturellement ignorés.
//
// ⚠️ **Refuse plutôt que de conclure à tort.** Une liste introuvable (renommée,
// déplacée) ou un bloc aux crochets non appariés rend `null`, et le contrôle
// ÉCHOUE — un vérificateur qui ne trouve pas ce qu'il cherche et dit « d'accord »
// est pire que pas de vérificateur (leçon du 30/07/2026 sur les codes d'erreur).
//
// ⚠️ **Limite connue** (héritée de `check_server_rules.dart`) : le blanchiment
// des commentaires ne distingue pas un `//` à l'intérieur d'une chaîne. Sans
// effet ici — les codes n'en contiennent pas —, mais à savoir avant d'étendre.
//
// ── Il sait dire non, et il le prouve ─────────────────────────────────────
//
// `--self-test` éprouve l'extraction ET la comparaison sur des cas fictifs, dont
// toutes les formes de divergence qu'il doit refuser (code en trop, code
// manquant, liste introuvable, code caché dans un commentaire).
//
// Usage :  dart tool/check_closed_lists.dart              (contrôle réel)
//          dart tool/check_closed_lists.dart --self-test  (le script s'éprouve)
// Sortie : 0 si tout concorde, 1 sinon.

import 'dart:io';

/// Une liste fermée reproduite des deux côtés.
class _ClosedList {
  const _ClosedList({
    required this.what,
    required this.serverFile,
    required this.serverAnchor,
    required this.clientFile,
    required this.clientAnchor,
  });

  /// Ce que la liste énumère, pour un message lisible.
  final String what;

  /// Fichier du BFF, relatif à la racine du dépôt.
  final String serverFile;

  /// Motif qui matche le début de la liste serveur, jusqu'au `[` inclus.
  final String serverAnchor;

  /// Fichier de l'app, relatif à `echango_delivery/`.
  final String clientFile;

  /// Motif qui matche le début de la liste client, jusqu'au `[` inclus.
  final String clientAnchor;
}

const _lists = <_ClosedList>[
  _ClosedList(
    what: 'motifs de refus d’une course',
    serverFile: 'backend/bff/src/transporteur/dto/transporteur.dto.ts',
    serverAnchor: r'DECLINE_REASONS\s*=\s*\[',
    clientFile: 'lib/screens/transporteur/order_detail_screen.dart',
    clientAnchor: r'_reasons\s*=\s*<\(String, IconData\)>\s*\[',
  ),
  _ClosedList(
    what: 'motifs d’échec de livraison',
    serverFile: 'backend/bff/src/transporteur/dto/transporteur.dto.ts',
    serverAnchor: r'DELIVERY_FAILURE_REASONS\s*=\s*\[',
    clientFile: 'lib/models/order.dart',
    clientAnchor: r'deliveryFailureReasons\s*=\s*(?:<[^\[]*>\s*)?\[',
  ),
  _ClosedList(
    what: 'motifs d’écart d’encaissement',
    serverFile: 'backend/bff/src/common/money/collection.ts',
    serverAnchor: r'COLLECTION_DISCREPANCY_REASONS\s*=\s*\[',
    clientFile: 'lib/i18n/collections_strings.dart',
    clientAnchor: r'collectionDiscrepancyReasons\s*=\s*(?:<[^\[]*>\s*)?\[',
  ),
];

final _commentPattern = RegExp(r'//[^\n]*|/\*[\s\S]*?\*/');
final _notNewline = RegExp(r'[^\n]');
final _quotedString = RegExp(r'''(?:'([^'\n]*)'|"([^"\n]*)")''');

/// Blanchit les commentaires en conservant les retours à la ligne.
String _stripComments(String source) => source.replaceAllMapped(
      _commentPattern,
      (m) => m.group(0)!.replaceAll(_notNewline, ' '),
    );

/// L'ensemble des codes de la liste désignée par [anchor], ou `null` si la liste
/// est introuvable ou ses crochets ne s'apparient pas — deux cas où l'on ne peut
/// rien conclure, donc où il faut échouer plutôt qu'affirmer un accord.
Set<String>? _extractList(String rawSource, String anchor) {
  final source = _stripComments(rawSource);
  final m = RegExp(anchor).firstMatch(source);
  if (m == null) return null;

  // L'ancre se termine sur le `[` d'ouverture : on est donc à profondeur 1.
  var depth = 1;
  var i = m.end;
  while (i < source.length && depth > 0) {
    final c = source[i];
    if (c == '[') {
      depth++;
    } else if (c == ']') {
      depth--;
    }
    i++;
  }
  if (depth != 0) return null; // crochets non appariés

  final block = source.substring(m.end, i - 1);
  return _quotedString
      .allMatches(block)
      .map((s) => s.group(1) ?? s.group(2)!)
      .toSet();
}

// ── Auto-test ──────────────────────────────────────────────────────────────

class _Fixture {
  const _Fixture(this.name, this.source, this.anchor, this.expected);
  final String name;
  final String source;
  final String anchor;
  final Set<String>? expected;
}

const _fixtures = <_Fixture>[
  _Fixture('liste TS nominale', '''
export const R = [
  'a',
  'b',
  'c',
] as const;
''', r'R\s*=\s*\[', {'a', 'b', 'c'}),
  _Fixture('commentaires entre items', '''
export const R = [
  /** premier */
  'a',
  // deuxième
  'b',
] as const;
''', r'R\s*=\s*\[', {'a', 'b'}),
  _Fixture('code cité dans un commentaire, ignoré', '''
export const R = [
  'a',
  // ne pas ajouter 'z' ici
] as const;
''', r'R\s*=\s*\[', {'a'}),
  _Fixture('liste Dart de tuples (code, icône)', '''
static const _reasons = <(String, IconData)>[
  ('a', Icons.x),
  ('b', Icons.y),
];
''', r'_reasons\s*=\s*<\(String, IconData\)>\s*\[', {'a', 'b'}),
  _Fixture('liste Dart typée', '''
const List<String> reasons = <String>[
  'a',
  'b',
];
''', r'reasons\s*=\s*(?:<[^\[]*>\s*)?\[', {'a', 'b'}),
  // Ceux que l'extraction doit refuser (rendre null) :
  _Fixture('liste introuvable → null', '''
export const AUTRE = ['a'];
''', r'R\s*=\s*\[', null),
];

/// La comparaison, éprouvée elle aussi : accord, code en trop, code manquant.
const _compareFixtures =
    <({String name, Set<String> server, Set<String> client, bool shouldAgree})>[
  (name: 'accord', server: {'a', 'b'}, client: {'a', 'b'}, shouldAgree: true),
  (name: 'accord, ordre différent', server: {'a', 'b'}, client: {'b', 'a'}, shouldAgree: true),
  (name: 'code en trop côté app', server: {'a', 'b'}, client: {'a', 'b', 'z'}, shouldAgree: false),
  (name: 'code manquant côté app', server: {'a', 'b', 'c'}, client: {'a', 'b'}, shouldAgree: false),
];

bool _selfTest() {
  var ok = true;
  for (final f in _fixtures) {
    final got = _extractList(f.source, f.anchor);
    final match = got == null
        ? f.expected == null
        : f.expected != null &&
            got.length == f.expected!.length &&
            got.every(f.expected!.contains);
    stdout.writeln('${match ? '✅' : '❌'} ${f.name} — ${got?.toList()}'
        '${match ? '' : ' (attendu ${f.expected?.toList()})'}');
    if (!match) ok = false;
  }
  for (final f in _compareFixtures) {
    final agree = f.server.length == f.client.length && f.server.every(f.client.contains);
    final match = agree == f.shouldAgree;
    stdout.writeln('${match ? '✅' : '❌'} ${f.name} — accord=$agree'
        '${match ? '' : ' (attendu ${f.shouldAgree})'}');
    if (!match) ok = false;
  }
  return ok;
}

void main(List<String> args) {
  if (args.contains('--self-test')) {
    final total = _fixtures.length + _compareFixtures.length;
    if (_selfTest()) {
      stdout.writeln('\n✅ $total cas — le script reconnaît les divergences '
          'qu\'il doit refuser.');
      return;
    }
    stdout.writeln('\n❌ Le vérificateur lui-même est faux : ne pas se fier à '
        'son verdict tant que ceci n\'est pas corrigé.');
    exit(1);
  }

  if (!File('lib/models/order.dart').existsSync()) {
    stderr.writeln('Fichiers de l’app introuvables — lancez le script depuis '
        'echango_delivery/.');
    exit(2);
  }

  var failed = false;
  void fail(String message) {
    stdout.writeln('❌ $message');
    failed = true;
  }

  for (final list in _lists) {
    final serverFile = File('../${list.serverFile}');
    final clientFile = File(list.clientFile);
    if (!serverFile.existsSync()) {
      fail('${list.what} : ${list.serverFile} introuvable (fichier déplacé ?)');
      continue;
    }
    if (!clientFile.existsSync()) {
      fail('${list.what} : ${list.clientFile} introuvable (fichier déplacé ?)');
      continue;
    }

    final server = _extractList(serverFile.readAsStringSync(), list.serverAnchor);
    final client = _extractList(clientFile.readAsStringSync(), list.clientAnchor);

    if (server == null || server.isEmpty) {
      fail('${list.what} : liste serveur introuvable ou vide dans '
          '${list.serverFile}.\n   Renommée, ou déclarée sous une forme que le '
          'script ne sait pas lire ? Tant que ce n’est pas levé, un accord ne '
          'vaudrait rien.');
      continue;
    }
    if (client == null || client.isEmpty) {
      fail('${list.what} : liste app introuvable ou vide dans '
          '${list.clientFile}.\n   Renommée, ou déclarée sous une forme que le '
          'script ne sait pas lire ?');
      continue;
    }

    final extra = client.difference(server); // dans l'app, pas côté serveur
    final missing = server.difference(client); // côté serveur, pas dans l'app
    if (extra.isNotEmpty || missing.isNotEmpty) {
      final lignes = <String>[];
      if (extra.isNotEmpty) {
        lignes.add('   en trop côté app (le serveur les REFUSERA) : ${extra.join(', ')}');
      }
      if (missing.isNotEmpty) {
        lignes.add('   jamais proposés par l’app (le serveur les accepte) : ${missing.join(', ')}');
      }
      fail('${list.what} : la liste app diverge de ${list.serverFile}.\n'
          '${lignes.join('\n')}');
    }
  }

  if (failed) {
    stdout.writeln('\nUne liste fermée a divergé de son original serveur.');
    exit(1);
  }

  stdout.writeln('✅ ${_lists.length} listes fermées reproduites, toutes '
      'd’accord avec leur original serveur.');
}
