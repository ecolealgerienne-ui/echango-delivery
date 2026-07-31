// Tient le barème d'espacement : refuse un littéral du barème écrit en dur, et
// recense ceux qui n'en font pas partie.
//
// ── Deux rôles, et un seul fait échouer ───────────────────────────────────
//
// **Il REFUSE** une valeur du barème (4, 8, 12, 16, 24, 32) écrite en clair
// dans un `EdgeInsets`, un `SizedBox` d'intervalle ou un `BorderRadius`. Sans
// ça, le lot du 31/07/2026 se défait au premier écran ajouté : 308 sites
// convertis d'un coup, et il suffit d'un `EdgeInsets.all(16)` pour rouvrir la
// divergence. Un chantier de centralisation sans garde n'est pas un chantier,
// c'est un instantané.
//
// **Il RECENSE**, sans échouer, les valeurs hors barème — 22 au 31/07/2026 :
// 1, 2, 6, 10, 14, 20, 36, 48. Les faire converger déplacerait des pixels : c'est
// une décision de design, elle se prend à l'écran, pas dans un script. Le
// recensement existe pour que la question reste posée au lieu de se dissoudre.
//
// ── Un intervalle n'est pas une taille ────────────────────────────────────
//
// `SizedBox(height: 16)` sépare deux éléments — barème. `SizedBox(height: 16,
// width: 16, child: CircularProgressIndicator())` dimensionne un composant —
// littéral, comme `maxLines: 1`. Changer l'échelle d'espacement ne doit pas
// redimensionner les indicateurs de chargement. D'où la lecture à parenthèses
// équilibrées : un `SizedBox` portant un `child:` est ignoré. Une regex de
// ligne ne saurait pas le voir, et c'est par chance qu'elle n'avait rien cassé.
//
// ── Il sait dire non, et il le prouve ─────────────────────────────────────
//
// `--self-test` fait passer des extraits fictifs — dont ceux qu'il doit refuser
// et ceux qu'il doit laisser passer. Un vérificateur qui n'a montré que sa
// capacité à dire oui n'a rien montré (leçon du 30/07/2026 sur les codes
// d'erreur, et du 31/07 sur `check_server_rules.dart`, dont trois faux accords
// ont survécu à sa propre suite de contrôles).
//
// Usage :  dart tool/check_spacing.dart              (contrôle réel)
//          dart tool/check_spacing.dart --self-test  (le script s'éprouve)
// Sortie : 0 si aucun littéral du barème ne subsiste, 1 sinon.

import 'dart:io';

/// Le barème tel qu'il était au 31/07/2026 — **repère de lisibilité seulement**.
///
/// La vérité est `lib/theme/app_spacing.dart`, lu à l'exécution par
/// [_declaredScale] : c'est lui qui décide ce que le script refuse. Cette carte
/// ne sert qu'à signaler un écart entre les deux, pour qu'une valeur retirée du
/// barème ne passe pas inaperçue.
const _scale = <int, String>{
  4: 'AppSpacing.xs',
  8: 'AppSpacing.sm',
  12: 'AppSpacing.md',
  16: 'AppSpacing.lg',
  24: 'AppSpacing.xl',
  32: 'AppSpacing.xxl',
};

/// Les fichiers exclus du contrôle, et pourquoi.
const _exempt = <String, String>{
  'lib/theme/app_spacing.dart': 'c’est la déclaration du barème lui-même',
};

/// Une valeur trouvée en dur.
class _Hit {
  const _Hit(this.file, this.line, this.value, this.context);
  final String file;
  final int line;
  final int value;
  final String context;
}

/// Le texte entre la parenthèse ouvrante à [open] et sa fermante, exclus.
///
/// Lecture à compteur plutôt qu'à regex : `SizedBox(...)` peut contenir un
/// `child:` avec ses propres parenthèses, et c'est précisément ce cas qu'il
/// faut reconnaître.
String? _balanced(String src, int open) {
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '(') depth++;
    if (src[i] == ')') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  return null; // parenthèse non fermée — fichier tronqué, pas notre affaire
}

