// Refuse une bordure de champ de saisie écrite dans un écran.
//
// ── Pourquoi un contrôle, et pas la convention écrite quelque part ─────────
//
// Parce qu'un commentaire ne peut pas échouer (règle 5). La convention est dans
// `lib/theme/app_theme.dart` → `_inputDecorationTheme` ; ce script est ce qui la
// tient. Pendant du `check_buttons.dart` du 31/07/2026, pour la même raison et
// après le même constat.
//
// Mesuré le 01/08/2026, avant : **21 des 25 `InputDecoration` du dépôt**
// repassaient un `border: OutlineInputBorder()` nu, qui écrase celui du thème.
// L'application avait donc deux apparences de champ — 21 à contour visible et
// coins de 4 px (le défaut Material), 4 remplis sans contour à coins de 8 px —
// et les quatre étaient tous dans le profil entreprise. Exactement le motif des
// boutons : un profil suit le thème, les deux autres se peignent eux-mêmes.
//
// ⚠️ Le lot n'a PAS consisté à retirer les 21 surcharges. Elles compensaient un
// défaut réel du thème, qui ne posait aucun `focusedBorder` : un champ n'avait
// alors de contour ni au repos ni au focus. Les retirer seules aurait uniformisé
// l'application vers le pire des deux états. Le thème a donc été corrigé
// d'abord, et les surcharges retirées ensuite.
//
// ── Ce qu'il refuse ────────────────────────────────────────────────────────
//
// Toute clé de bordure dans un écran : `border`, `enabledBorder`,
// `focusedBorder`, `errorBorder`, `focusedErrorBorder`, `disabledBorder`.
// Une seule suffit à faire diverger un champ des vingt-quatre autres, et la
// divergence ne se voit qu'en mettant deux écrans côte à côte — ce que
// personne ne fait.
//
// ── Ce qu'il NE refuse pas ─────────────────────────────────────────────────
//
// `isDense`, `contentPadding`, `prefixIcon`, `labelText`, `hintText`,
// `helperText`, `suffixIcon`. Ce sont le contenu et la densité du champ, pas
// son apparence de cadre : un champ de recherche dans une barre a le droit
// d'être plus compact qu'un champ de formulaire.
//
// ── Ce qu'il ne SAIT PAS voir, et il faut le dire ─────────────────────────
//
// La valeur doit être un `InputBorder` **littéral** — `OutlineInputBorder`,
// `UnderlineInputBorder`, `InputBorder.none`. Un `border: maBordure` passant par
// une variable échappe au repérage. C'est délibéré : accepter n'importe quelle
// valeur ferait signaler `BoxDecoration(border: Border.all(...))`, qui n'a rien
// à voir avec un champ de saisie et est parfaitement légitime. Aucune forme par
// variable n'existe aujourd'hui dans le dépôt (vérifié) ; le jour où il en
// apparaîtrait une, ce contrôle ne la verrait pas — mieux vaut l'écrire ici que
// de laisser croire à une couverture complète (règle 8).
//
// ⚠️ `isDense` est employé à 9 sites sur 25, sans règle apparente — les quatre
// champs du formulaire de commande le sont, ceux de la connexion ne le sont
// pas. C'est une divergence, mais la corriger déplacerait des pixels sur le
// plus gros formulaire de l'application : c'est une décision de design, à
// prendre à l'écran. Le script la **recense** sans échouer, comme
// `check_spacing.dart` recense les littéraux hors barème.
//
// Usage :  dart tool/check_inputs.dart [--self-test]
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

/// Les clés qui décident du **cadre** d'un champ.
const _borderKeys = [
  'border',
  'enabledBorder',
  'focusedBorder',
  'errorBorder',
  'focusedErrorBorder',
  'disabledBorder',
];

/// ⚠️ Le thème est **exclu** : c'est le seul endroit où la bordure d'un champ
/// se décide. L'y interdire reviendrait à interdire de définir la convention
/// qu'on fait respecter ailleurs — même exemption que `check_buttons.dart`.
bool _exempt(String path) =>
    path.replaceAll('\\', '/').contains('lib/theme/');

List<Finding> inspect(String path, String source) {
  final findings = <Finding>[];
  if (_exempt(path)) return findings;

  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    // Les commentaires ne sont pas du code. Sans ce filtre, la ligne qui
    // EXPLIQUE pourquoi `border:` est proscrit se ferait signaler — le contrôle
    // refuserait sa propre justification.
    final code = _stripComment(lines[i]);
    if (code.trim().isEmpty) continue;

    for (final key in _borderKeys) {
      // Ancré sur le début de la valeur : `border:` en clé nommée, suivi d'un
      // `InputBorder` quelconque. `side:` d'un `Card`, `borderRadius:` d'un
      // `BoxDecoration` ou `borderSide:` d'un `BorderSide` ne matchent pas.
      // ⚠️ `(^|[^A-Za-z0-9_])` et non une anticipation arrière `(?<!…)` : la
      // disponibilité des assertions arrière dans le `RegExp` de Dart n'est pas
      // vérifiable dans ce bac à sable, et une API ne s'emploie pas parce qu'on
      // s'en souvient. Un groupe explicite fait le même travail, partout.
      final re = RegExp('(^|[^A-Za-z0-9_])$key\\s*:\\s*(?:const\\s+)?'
          r'(?:Outline|Underline)?InputBorder(?:\.none)?\b');
      if (re.hasMatch(code)) {
        findings.add(Finding(path, i + 1,
            '$key dans un écran — la bordure des champs se décide dans '
            'theme/app_theme.dart (_inputDecorationTheme), sans quoi ce champ '
            'seul diverge des vingt-quatre autres'));
        break;
      }
    }
  }
  return findings;
}

