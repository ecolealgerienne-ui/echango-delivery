// Vérifie que les copies de règles serveur, dans `lib/config/app_rules.dart`,
// valent bien ce que le BFF applique.
//
// ── Pourquoi ce script, et non un commentaire ─────────────────────────────
//
// Règle 5 du projet : un invariant s'applique, il ne se documente pas. Trois
// écrans reproduisaient la longueur minimale d'une recherche de transporteur, et
// **l'un d'eux se trompait** — deux caractères au lieu de trois, donc une
// requête que le serveur refusait après coup, sur une saisie que l'application
// venait d'accepter. Écrire « doit valoir 3 comme le DTO » n'aurait rien
// empêché : un commentaire ne peut pas échouer.
//
// ── Comment il s'y prend, et les cinq pièges qu'il a fallu fermer ─────────
//
// Il lit la constante Dart ET le décorateur du DTO, puis compare. Chaque piège
// ci-dessous a été trouvé en éprouvant le script sur des mutations, jamais en le
// relisant — et les trois derniers l'ont été par une revue du 31/07/2026, sur
// une version que sa propre suite de fixtures déclarait bonne.
//
//  1. **Chercher `@MinLength` dans tout le fichier** attrapait le `@MinLength(20)`
//     d'un jeton d'invitation et concluait à un désaccord inexistant.
//  2. **Chercher le `@MinLength` le plus proche avant le champ** faisait hériter
//     un champ sans décorateur de celui du champ précédent : retirer une
//     contrainte serveur passait inaperçu.
//  3. **Ne compter que les classes trouvées** laissait passer le pire cas : si la
//     déclaration du champ n'était pas reconnue (`readonly password:`,
//     `password!:`), la classe ne versait aucune valeur, le compte de classes
//     restait bon, et le script **concluait à l'accord**. Un `@MinLength(12)`
//     serveur passait pour un 8. D'où `fieldsSeen` : on prouve que le champ a
//     été vu, pas seulement sa classe. Ce n'est pas théorique — `backend/bff/
//     tsconfig.json` porte `strictPropertyInitialization: false` ; le jour où
//     quelqu'un le durcit, **tous** les champs prennent un `!`.
//  4. **Un décorateur mis en commentaire** comptait comme appliqué : `//
//     @MinLength(8)` sur les trois DTO et le script disait oui. Les commentaires
//     sont désormais blanchis avant toute analyse.
//  5. **Une classe ajoutée** était invisible : un `OperatorRegisterDto` avec sa
//     propre longueur minimale n'était jamais inspecté, puisque la liste des
//     classes est fermée. `family` décrit la famille attendue dans le fichier et
//     le script refuse un membre non déclaré.
//
// D'où la portée retenue : **la classe visée, puis le bloc de décorateurs
// propre au champ**. Un champ sans contrainte donne `null`, qui est une
// divergence — pas une absence à ignorer.
//
// Le script échoue aussi si une classe attendue a disparu (renommée, déplacée)
// plutôt que de vérifier ce qui reste et de se taire. Un vérificateur qui ne
// trouve pas ce qu'il cherche et conclut à l'accord est pire que pas de
// vérificateur — leçon du 30/07/2026 sur les codes d'erreur.
//
// ⚠️ **Limite connue** : le blanchiment des commentaires ne distingue pas un
// `//` à l'intérieur d'une chaîne. Un message contenant une URL verrait la fin
// de sa ligne effacée. Sans effet ici — on ne lit que des décorateurs et des
// déclarations de champ, qui précèdent la chaîne —, mais c'est à savoir avant
// d'étendre le script à autre chose.
//
// ── Il sait dire non, et il le prouve ────────────────────────────────────
//
// Un premier passage au vert ne montre que la moitié de ce qui compte : qu'il
// sait dire oui. `--self-test` fait tourner l'extraction sur des DTO fictifs —
// dont toutes les formes de divergence qu'il doit refuser — et vérifie qu'il
// répond ce qu'il faut. Sans ça, sa validité repose sur une simulation faite
// ailleurs, c'est-à-dire sur rien de vérifiable là où il s'exécute.
//
// Usage :  dart tool/check_server_rules.dart              (contrôle réel)
//          dart tool/check_server_rules.dart --self-test  (le script s'éprouve)
// Sortie : 0 si tout concorde, 1 sinon, avec le détail.