/// Les nombres entiers d'un fragment d'arguments, hors sous-parenthèses.
///
/// `0` est ignoré : il ne relève d'aucune échelle, `EdgeInsets.only(top: 0)`
/// dit « rien », pas « quatre pixels ».
List<int> _numbersAtTopLevel(String fragment) {
  final out = <int>[];
  var depth = 0;
  final buffer = StringBuffer();
  void flush() {
    if (buffer.isEmpty) return;
    final v = int.tryParse(buffer.toString());
    if (v != null && v != 0) out.add(v);
    buffer.clear();
  }

  // ⚠️ Sur `16.5`, abandonner le `16` ne suffit pas : la partie décimale se
  // relisait comme un nombre à part entière et le script rendait `5`. Trouvé en
  // faisant tourner ses propres fixtures — pas en le relisant, où il paraissait
  // correct. D'où ce drapeau, qui saute aussi la suite du décimal.
  var skippingDecimal = false;

  for (var i = 0; i < fragment.length; i++) {
    final c = fragment[i];
    if (c == '(' || c == '[') depth++;
    if (c == ')' || c == ']') depth--;
    if (depth == 0 && c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) {
      if (!skippingDecimal) buffer.write(c);
      continue;
    }
    // Un `.` colle un décimal (16.5) : on abandonne le nombre entier.
    if (buffer.isNotEmpty && c == '.') {
      buffer.clear();
      skippingDecimal = true;
      continue;
    }
    skippingDecimal = false;
    flush();
  }
  flush();
  return out;
}

final _edgeInsets = RegExp(r'EdgeInsets\.(?:all|symmetric|only|fromLTRB)\(');
final _sizedBox = RegExp(r'SizedBox\(');
final _borderRadius = RegExp(r'BorderRadius\.circular\(');

/// Recense les valeurs en dur d'un fichier.
///
/// Privée comme tout le reste du script : elle rend des `_Hit`, et une
/// fonction publique qui expose un type privé est refusée par l'analyseur
/// (`library_private_types_in_public_api`).
List<_Hit> _scan(String source, String file) {
  final hits = <_Hit>[];
  int lineOf(int offset) =>
      '\n'.allMatches(source.substring(0, offset)).length + 1;

  void collect(RegExp pattern, String label, {bool skipIfHasChild = false}) {
    for (final m in pattern.allMatches(source)) {
      final args = _balanced(source, m.end - 1);
      if (args == null) continue;
      // Un `SizedBox` qui enveloppe quelque chose le dimensionne : ce n'est pas
      // un intervalle, et le barème ne le concerne pas.
      if (skipIfHasChild && args.contains('child:')) continue;
      for (final v in _numbersAtTopLevel(args)) {
        hits.add(_Hit(file, lineOf(m.start), v, label));
      }
    }
  }

  collect(_edgeInsets, 'EdgeInsets');
  collect(_sizedBox, 'SizedBox', skipIfHasChild: true);
  collect(_borderRadius, 'BorderRadius.circular');
  return hits;
}

/// Le barème déclaré par `app_spacing.dart`, lu et non supposé.
///
/// Si quelqu'un ajoute `AppSpacing.xxxl = 48`, ce script doit se mettre à
/// refuser les `48` en dur — sans qu'il faille penser à le modifier lui aussi.
/// C'est la règle 5 appliquée au vérificateur : deux copies du barème
/// divergeraient, donc il n'y en a qu'une.
Map<int, String> _declaredScale(String source) {
  final out = <int, String>{};
  for (final m in RegExp(r'class (AppSpacing|AppRadius)\b').allMatches(source)) {
    final cls = m.group(1)!;
    final end = source.indexOf('\n}', m.start);
    final body = source.substring(m.start, end == -1 ? source.length : end);
    for (final f
        in RegExp(r'static const double (\w+) = (\d+)').allMatches(body)) {
      // `AppRadius.md` vaut 8, comme `AppSpacing.sm` : le message nommera le
      // jeton d'espacement, qui est le cas de loin le plus fréquent.
      out.putIfAbsent(int.parse(f.group(2)!), () => '$cls.${f.group(1)}');
    }
  }
  return out;
}

const _fixtures = <({String name, String source, List<int> expected})>[
  (name: 'EdgeInsets du barème', source: 'EdgeInsets.all(16)', expected: [16]),
  (
    name: 'EdgeInsets déjà tokenisé',
    source: 'EdgeInsets.all(AppSpacing.lg)',
    expected: <int>[]
  ),
  (
    name: 'zéro ignoré',
    source: 'EdgeInsets.fromLTRB(16, 8, 16, 0)',
    expected: [16, 8, 16]
  ),
  (
    name: 'hors barème recensé aussi',
    source: 'EdgeInsets.only(left: 6, top: 10)',
    expected: [6, 10]
  ),
  (name: 'SizedBox intervalle', source: 'SizedBox(height: 16)', expected: [16]),
  // Le cas qui distingue une taille d'un intervalle. Écrit sur une ligne…
  (
    name: 'SizedBox taille (une ligne)',
    source: 'SizedBox(height: 16, width: 16, child: Indicator(strokeWidth: 2))',
    expected: <int>[]
  ),
  // …et sur plusieurs, forme réelle du dépôt qu'une regex de ligne ratait.
  (
    name: 'SizedBox taille (plusieurs lignes)',
    source: 'SizedBox(\n  height: 16,\n  width: 16,\n  child: Indicator(),\n)',
    expected: <int>[]
  ),
  (
    name: 'décimal non tronqué',
    source: 'EdgeInsets.all(16.5)',
    expected: <int>[]
  ),
  (
    name: 'sous-parenthèse ignorée',
    source: 'EdgeInsets.all(AppSpacing.lg).copyWith(top: Foo(12))',
    expected: <int>[]
  ),
  (
    name: 'BorderRadius du barème',
    source: 'BorderRadius.circular(8)',
    expected: [8]
  ),
  (
    name: 'BorderRadius hors barème',
    source: 'BorderRadius.circular(20)',
    expected: [20]
  ),
];