/// Retire un commentaire de fin de ligne, **sans casser une chaîne**.
///
/// ⚠️ Une URL contient `//`. Couper au premier `//` venu transformerait
/// `'https://tile.openstreetmap.org/…'` en chaîne non terminée pour la suite de
/// l'analyse — et le contrôle se mettrait à voir des choses qui n'existent pas,
/// ou à ne plus rien voir. Repris **à l'identique** de `check_buttons.dart` : ce
/// n'est pas une copie qui doit rester accordée, c'est la même fonction, et si
/// un troisième contrôle en a besoin elle sortira dans un fichier commun.
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
  var dense = 0;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    scanned++;
    final source = entity.readAsStringSync();
    findings.addAll(inspect(entity.path, source));
    if (!_exempt(entity.path)) {
      dense += RegExp(r'(^|[^A-Za-z0-9_])isDense:\s*true')
          .allMatches(source)
          .length;
    }
  }

  // Recensé, jamais refusé — voir l'en-tête. Le compte est **imprimé** plutôt
  // que noté à la main : un chiffre recopié diverge de la mesure, et c'est
  // arrivé deux fois avec `check_spacing.dart`.
  stdout.writeln('ℹ️  $dense champ(s) en `isDense: true` — divergence connue, '
      'décision de design, non traitée ici.');

  if (findings.isEmpty) {
    stdout.writeln('✅ $scanned fichiers — aucune bordure de champ écrite hors '
        'du thème.');
    return;
  }

  for (final f in findings) {
    stdout.writeln('❌ $f');
  }
  stdout.writeln('\n${findings.length} à corriger. La convention est dans '
      'lib/theme/app_theme.dart (_inputDecorationTheme).');
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
  expect('un champ qui laisse le thème décider', inspect('lib/screens/x.dart', '''
TextField(
  controller: c,
  decoration: const InputDecoration(labelText: 'Email'),
)
'''), shouldFail: false);

  expect('isDense et contentPadding — densité, pas cadre',
      inspect('lib/screens/x.dart', '''
InputDecoration(
  labelText: 'Ville',
  isDense: true,
  contentPadding: EdgeInsets.all(AppSpacing.sm),
)
'''), shouldFail: false);

  expect('le thème, qui a le droit de décider',
      inspect('lib/theme/app_theme.dart', '''
InputDecorationTheme(border: OutlineInputBorder(borderSide: BorderSide.none))
'''), shouldFail: false);

  expect('le COMMENTAIRE qui explique la règle', inspect('lib/screens/x.dart', '''
// border: OutlineInputBorder() n'a plus sa place ici — voir app_theme.dart.
TextField(controller: c)
'''), shouldFail: false);

  expect('le `side` d\'une Card, qui n\'est pas un champ',
      inspect('lib/screens/x.dart', '''
Card(shape: RoundedRectangleBorder(side: BorderSide(color: c)))
'''), shouldFail: false);

  expect('un borderRadius de BoxDecoration', inspect('lib/screens/x.dart', '''
BoxDecoration(borderRadius: BorderRadius.circular(AppRadius.md))
'''), shouldFail: false);

  expect('une URL contenant // dans une chaîne', inspect('lib/widgets/m.dart', '''
const t = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
TextField(controller: c)
'''), shouldFail: false);

  expect('un identifiant dont une clé n\'est que le suffixe',
      inspect('lib/screens/x.dart', '''
InputDecoration(myFocusedBorder: OutlineInputBorder())
'''), shouldFail: false);

  stdout.writeln('── ce qui doit ÉCHOUER ──');
  expect('une bordure nue dans un écran', inspect('lib/screens/x.dart', '''
InputDecoration(labelText: 'Email', border: OutlineInputBorder())
'''), shouldFail: true);

  expect('la même, en const', inspect('lib/screens/x.dart', '''
InputDecoration(labelText: 'Email', border: const OutlineInputBorder())
'''), shouldFail: true);

  expect('une bordure paramétrée sur plusieurs lignes',
      inspect('lib/screens/x.dart', '''
InputDecoration(
  hintText: 'Précisions',
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.md),
  ),
)
'''), shouldFail: true);

  expect('un focusedBorder', inspect('lib/screens/x.dart', '''
InputDecoration(focusedBorder: OutlineInputBorder(borderSide: BorderSide(width: 2)))
'''), shouldFail: true);

  expect('un enabledBorder', inspect('lib/screens/x.dart', '''
InputDecoration(enabledBorder: UnderlineInputBorder())
'''), shouldFail: true);

  expect('un errorBorder', inspect('lib/screens/x.dart', '''
InputDecoration(errorBorder: OutlineInputBorder())
'''), shouldFail: true);

  expect('InputBorder.none, qui retire le cadre aussi sûrement',
      inspect('lib/screens/x.dart', '''
InputDecoration(border: InputBorder.none)
'''), shouldFail: true);

  expect('une bordure derrière du vrai code sur la même ligne',
      inspect('lib/screens/x.dart', '''
final d = dense ? InputDecoration(border: OutlineInputBorder()) : null;
'''), shouldFail: true);

  if (failed > 0) {
    stdout.writeln('\n$failed cas en échec — le contrôle ne vérifie pas ce '
        'qu\'il annonce.');
    exit(1);
  }
  stdout.writeln('\n✅ 16 cas — le contrôle sait dire oui ET non.');
}