import 'dart:io';

/// Une contrainte serveur reproduite côté app.
class _Mirror {
  const _Mirror({
    required this.constant,
    required this.serverFile,
    required this.classes,
    required this.family,
    required this.field,
    required this.what,
  });

  /// Nom de la constante dans `lib/config/app_rules.dart`.
  final String constant;

  /// Fichier du BFF qui porte l'original, relatif à la racine du dépôt.
  final String serverFile;

  /// Les classes qui doivent porter la contrainte. Toutes sont vérifiées :
  /// `register.dto.ts` en a trois, une par persona, et il suffirait qu'une seule
  /// dérive pour qu'un des trois formulaires mente.
  final Set<String> classes;

  /// La famille à laquelle ces classes appartiennent, en nom **complet**
  /// (le motif est ancré). Toute classe du fichier qui y appartient sans figurer
  /// dans [classes] fait échouer le contrôle : sinon un quatrième persona
  /// s'ajouterait avec sa propre longueur minimale, sans que rien ne l'inspecte.
  final String family;

  /// Le champ contraint, dans ces classes.
  final String field;

  /// Ce que la règle contraint, pour que le message soit lisible.
  final String what;
}

const _mirrors = <_Mirror>[
  _Mirror(
    constant: 'driverSearchMinLength',
    serverFile: 'backend/bff/src/commercant/dto/driver-search.dto.ts',
    classes: {'DriverSearchDto'},
    family: r'\w*SearchDto',
    field: 'q',
    what: 'longueur minimale d’une recherche de transporteur',
  ),
  _Mirror(
    constant: 'addressSearchMinLength',
    serverFile: 'backend/bff/src/commercant/dto/geocode.dto.ts',
    classes: {'GeocodeQueryDto'},
    // ⚠️ Ancré : `ReverseGeocodeQueryDto`, dans le même fichier, prend des
    // coordonnées et n'a légitimement aucun `q`. L'inclure ferait échouer le
    // contrôle sur un comportement correct.
    family: r'Geocode\w*Dto',
    field: 'q',
    what: 'longueur minimale d’une recherche d’adresse',
  ),
  _Mirror(
    constant: 'passwordMinLength',
    serverFile: 'backend/bff/src/auth/dto/register.dto.ts',
    // ⚠️ Les DTO de CONNEXION portent aussi un champ `password`, et n'ont
    // légitimement aucune longueur minimale — on saisit le mot de passe qu'on a.
    // Les inclure ferait échouer le contrôle sur un comportement correct.
    classes: {'MerchantRegisterDto', 'FleetRegisterDto', 'DriverRegisterDto'},
    family: r'\w+RegisterDto',
    field: 'password',
    what: 'longueur minimale d’un mot de passe',
  ),
];

/// Une constante exportée du BFF, reproduite côté app.
///
/// Deuxième forme de miroir, parce que toutes les règles serveur ne sont pas
/// des décorateurs : `MAX_PHOTO_BASE64_LENGTH` est un `export const` employé
/// par deux `@MaxLength`. Le vérificateur n'avait pas de mode pour ça, et c'est
/// le miroir dont la divergence coûte le plus cher — cinq mégaoctets envoyés
/// sur une connexion mobile avant un refus.
class _ConstMirror {
  const _ConstMirror({
    required this.constant,
    required this.serverFile,
    required this.serverConst,
    required this.what,
  });

