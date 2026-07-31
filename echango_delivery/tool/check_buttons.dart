// Refuse un `ElevatedButton` dans les écrans, et un style destructeur recopié.
//
// ── Pourquoi un contrôle, et pas la convention écrite quelque part ─────────
//
// Parce qu'un commentaire ne peut pas échouer (règle 5). La convention est dans
// `lib/theme/app_buttons.dart` ; ce script est ce qui la tient.
//
// Mesuré le 31/07/2026, avant : 15 `ElevatedButton` côté transporteur contre
// 5 `FilledButton` côté entreprise — le profil conducteur était en Material 2
// et celui de la société en Material 3, **dans la même application**. Personne
// ne l'avait décidé : c'est ce que produit la recopie, écran après écran. Et
// dans un seul écran, `FlotteHomeScreen` servait l'action principale d'une
// ligne en bouton plein dans un onglet et en lien dans l'autre.
//
// ── Ce qu'il refuse ────────────────────────────────────────────────────────
//
//  1. `ElevatedButton` sous `lib/` — l'application déclare `useMaterial3`, et
//     le thème le repeignait en primaire, donc deux boutons principaux
//     d'aspect différent selon l'écran où l'on se trouvait.
//  2. Un style destructeur écrit à la main (`colorScheme.error` posé dans un
//     `styleFrom`) — il l'était sept fois, en deux variantes qui ne
//     s'accordaient pas : quatre posaient le fond ET le libellé, trois
//     seulement le fond, donc un texte en couleur par défaut sur rouge dont le
//     contraste n'était garanti par personne.
//
// ── Ce qu'il NE refuse pas ─────────────────────────────────────────────────
//
// Le choix entre `FilledButton`, `.tonal`, `OutlinedButton` et `TextButton`.
// C'est une question d'intention, elle se juge à l'écran, et un script qui
// prétendrait la trancher se tromperait plus souvent qu'il n'aiderait.
//
// Usage :  dart tool/check_buttons.dart [--self-test]
// Sortie : 0 si rien à signaler, 1 sinon.

import 'dart:io';

/// Un reproche : le fichier, la ligne, et ce qu'il faut faire.
class Finding {
  Finding(this.file, this.line, this.message);
  final String file;
  final int line;
  final String message;

  @override
  String toString() => '$file:$line — $message';
}

/// ⚠️ Le thème est **exclu** : c'est le seul endroit où une couleur d'erreur et
/// une forme de bouton se décident. L'y interdire reviendrait à interdire de
/// définir la convention qu'on fait respecter ailleurs.
bool _exempt(String path) =>
    path.replaceAll('\\', '/').contains('lib/theme/');

List<Finding> inspect(String path, String source) {
  final findings = <Finding>[];
  if (_exempt(path)) return findings;

  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    // Les commentaires ne sont pas du code. Sans ce filtre, la ligne qui
    // EXPLIQUE pourquoi `ElevatedButton` est proscrit se ferait signaler —
    // le contrôle refuserait sa propre justification.
    final code = _stripComment(line);
    if (code.trim().isEmpty) continue;

    if (RegExp(r'\bElevatedButton\b').hasMatch(code)) {
      findings.add(Finding(path, i + 1,
          'ElevatedButton — l’application est en Material 3 : utilisez '
          'FilledButton (voir theme/app_buttons.dart)'));
    }

    // Un `colorScheme.error` dans un `styleFrom` : le style destructeur, écrit
    // à la main. Le repérage porte sur la ligne du `styleFrom` **et** sur les
    // quelques lignes qui la suivent, la couleur étant rarement sur la même.
    if (RegExp(r'\b(FilledButton|OutlinedButton|TextButton)\.styleFrom\b')
        .hasMatch(code)) {
      final until = (i + 6).clamp(0, lines.length);
      for (var j = i; j < until; j++) {
        if (RegExp(r'colorScheme\.(error|onError)').hasMatch(_stripComment(lines[j]))) {
          findings.add(Finding(path, i + 1,
              'style destructeur écrit à la main — utilisez '
              'AppButtonStyles.destructiveFilled/Outlined/Text'));
          break;
        }
      }
    }
  }
  return findings;
}

/// Retire un commentaire de fin de ligne, **sans casser une chaîne**.
///
/// ⚠️ Une URL contient `//`. Couper au premier `//` venu transformerait
/// `'https://tile.openstreetmap.org/…'` en chaîne non terminée pour la suite
/// de l'analyse — et le contrôle se mettrait à voir des choses qui n'existent
/// pas, ou à ne plus rien voir.
String _stripComment(String line) {
  var inString = false;
  String? quote;
  for (var i = 0; i < line.length - 1; i++) {
    final c = line[i];
    if (inString) {
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        inString = false;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      inString = true;
      quote = c;
      continue;
    }
    if (c == '/' && line[i + 1] == '/') return line.substring(0, i);
  }
  return line;
}

