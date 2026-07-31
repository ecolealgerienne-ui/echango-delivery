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
// ── Comment il s'y prend, et les deux pièges qu'il a fallu fermer ─────────
//
// Il lit la constante Dart ET le décorateur du DTO, puis compare. Deux versions
// antérieures se sont trompées, chacune trouvée en éprouvant le script sur des
// mutations plutôt qu'en le relisant :
//
//  1. **Chercher `@MinLength` dans tout le fichier** attrapait le `@MinLength(20)`
//     d'un jeton d'invitation et concluait à un désaccord inexistant.
//  2. **Chercher le `@MinLength` le plus proche avant le champ** faisait hériter
//     un champ sans décorateur de celui du champ précédent : retirer une
//     contrainte serveur passait inaperçu.
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
// Usage :  dart tool/check_server_rules.dart   (depuis echango_delivery/)
// Sortie : 0 si tout concorde, 1 sinon, avec le détail.

import 'dart:io';

/// Une contrainte serveur reproduite côté app.
class _Mirror {
  const _Mirror({
    required this.constant,
    required this.serverFile,
    required this.classes,
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
    field: 'q',
    what: 'longueur minimale d’une recherche de transporteur',
  ),
  _Mirror(
    constant: 'addressSearchMinLength',
    serverFile: 'backend/bff/src/commercant/dto/geocode.dto.ts',
    classes: {'GeocodeQueryDto'},
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
    field: 'password',
    what: 'longueur minimale d’un mot de passe',
  ),
];

final _classPattern = RegExp(r'^export class (\w+)', multiLine: true);
// ⚠️ Deux espaces LITTÉRAUX, et non `\s{2}` : en Dart comme en Python, `\s`
// matche aussi le retour à la ligne, donc `^\s{2}` peut franchir une ligne vide
// et reconnaître un champ là où il n'y en a pas. Aucun écart sur les DTO
// actuels — mais une forme qui ne peut pas se tromper vaut mieux qu'une forme
// qui ne s'est pas encore trompée.
final _fieldPattern = RegExp(r'^ {2}(\w+)\??\s*:\s*\w', multiLine: true);
final _minLengthPattern = RegExp(r'@MinLength\((\d+)');

/// Les valeurs de `@MinLength` portées par [field] dans chacune des [classes].
///
/// Rend aussi le nombre de classes effectivement inspectées : moins que prévu
/// signifie qu'une classe a été renommée ou déplacée, et le contrôle ne vaut
/// alors plus rien.
({int classesSeen, Set<int?> values}) _constraintsOf(
  String source,
  Set<String> classes,
  String field,
) {
  final marks = _classPattern
      .allMatches(source)
      .map((m) => (name: m.group(1)!, start: m.start))
      .toList();

  var seen = 0;
  final values = <int?>{};

  for (var i = 0; i < marks.length; i++) {
    if (!classes.contains(marks[i].name)) continue;
    seen++;

    final end = i + 1 < marks.length ? marks[i + 1].start : source.length;
    final body = source.substring(marks[i].start, end);
    final decls = _fieldPattern.allMatches(body).toList();

    for (var j = 0; j < decls.length; j++) {
      if (decls[j].group(1) != field) continue;
      // Le bloc de décorateurs PROPRE à ce champ : du champ précédent à
      // celui-ci. Sans cette borne, un champ sans contrainte hériterait de
      // celle du voisin.
      final block = body.substring(j > 0 ? decls[j - 1].end : 0, decls[j].start);
      final found = _minLengthPattern.allMatches(block).toList();
      values.add(found.isEmpty ? null : int.parse(found.last.group(1)!));
    }
  }

  return (classesSeen: seen, values: values);
}

void main() {
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

    final result = _constraintsOf(
      serverFile.readAsStringSync(),
      mirror.classes,
      mirror.field,
    );

    if (result.classesSeen != mirror.classes.length) {
      fail('${mirror.constant} : ${result.classesSeen} classe(s) trouvée(s) sur '
          '${mirror.classes.length} attendue(s) dans ${mirror.serverFile}.\n'
          '   Attendues : ${mirror.classes.join(', ')}');
      continue;
    }

    if (result.values.contains(null)) {
      fail('${mirror.constant} : au moins une classe ne porte AUCUNE contrainte '
          'sur `${mirror.field}`. Le décorateur a-t-il été retiré ?\n'
          '   ${mirror.serverFile}');
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

  if (failed) {
    stdout.writeln('\nUne copie de règle serveur a divergé de son original.');
    exit(1);
  }

  stdout.writeln('✅ ${_mirrors.length} règles serveur reproduites, toutes '
      'd’accord avec leur original.');
}