  /// Nom de la constante dans `lib/config/app_rules.dart`.
  final String constant;

  /// Fichier du BFF qui porte l'original, relatif à la racine du dépôt.
  final String serverFile;

  /// Nom de la constante exportée par ce fichier.
  final String serverConst;

  /// Ce que la règle contraint, pour que le message soit lisible.
  final String what;
}

const _constMirrors = <_ConstMirror>[
  _ConstMirror(
    constant: 'maxPhotoBase64Length',
    serverFile: 'backend/bff/src/transporteur/dto/transporteur.dto.ts',
    serverConst: 'MAX_PHOTO_BASE64_LENGTH',
    what: 'taille maximale d’une photo',
  ),
];

final _classPattern = RegExp(r'^export class (\w+)', multiLine: true);
// ⚠️ Deux espaces LITTÉRAUX, et non `\s{2}` : en Dart comme en Python, `\s`
// matche aussi le retour à la ligne, donc `^\s{2}` peut franchir une ligne vide
// et reconnaître un champ là où il n'y en a pas. Même raison pour ` *: *` plutôt
// que `\s*:\s*`.
//
// `readonly` et le `!` d'affectation définie sont acceptés : les ignorer rendait
// la déclaration invisible, et une déclaration invisible produisait un ACCORD
// (piège n°3 de l'en-tête).
final _fieldPattern = RegExp(r'^ {2}(?:readonly +)?(\w+)[?!]? *: *\w',
    multiLine: true);
// `\s*` après la parenthèse : `@MinLength( 8 )` est du TypeScript valide, et un
// formateur peut l'écrire ainsi.
final _minLengthPattern = RegExp(r'@MinLength\(\s*(\d+)');
final _commentPattern = RegExp(r'//[^\n]*|/\*[\s\S]*?\*/');
final _notNewline = RegExp(r'[^\n]');

/// Blanchit les commentaires en conservant les retours à la ligne — donc toutes
/// les positions et toutes les colonnes, dont dépend `_fieldPattern`.
String _stripComments(String source) => source.replaceAllMapped(
      _commentPattern,
      (m) => m.group(0)!.replaceAll(_notNewline, ' '),
    );

/// Les valeurs de `@MinLength` portées par [field] dans chacune des [classes].
///
/// Rend aussi ce qui a été effectivement inspecté :
///  * [classesSeen] — moins que prévu signifie qu'une classe a été renommée ou
///    déplacée ;
///  * [fieldsSeen] — moins que prévu signifie que la DÉCLARATION du champ n'a
///    pas été reconnue, ce qui rend le résultat sans valeur même s'il paraît
///    cohérent.
({int classesSeen, int fieldsSeen, Set<int?> values}) _constraintsOf(
  String rawSource,
  Set<String> classes,
  String field,
) {
  final source = _stripComments(rawSource);
  final marks = _classPattern
      .allMatches(source)
      .map((m) => (name: m.group(1)!, start: m.start))
      .toList();

  var seen = 0;
  var fields = 0;
  final values = <int?>{};

  for (var i = 0; i < marks.length; i++) {
    if (!classes.contains(marks[i].name)) continue;
    seen++;

    final end = i + 1 < marks.length ? marks[i + 1].start : source.length;
    final body = source.substring(marks[i].start, end);
    final decls = _fieldPattern.allMatches(body).toList();

    var found = false;
    for (var j = 0; j < decls.length; j++) {
      if (decls[j].group(1) != field) continue;
      found = true;
      // Le bloc de décorateurs PROPRE à ce champ : du champ précédent à
      // celui-ci. Sans cette borne, un champ sans contrainte hériterait de
      // celle du voisin.
      final block = body.substring(j > 0 ? decls[j - 1].end : 0, decls[j].start);
      final hits = _minLengthPattern.allMatches(block).toList();
      values.add(hits.isEmpty ? null : int.parse(hits.last.group(1)!));
    }
    if (found) fields++;
  }

  return (classesSeen: seen, fieldsSeen: fields, values: values);
}