void main(List<String> args) {
  if (args.contains('--self-test')) {
    _selfTest();
    return;
  }

  final root = Directory('lib');
  if (!root.existsSync()) {
    stderr.writeln('lib/ introuvable — lancez depuis echango_delivery/.');
    exit(2);
  }

  final findings = <Finding>[];
  var scanned = 0;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    scanned++;
    findings.addAll(inspect(entity.path, entity.readAsStringSync()));
  }

  if (findings.isEmpty) {
    stdout.writeln('✅ $scanned fichiers — aucun ElevatedButton, aucun style '
        'destructeur recopié.');
    return;
  }

  for (final f in findings) {
    stdout.writeln('❌ $f');
  }
  stdout.writeln('\n${findings.length} à corriger. La convention est dans '
      'lib/theme/app_buttons.dart.');
  exit(1);
}

// ── Le vérificateur doit prouver qu'il sait dire NON ───────────────────────

void _selfTest() {
  var failed = 0;

  void expect(String label, List<Finding> got, {required bool shouldFail}) {
    final ok = shouldFail ? got.isNotEmpty : got.isEmpty;
    stdout.writeln('${ok ? '  ✅' : '  ❌'} $label'
        '${ok ? '' : ' — obtenu : ${got.isEmpty ? 'rien' : got.join(' | ')}'}');
    if (!ok) failed++;
  }

  stdout.writeln('── ce qui doit passer ──');
  expect('un FilledButton', inspect('lib/screens/x.dart', '''
FilledButton(onPressed: f, child: const Text('Publier'))
'''), shouldFail: false);

  expect('le style destructeur partagé', inspect('lib/screens/x.dart', '''
FilledButton(style: AppButtonStyles.destructiveFilled(context), child: t)
'''), shouldFail: false);

  expect('un styleFrom SANS couleur d’erreur', inspect('lib/screens/x.dart', '''
FilledButton(
  style: FilledButton.styleFrom(padding: EdgeInsets.zero),
  child: t,
)
'''), shouldFail: false);

  expect('le COMMENTAIRE qui explique la règle', inspect('lib/screens/x.dart', '''
// ElevatedButton n'a plus sa place ici : voir theme/app_buttons.dart.
FilledButton(onPressed: f, child: t)
'''), shouldFail: false);

  expect('le thème, qui a le droit de décider', inspect('lib/theme/app_theme.dart', '''
elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom())
'''), shouldFail: false);

  expect('une URL contenant // dans une chaîne', inspect('lib/widgets/m.dart', '''
const t = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
FilledButton(onPressed: f, child: c)
'''), shouldFail: false);

  stdout.writeln('── ce qui doit ÉCHOUER ──');
  expect('un ElevatedButton dans un écran', inspect('lib/screens/x.dart', '''
ElevatedButton(onPressed: f, child: const Text('Valider'))
'''), shouldFail: true);

  expect('un ElevatedButton.icon', inspect('lib/screens/x.dart', '''
ElevatedButton.icon(onPressed: f, icon: i, label: l)
'''), shouldFail: true);

  expect('un fond d’erreur écrit à la main', inspect('lib/screens/x.dart', '''
FilledButton(
  style: FilledButton.styleFrom(
    backgroundColor: Theme.of(context).colorScheme.error,
    foregroundColor: Theme.of(context).colorScheme.onError,
  ),
  child: t,
)
'''), shouldFail: true);

  expect('un libellé d’erreur sur un bouton bordé', inspect('lib/screens/x.dart', '''
OutlinedButton.icon(
  style: OutlinedButton.styleFrom(
    foregroundColor: Theme.of(context).colorScheme.error,
  ),
  icon: i, label: l,
)
'''), shouldFail: true);

  expect('la même chose sur un TextButton', inspect('lib/screens/x.dart', '''
TextButton(
  style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
  child: t,
)
'''), shouldFail: true);

  expect('un ElevatedButton derrière du vrai code sur la même ligne',
      inspect('lib/screens/x.dart', '''
final b = cond ? ElevatedButton(onPressed: f, child: t) : null;
'''), shouldFail: true);

  if (failed > 0) {
    stdout.writeln('\n$failed cas en échec — le contrôle ne vérifie pas ce '
        'qu\'il annonce.');
    exit(1);
  }
  stdout.writeln('\n✅ 12 cas — le contrôle sait dire oui ET non.');
}