bool _selfTest() {
  var ok = true;
  for (final f in _fixtures) {
    final got = _scan(f.source, 'fixture').map((h) => h.value).toList();
    final match = got.length == f.expected.length &&
        List.generate(got.length, (i) => got[i] == f.expected[i])
            .every((e) => e);
    stdout.writeln('${match ? '✅' : '❌'} ${f.name} — $got'
        '${match ? '' : ' (attendu ${f.expected})'}');
    if (!match) ok = false;
  }

  // Le barème lu doit être celui que ce script suppose. Une divergence rendrait
  // tous les messages faux sans qu'aucun cas ne rougisse.
  const declaration = '''
class AppSpacing {
  static const double xs = 4;
  static const double xxl = 32;
}

class AppRadius {
  static const double md = 8;
}
''';
  final read = _declaredScale(declaration);
  final expectedRead = {4: 'AppSpacing.xs', 32: 'AppSpacing.xxl', 8: 'AppRadius.md'};
  final match = read.length == expectedRead.length &&
      read.entries.every((e) => expectedRead[e.key] == e.value);
  stdout.writeln('${match ? '✅' : '❌'} barème lu depuis sa déclaration — $read'
      '${match ? '' : ' (attendu $expectedRead)'}');
  if (!match) ok = false;

  return ok;
}

void main(List<String> args) {
  if (args.contains('--self-test')) {
    if (_selfTest()) {
      stdout.writeln('\n✅ ${_fixtures.length + 1} cas — le script distingue un '
          'intervalle d’une taille, et refuse ce qu’il doit refuser.');
      return;
    }
    stdout.writeln('\n❌ Le vérificateur lui-même est faux : ne pas se fier à '
        'son verdict tant que ceci n’est pas corrigé.');
    exit(1);
  }

  final spacingFile = File('lib/theme/app_spacing.dart');
  if (!spacingFile.existsSync()) {
    stderr.writeln('lib/theme/app_spacing.dart introuvable — lancez le script '
        'depuis echango_delivery/.');
    exit(2);
  }

  final scale = _declaredScale(spacingFile.readAsStringSync());
  if (scale.isEmpty) {
    stderr.writeln('Aucun jeton lu dans app_spacing.dart : le contrôle ne '
        'vaudrait rien, il s’arrête plutôt que de conclure.');
    exit(2);
  }
  // Le barème codé ici n'est qu'un repère de lisibilité ; la vérité est le
  // fichier. On signale l'écart au lieu de le laisser silencieux.
  for (final v in _scale.keys) {
    if (!scale.containsKey(v)) {
      stdout.writeln('ℹ️  $v ne figure plus dans app_spacing.dart — le contrôle '
          'suit le fichier, pas la liste de ce script.');
    }
  }

  final inScale = <_Hit>[];
  final offScale = <int, int>{};

  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    // Normalisé : sous Windows `listSync` rend des `\`, et les chemins de
    // `_exempt` ne correspondraient jamais.
    final path = entity.path.replaceAll('\\', '/');
    if (_exempt.containsKey(path)) continue;
    for (final hit in _scan(entity.readAsStringSync(), path)) {
      if (scale.containsKey(hit.value)) {
        inScale.add(hit);
      } else {
        offScale[hit.value] = (offScale[hit.value] ?? 0) + 1;
      }
    }
  }

  if (offScale.isNotEmpty) {
    final keys = offScale.keys.toList()..sort();
    stdout.writeln('ℹ️  Hors barème, laissés littéraux — les faire converger '
        'est une décision de design, pas un renommage :');
    for (final v in keys) {
      stdout.writeln('     $v → ${offScale[v]} fois');
    }
    stdout.writeln('');
  }

  if (inScale.isEmpty) {
    stdout.writeln('✅ Aucune valeur du barème écrite en dur '
        '(${scale.keys.toList()..sort()}).');
    return;
  }

  stdout.writeln('❌ ${inScale.length} valeur(s) du barème écrite(s) en dur :');
  for (final h in inScale) {
    stdout.writeln('   ${h.file}:${h.line} — ${h.context} ${h.value} '
        '→ ${scale[h.value]}');
  }
  stdout.writeln('\nLe barème existe pour que ces valeurs changent d’un seul '
      'endroit. Un littéral le rouvre.');
  exit(1);
}