/// La valeur d'un `export const NOM = <entier>` du BFF, ou `null` s'il est
/// introuvable.
///
/// ⚠️ Les séparateurs de milliers sont retirés : le serveur écrit `7_000_000`,
/// l'app `7000000`, et comparer les textes ferait échouer sur une égalité vraie.
/// Un `export const` calculé (`5 * 1024 * 1024`) rend `null` plutôt qu'une
/// valeur fausse — le script refuse alors, ce qui est le bon sens de l'erreur.
int? _exportedConst(String rawSource, String name) {
  final m = RegExp('export const $name(?:\\s*:\\s*\\w+)?\\s*=\\s*([\\d_]+)\\s*;')
      .firstMatch(_stripComments(rawSource));
  if (m == null) return null;
  return int.tryParse(m.group(1)!.replaceAll('_', ''));
}

/// Les classes du fichier qui appartiennent à [family], en nom complet.
Set<String> _familyMembers(String rawSource, String family) {
  final anchored = RegExp('^$family\$');
  return _classPattern
      .allMatches(_stripComments(rawSource))
      .map((m) => m.group(1)!)
      .where(anchored.hasMatch)
      .toSet();
}

/// Un DTO fictif, et ce que l'extraction doit en tirer.
class _Fixture {
  const _Fixture(
    this.name,
    this.source,
    this.classes,
    this.expectedClasses,
    this.expectedFields,
    this.expectedValues,
  );

  final String name;
  final String source;
  final Set<String> classes;
  final int expectedClasses;
  final int expectedFields;
  final Set<int?> expectedValues;
}

const _fixtures = <_Fixture>[
  _Fixture('nominal', '''
export class ADto {
  @IsString()
  @MinLength(3)
  @MaxLength(60)
  q: string;
}
''', {'ADto'}, 1, 1, {3}),
  _Fixture('champ premier de sa classe', '''
export class ADto {
  @MinLength(3)
  q: string;

  @IsOptional()
  other?: string;
}
''', {'ADto'}, 1, 1, {3}),
  // Un `@MinLength(99)` dans un commentaire ne doit pas être pris pour une
  // contrainte du champ suivant.
  _Fixture('commentaire entre deux champs', '''
export class ADto {
  @MinLength(3)
  q: string;

  /**
   * Un commentaire citant @MinLength(99), qui ne compte pas.
   */
  @IsOptional()
  note?: string;
}
''', {'ADto'}, 1, 1, {3}),
  // Le symétrique du précédent : un commentaire APRÈS le vrai décorateur. La
  // version antérieure prenait `found.last` et retenait le 4.
  _Fixture('commentaire après le décorateur', '''
export class ADto {
  @MinLength(3)
  // ancienne valeur : @MinLength(4)
  q: string;
}
''', {'ADto'}, 1, 1, {3}),
  // Piège n°4 : le décorateur commenté ne doit PAS compter.
  _Fixture('décorateur mis en commentaire', '''
export class ADto {
  @IsString()
  // @MinLength(3)
  q: string;
}
''', {'ADto'}, 1, 1, {null}),
  // Piège n°3, dans ses deux formes. Le champ DOIT être reconnu, sinon le
  // script conclurait à l'accord sur une classe qu'il n'a pas lue.
  _Fixture('champ readonly', '''
export class ADto {
  @MinLength(3)
  readonly q: string;
}
''', {'ADto'}, 1, 1, {3}),
  _Fixture('champ en affectation définie', '''
export class ADto {
  @MinLength(3)
  q!: string;
}
''', {'ADto'}, 1, 1, {3}),
  // Champ renommé côté serveur : la classe est vue, le champ non. C'est ce cas
  // qui produisait un faux accord.
  _Fixture('champ absent de la classe', '''
export class ADto {
  @MinLength(3)
  query: string;
}
''', {'ADto'}, 1, 0, <int?>{}),
  _Fixture('champ absent d’UNE classe sur deux', '''
export class ADto {
  @MinLength(3)
  q: string;
}
export class BDto {
  @MinLength(3)
  query: string;
}
''', {'ADto', 'BDto'}, 2, 1, {3}),
  // Espaces dans le décorateur : forme valide, ne doit pas passer pour absente.
  _Fixture('décorateur espacé', '''
export class ADto {
  @MinLength( 3 )
  q: string;
}
''', {'ADto'}, 1, 1, {3}),
  // Les suivants sont ceux que le script DOIT refuser.
  _Fixture('décorateur retiré', '''
export class ADto {
  @IsString()
  q: string;
}
''', {'ADto'}, 1, 1, {null}),
  _Fixture('deux classes en désaccord', '''
export class ADto {
  @MinLength(3)
  q: string;
}
export class BDto {
  @MinLength(4)
  q: string;
}
''', {'ADto', 'BDto'}, 2, 2, {3, 4}),
  _Fixture('classe hors cible ignorée', '''
export class ADto {
  @MinLength(3)
  q: string;
}
export class LoginDto {
  q: string;
}
''', {'ADto'}, 1, 1, {3}),
  // Le piège qui a fait échouer une version antérieure : sans borne au champ
  // précédent, `q` aurait hérité du `@MinLength(3)` de `other`.
  _Fixture('champ sans contrainte, voisin qui en a une', '''
export class ADto {
  @MinLength(3)
  other: string;

  @IsString()
  q: string;
}
''', {'ADto'}, 1, 1, {null}),
];

/// La famille, éprouvée elle aussi : elle doit voir l'ajout qu'elle est censée
/// voir, et ne pas ramasser le voisin qui lui ressemble.
const _familyFixtures = <({String name, String source, String family, Set<String> expected})>[
  (
    name: 'famille — les trois personas',
    source: 'export class MerchantRegisterDto {}\n'
        'export class MerchantLoginDto {}\n'
        'export class FleetRegisterDto {}\n'
        'export class DriverRegisterDto {}\n'
        'export class CreateDriverInvitationDto {}\n',
    family: r'\w+RegisterDto',
    expected: {'MerchantRegisterDto', 'FleetRegisterDto', 'DriverRegisterDto'},
  ),
  (
    name: 'famille — un quatrième persona apparaît',
    source: 'export class MerchantRegisterDto {}\n'
        'export class OperatorRegisterDto {}\n',
    family: r'\w+RegisterDto',
    expected: {'MerchantRegisterDto', 'OperatorRegisterDto'},
  ),
  (
    name: 'famille — ancrée, le préfixe ne compte pas',
    source: 'export class GeocodeQueryDto {}\n'
        'export class ReverseGeocodeQueryDto {}\n',
    family: r'Geocode\w*Dto',
    expected: {'GeocodeQueryDto'},
  ),
];

/// Un `export const` fictif, et ce que l'extraction doit en tirer.
const _constFixtures =
    <({String name, String source, String constName, int? expected})>[
  (
    name: 'const — séparateurs de milliers',
    source: 'export const MAX_PHOTO_BASE64_LENGTH = 7_000_000;\n',
    constName: 'MAX_PHOTO_BASE64_LENGTH',
    expected: 7000000,
  ),
  (
    name: 'const — annoté en type',
    source: 'export const MAX_PHOTO_BASE64_LENGTH: number = 7000000;\n',
    constName: 'MAX_PHOTO_BASE64_LENGTH',
    expected: 7000000,
  ),
  (
    name: 'const — renommé, donc introuvable',
    source: 'export const MAX_PHOTO_BYTES = 7_000_000;\n',
    constName: 'MAX_PHOTO_BASE64_LENGTH',
    expected: null,
  ),
  (
    name: 'const — mis en commentaire',
    source: '// export const MAX_PHOTO_BASE64_LENGTH = 7_000_000;\n',
    constName: 'MAX_PHOTO_BASE64_LENGTH',
    expected: null,
  ),
  // Une expression n'est pas lue « à peu près » : le script refuse plutôt que
  // de retenir le premier nombre venu, qui vaudrait 5 au lieu de 5 242 880.
  (
    name: 'const — expression calculée, refusée',
    source: 'export const MAX_PHOTO_BASE64_LENGTH = 5 * 1024 * 1024;\n',
    constName: 'MAX_PHOTO_BASE64_LENGTH',
    expected: null,
  ),
];

/// Éprouve l'extraction sur les DTO fictifs. Rend `true` si tout concorde.
bool _selfTest() {
  var ok = true;
  for (final f in _fixtures) {
    final r = _constraintsOf(f.source, f.classes, 'q');
    final match = r.classesSeen == f.expectedClasses &&
        r.fieldsSeen == f.expectedFields &&
        r.values.length == f.expectedValues.length &&
        r.values.every(f.expectedValues.contains);
    stdout.writeln('${match ? '✅' : '❌'} ${f.name} — '
        '${r.classesSeen} classe(s), ${r.fieldsSeen} champ(s), '
        'valeurs ${r.values.toList()}'
        '${match ? '' : ' (attendu ${f.expectedClasses}/${f.expectedFields}, '
            '${f.expectedValues.toList()})'}');
    if (!match) ok = false;
  }
  for (final f in _familyFixtures) {
    final got = _familyMembers(f.source, f.family);
    final match = got.length == f.expected.length && got.every(f.expected.contains);
    stdout.writeln('${match ? '✅' : '❌'} ${f.name} — ${got.toList()}'
        '${match ? '' : ' (attendu ${f.expected.toList()})'}');
    if (!match) ok = false;
  }
  for (final f in _constFixtures) {
    final got = _exportedConst(f.source, f.constName);
    final match = got == f.expected;
    stdout.writeln('${match ? '✅' : '❌'} ${f.name} — $got'
        '${match ? '' : ' (attendu ${f.expected})'}');
    if (!match) ok = false;
  }
  return ok;
}

void main(List<String> args) {
  if (args.contains('--self-test')) {
    final total =
        _fixtures.length + _familyFixtures.length + _constFixtures.length;
    if (_selfTest()) {
      stdout.writeln('\n✅ $total cas — le script reconnaît les '
          'divergences qu\'il doit refuser.');
      return;
    }
    stdout.writeln('\n❌ Le vérificateur lui-même est faux : ne pas se fier à '
        'son verdict tant que ceci n\'est pas corrigé.');
    exit(1);
  }

  final rulesFile = File('lib/config/app_rules.dart');
  if (!rulesFile.existsSync()) {
    stderr.writeln('lib/config/app_rules.dart introuvable — lancez le script '
        'depuis echango_delivery/.');
    exit(2);
  }
  final rules = rulesFile.readAsStringSync();

  var failed = false;

  void fail(String message) {
    stdout.writeln('❌ $message');
    failed = true;
  }

  for (final mirror in _mirrors) {
    final declared =
        RegExp('static const int ${mirror.constant} = (\\d+)').firstMatch(rules);
    if (declared == null) {
      fail('${mirror.constant} : constante introuvable dans app_rules.dart '
          '(renommée ? changée de type ?)');
      continue;
    }

    final serverFile = File('../${mirror.serverFile}');
    if (!serverFile.existsSync()) {
      fail('${mirror.constant} : ${mirror.serverFile} introuvable '
          '(fichier déplacé ?)');
      continue;
    }
    final source = serverFile.readAsStringSync();

    final extra = _familyMembers(source, mirror.family).difference(mirror.classes);
    if (extra.isNotEmpty) {
      fail('${mirror.constant} : ${mirror.serverFile} contient ${extra.join(', ')}, '
          'de la même famille que les classes vérifiées mais absente de la liste.\n'
          '   Cette classe porte peut-être sa propre ${mirror.what}, que rien '
          'n’inspecte. L’ajouter à `classes`, ou dire pourquoi elle en est exclue.');
      continue;
    }

    final result = _constraintsOf(source, mirror.classes, mirror.field);

    if (result.classesSeen != mirror.classes.length) {
      fail('${mirror.constant} : ${result.classesSeen} classe(s) trouvée(s) sur '
          '${mirror.classes.length} attendue(s) dans ${mirror.serverFile}.\n'
          '   Attendues : ${mirror.classes.join(', ')}');
      continue;
    }

    if (result.fieldsSeen != mirror.classes.length) {
      fail('${mirror.constant} : le champ `${mirror.field}` n’a été reconnu que '
          'dans ${result.fieldsSeen} classe(s) sur ${mirror.classes.length}.\n'
          '   Renommé, ou déclaré sous une forme que le script ne sait pas lire ?\n'
          '   Tant que ce n’est pas levé, un accord affiché ne vaudrait rien : '
          'la classe non lue peut porter n’importe quelle valeur.');
      continue;
    }

    if (result.values.isEmpty) {
      fail('${mirror.constant} : aucune contrainte collectée alors que les '
          'classes et les champs ont été trouvés. Anomalie du script lui-même — '
          'lancer --self-test.');
      continue;
    }

    if (result.values.contains(null)) {
      fail('${mirror.constant} : au moins une classe ne porte AUCUNE contrainte '
          'sur `${mirror.field}`. Le décorateur a-t-il été retiré, ou mis en '
          'commentaire ?\n   ${mirror.serverFile}');
      continue;
    }

    if (result.values.length > 1) {
      final sorted = result.values.whereType<int>().toList()..sort();
      fail('${mirror.constant} : le serveur applique PLUSIEURS valeurs '
          '(${sorted.join(', ')}) pour ${mirror.what}. Une copie unique côté app '
          'est alors fausse pour au moins un cas.');
      continue;
    }

    final server = result.values.single!;
    final app = int.parse(declared.group(1)!);

    if (server != app) {
      fail('${mirror.constant} : l’app dit $app, le serveur exige $server '
          '(${mirror.what}).\n   ${mirror.serverFile}');
    }
  }

  for (final mirror in _constMirrors) {
    final declared =
        RegExp('static const int ${mirror.constant} = (\\d+)').firstMatch(rules);
    if (declared == null) {
      fail('${mirror.constant} : constante introuvable dans app_rules.dart '
          '(renommée ? changée de type ?)');
      continue;
    }

    final serverFile = File('../${mirror.serverFile}');
    if (!serverFile.existsSync()) {
      fail('${mirror.constant} : ${mirror.serverFile} introuvable '
          '(fichier déplacé ?)');
      continue;
    }

    final server = _exportedConst(serverFile.readAsStringSync(), mirror.serverConst);
    if (server == null) {
      fail('${mirror.constant} : `${mirror.serverConst}` introuvable ou non '
          'littéral dans ${mirror.serverFile}.\n'
          '   Renommé, mis en commentaire, ou devenu une expression calculée — '
          'dans les trois cas la copie côté app n’est plus vérifiable.');
      continue;
    }

    final app = int.parse(declared.group(1)!);
    if (server != app) {
      fail('${mirror.constant} : l’app dit $app, le serveur exige $server '
          '(${mirror.what}).\n   ${mirror.serverFile}');
    }
  }

  if (failed) {
    stdout.writeln('\nUne copie de règle serveur a divergé de son original.');
    exit(1);
  }

  stdout.writeln('✅ ${_mirrors.length + _constMirrors.length} règles serveur '
      'reproduites, toutes d’accord avec leur original.');
}
