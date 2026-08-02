/// Le parcours commerçant, joué **dans l'application** sur un vrai appareil.
///
/// ── Ce que ce fichier ajoute aux sept scénarios existants ─────────────────
///
/// `scripts/run-all-scenarios.sh` exerce le BFF de bout en bout, en `curl`.
/// Il ne touche jamais l'application : un écran peut être absent, muet ou
/// planter à l'ouverture sans qu'un seul scénario passe au rouge. C'est
/// exactement ce qui s'est produit — deux formulaires d'inscription livrés,
/// compilés, analysés, et **jamais ouverts**.
///
/// Ici l'application démarre pour de vrai (`app.main()`), sur l'émulateur, avec
/// le BFF derrière. Ce qui est vérifié n'est donc pas « le serveur répond »
/// mais « quelqu'un peut le faire ».
///
/// ── Comment le lancer ─────────────────────────────────────────────────────
///
///   # dans WSL — pose le décor et imprime la commande complète
///   ./scripts/provision-app-parcours.sh
///
///   # côté Windows — la commande imprimée ci-dessus
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/parcours_commercant_test.dart -d <émulateur> \
///     --dart-define=TEST_MERCHANT_EMAIL=… --dart-define=TEST_MERCHANT_PASSWORD=…
///
/// ⚠️ **Une exécution complète consomme deux inscriptions sur les dix par
/// heure** : une pour le décor, une pour le test d'inscription. Enchaîner avec
/// `run-all-scenarios.sh`, qui en consomme huit, ne passera pas.
///
/// ── Pourquoi rien n'est cherché par son libellé ───────────────────────────
///
/// Les widgets sont désignés par leur **icône**, leur **type**, ou une **donnée
/// que le décor a posée** — jamais par un texte traduit. Une recherche par
/// libellé lierait le test à la langue de l'émulateur : il passerait au vert
/// chez moi et échouerait chez quelqu'un dont le téléphone est en arabe, pour
/// une raison qui n'aurait rien à voir avec le défaut. Les icônes et les noms
/// d'adresse ne bougent pas avec la locale.
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echango_delivery/main.dart' as app;
import 'package:echango_delivery/screens/auth/login_screen.dart';
import 'package:echango_delivery/screens/auth/register_screen.dart';
import 'package:echango_delivery/state/auth_state.dart' show UserRole;
import 'package:echango_delivery/widgets/notice.dart';

/// Identifiants d'un commerçant **déjà activé**, posés par
/// `scripts/provision-app-parcours.sh`.
///
/// Aucune valeur par défaut, et c'est délibéré : un test qui se rabattrait sur
/// un compte imaginaire échouerait à la connexion en accusant l'écran de
/// connexion. Absents, on le dit tout de suite et on nomme le script à lancer.
const String merchantEmail = String.fromEnvironment('TEST_MERCHANT_EMAIL');
const String merchantPassword = String.fromEnvironment('TEST_MERCHANT_PASSWORD');
const String pickupName =
    String.fromEnvironment('TEST_PICKUP_NAME', defaultValue: 'Dépôt Alger-Centre');
const String dropoffName =
    String.fromEnvironment('TEST_DROPOFF_NAME', defaultValue: 'Client Hydra');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    if (merchantEmail.isEmpty || merchantPassword.isEmpty) {
      fail(
        'TEST_MERCHANT_EMAIL / TEST_MERCHANT_PASSWORD absents.\n'
        'Poser le décor d’abord :  ./scripts/provision-app-parcours.sh\n'
        'puis relancer avec les --dart-define qu’il imprime.',
      );
    }
  });

  // ⚠️ **Repartir d'un appareil sans session — sans quoi le test lit l'état
  // laissé par quelqu'un d'autre (constaté le 02/08/2026).**
  //
  // `flutter drive` installe **par-dessus** l'application déjà présente : les
  // préférences et le stockage sécurisé survivent. L'appareil portait donc la
  // session d'un lancement manuel, l'application l'a restaurée, et elle est
  // allée droit sur un écran d'accueil sans jamais montrer la connexion. Le
  // test a échoué en accusant l'écran de connexion de n'avoir aucun champ —
  // il n'était simplement pas affiché.
  //
  // Le défaut ne se voit pas en relisant : il dépend de ce que la machine
  // portait avant. C'est aussi pour ça que le nettoyage est en `setUp` et non
  // en `setUpAll` — le premier test se connecte, donc il **laisse** une session
  // au suivant.
  setUp(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await const FlutterSecureStorage().deleteAll();
  });

  testWidgets('connexion → création d’une course → publication', (tester) async {
    app.main();

    // ── Connexion ──────────────────────────────────────────────────────────
    //
    // Le démarrage traverse un splash qui interroge le stockage sécurisé et le
    // BFF : on attend l'écran, on ne le suppose pas arrivé.
    await pumpUntil(tester, find.byType(FilledButton),
        reason: 'écran de connexion');

    // ⚠️ **Les champs sont cherchés SOUS l'écran visé, jamais dans tout l'arbre.**
    //
    // Pendant une transition de route, l'écran qu'on quitte est encore monté et
    // ses champs comptent dans `find.byType(TextField)`. C'est ce qui a fait
    // échouer le second test : trois saisies destinées à l'inscription sont
    // parties dans les deux champs de la connexion, et le formulaire a refusé
    // « Commerce, email et mot de passe sont requis » sur un écran que le test
    // croyait avoir rempli. Un index global n'a de sens que si l'on sait ce que
    // l'arbre contient — ce que personne ne sait pendant une animation.
    final fields = find.descendant(
        of: find.byType(LoginScreen), matching: find.byType(TextField));
    expect(fields, findsNWidgets(2),
        reason: 'l’écran de connexion porte exactement deux champs');

    await tester.enterText(fields.at(0), merchantEmail);
    await tester.enterText(fields.at(1), merchantPassword);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    await tester.tap(find.byType(FilledButton));

    // ── La liste des courses ───────────────────────────────────────────────
    //
    // Le bouton flottant est le repère : il n'existe que sur l'écran du
    // commerçant connecté. L'attendre vaut assertion d'arrivée.
    await pumpUntil(tester, find.byType(FloatingActionButton),
        reason: 'liste des courses du commerçant',
        onTimeout: 'la connexion n’a pas abouti — compte non activé, '
            'ou BFF injoignable depuis l’appareil (voir ApiConfig.bffBaseUrl)');

    await tester.tap(find.byType(FloatingActionButton));
    await pumpUntil(tester, find.byIcon(Icons.save_outlined),
        reason: 'formulaire de course');

    // ── Les deux points, pris au carnet ────────────────────────────────────
    //
    // Deux boutons « carnet » à l'écran, dans l'ordre du formulaire :
    // enlèvement puis livraison. Chacun remplit d'un coup le nom, le contact,
    // le téléphone et la position — les quatre champs obligatoires.
    await pickFromBook(tester, row: 0, addressName: pickupName);
    await pickFromBook(tester, row: 1, addressName: dropoffName);

    // ── Enregistrement ─────────────────────────────────────────────────────
    //
    // La course naît en **brouillon** (décision produit du 30/07/2026) :
    // personne n'est sollicité tant qu'elle n'est pas publiée.
    final complaint =
        await tapAndCatchComplaint(tester, find.byIcon(Icons.save_outlined));
    await pumpUntil(tester, find.byIcon(Icons.publish_outlined),
        reason: 'fiche de la course, en brouillon',
        onTimeout: complaint == null
            ? 'aucun refus affiché — texte à l’écran : ${visibleTexts()}'
            : 'refus affiché : « $complaint »');

    // ── Publication ────────────────────────────────────────────────────────
    //
    // C'est ici que la course devient réclamable. La disparition du bouton est
    // l'assertion : tant qu'il est là, rien n'a été publié.
    final said =
        await tapAndCatchComplaint(tester, find.byIcon(Icons.publish_outlined));
    await pumpUntilGone(tester, find.byIcon(Icons.publish_outlined),
        reason: 'disparition du bouton « Publier »',
        onTimeout: 'l’application a dit : « ${said ?? 'rien'} »'
            '\n  Fiche : ${visibleTexts()}');
  });

  testWidgets('inscription commerçant — la demande est enregistrée, pas ouverte',
      (tester) async {
    app.main();
    await pumpUntil(tester, find.byType(TextButton), reason: 'écran de connexion');

    // ⚠️ **Le lien d'inscription ne se désigne ni par son rang, ni par son
    // type** — deux tentatives, deux échecs, tous deux instructifs.
    //
    // Le sélecteur de langue est lui aussi un bouton texte et vient **avant** :
    // taper « le premier » bascule l'application en arabe au lieu d'ouvrir
    // l'inscription, sans rien lever — le test continue sur un écran traduit et
    // échoue trois étapes plus loin, sur autre chose.
    //
    // Compter les `TextButton` ne sauve pas non plus : mesuré sur l'appareil,
    // l'écran n'en expose **qu'un seul**, les deux ne se distinguant donc pas
    // par le type.
    //
    // Ce qui les sépare vraiment : le lien porte un `Text` nu, le sélecteur une
    // icône et un libellé. Le critère décrit ce que le widget **est**, et non où
    // il se trouve — il survit donc à un déplacement dans l'écran.
    final registerLink = find.byWidgetPredicate(
      (w) => w is TextButton && w.child is Text,
      description: 'bouton texte simple (le lien d’inscription)',
    );
    expect(registerLink, findsOneWidget,
        reason: 'un seul lien texte attendu sur l’écran de connexion');

    await tester.tap(registerLink);
    await pumpUntil(tester, find.byType(SegmentedButton<UserRole>),
        reason: 'formulaire d’inscription',
        onTimeout: 'le sélecteur de profil est absent — c’est lui qui donne '
            'accès aux parcours entreprise et transporteur');

    // Profil commerçant : c'est la sélection par défaut, on ne la retouche pas.
    // Champs restreints à l'écran d'inscription — motif au premier test.
    final fields = find.descendant(
        of: find.byType(RegisterScreen), matching: find.byType(TextField));
    expect(fields, findsNWidgets(4),
        reason: 'commerçant : commerce, email, mot de passe, téléphone');

    final stamp = DateTime.now().millisecondsSinceEpoch;
    await tester.enterText(fields.at(0), 'Boulangerie App $stamp');
    await tester.enterText(fields.at(1), 'app-inscription-$stamp@echango.local');
    await tester.enterText(fields.at(2), 'motdepasse123');
    await tester.pump();

    await tapVisible(
        tester,
        find.descendant(
            of: find.byType(RegisterScreen), matching: find.byType(FilledButton)));

    // ⚠️ **Le résultat attendu est l'absence d'accès**, pas une session.
    //
    // Une inscription commerçant enregistre une demande : ni jeton, ni
    // navigation, un bandeau qui explique l'attente. Un test qui attendrait
    // l'écran d'accueil ici serait vert le jour où la validation disparaîtrait
    // — c'est-à-dire le jour où le garde du Lot 4 serait cassé.
    await pumpUntil(tester, find.byType(AppNotice),
        reason: 'bandeau « demande enregistrée »',
        onTimeout: 'texte à l’écran : ${visibleTexts()}');
    expect(find.byType(FloatingActionButton), findsNothing,
        reason: 'aucun écran commerçant ne doit s’ouvrir sans validation');
  });
}

// ── Outillage ────────────────────────────────────────────────────────────────

/// Pompe jusqu'à ce que `finder` matche, ou échoue en disant quoi regarder.
///
/// ⚠️ **`pumpAndSettle` ne convient pas ici, et c'est le piège n°1 du pilotage
/// d'application.** Il pompe jusqu'à ce qu'il n'y ait plus d'animation en
/// cours — or un `CircularProgressIndicator` tourne indéfiniment. Tout écran
/// qui charge quelque chose le fait donc expirer au bout de dix minutes, sur un
/// message qui parle d'animations et non du chargement qui n'aboutit pas.
///
/// On attend donc une **condition**, pas un repos. Et le message d'échec dit ce
/// qu'on attendait : « timeout » tout court oblige à rejouer le parcours à la
/// main pour savoir où il s'est arrêté.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  String? onTimeout,
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Jamais atteint : $reason'
      '${onTimeout == null ? '' : '\n  → $onTimeout'}'
      '\n  Écran au moment de l’abandon : ${whatIsOnScreen()}');
}

/// Nomme l'écran visible, pour qu'un échec d'attente n'oblige pas à enquêter.
///
/// ⚠️ Écrit après coup, et c'est l'enseignement du 02/08/2026 : « jamais
/// atteint : écran de connexion » a coûté une demi-heure d'hypothèses alors que
/// la réponse — « l'application est sur un écran d'accueil, une session traînait
/// » — tenait en un repère. Une absence qui ne dit pas ce qu'il y avait à la
/// place laisse chercher au mauvais endroit.
String whatIsOnScreen() {
  final marks = <String, Finder>{
    'splash (chargement)': find.byType(CircularProgressIndicator),
    'connexion': find.byType(FilledButton),
    'inscription': find.byType(SegmentedButton<UserRole>),
    'accueil commerçant': find.byType(FloatingActionButton),
    'formulaire de course': find.byIcon(Icons.save_outlined),
    'fiche de course': find.byIcon(Icons.publish_outlined),
    // ⚠️ PAS de repère « carnet ouvert » sur `Icons.bookmark_outline` : cette
    // icône est celle des **boutons** du formulaire, présents en permanence. Le
    // repère annonçait donc un carnet ouvert sur un formulaire au repos —
    // un diagnostic faux est pire qu'un diagnostic absent.
    'bandeau': find.byType(AppNotice),
  };
  final seen = marks.entries
      .where((e) => e.value.evaluate().isNotEmpty)
      .map((e) => e.key)
      .toList();
  final fields = find.byType(TextField).evaluate().length;
  return seen.isEmpty
      ? 'aucun repère connu ($fields champs de saisie)'
      : '${seen.join(' + ')} ($fields champs de saisie)';
}

/// Amène le widget dans la fenêtre **avant** de taper dessus.
///
/// ⚠️ `tester.tap` frappe les coordonnées du centre du widget, même quand ce
/// centre est **hors de l'écran** : le formulaire de course défile, son bouton
/// d'enregistrement vit tout en bas, et le tap partait donc sur ce qui se
/// trouvait à ces coordonnées-là. Aucune exception — le test attendait ensuite
/// une navigation qui n'avait aucune raison d'arriver, et accusait la création
/// de la course.
///
/// Le finder doit exister dans l'arbre : c'est le cas d'un `SingleChildScrollView`,
/// qui construit tous ses enfants. `ensureVisible` fait ensuite défiler jusqu'à
/// lui.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 300));
}

/// Tape, puis guette un refus pendant les secondes où il est affiché.
///
/// ⚠️ **Un `SnackBar` s'efface au bout de quelques secondes** — une attente de
/// quarante secondes ne le voit donc jamais. Le premier échec de l'étape
/// d'enregistrement s'est ainsi présenté comme « rien ne s'est passé » alors que
/// l'application avait peut-être dit exactement pourquoi. On regarde tout de
/// suite, on rapporte plus tard.
Future<String?> tapAndCatchComplaint(WidgetTester tester, Finder finder) async {
  // ⚠️ **Attendre que le bandeau précédent se soit effacé, sinon on lit
  // l'étape d'avant.** Constaté : la publication a rapporté « Brouillon
  // enregistré… », c'est-à-dire le message de l'enregistrement, encore affiché
  // au moment du tap. Un diagnostic qui cite le mauvais message est pire que
  // pas de diagnostic — il fait chercher un défaut là où il n'y en a pas.
  final clear = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(clear) &&
      find.byType(SnackBar).evaluate().isNotEmpty) {
    await tester.pump(const Duration(milliseconds: 200));
  }

  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);

  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    final bar = find.byType(SnackBar);
    if (bar.evaluate().isEmpty) continue;
    final texts = find
        .descendant(of: bar, matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .toList();
    if (texts.isNotEmpty) return texts.join(' — ');
  }
  return null;
}

/// Ouvre le carnet d'adresses de la ligne `row` et y choisit `addressName`.
///
/// `row` vaut 0 pour l'enlèvement, 1 pour la livraison : les deux boutons sont
/// identiques et ne se distinguent que par leur ordre à l'écran, qui est celui
/// du formulaire.
Future<void> pickFromBook(
  WidgetTester tester, {
  required int row,
  required String addressName,
}) async {
  final books = find.byIcon(Icons.bookmark_outline);
  await pumpUntil(tester, books, reason: 'boutons « carnet »');
  expect(books, findsNWidgets(2),
      reason: 'le carnet doit être proposé pour l’enlèvement ET la livraison — '
          'un seul bouton signifie un carnet vide côté décor');

  await tester.tap(books.at(row));

  // ⚠️ **Comparaison insensible à la casse** : Fleetbase rend les noms de lieux
  // en MAJUSCULES. `find.text('Dépôt Alger-Centre')` ne trouvait donc rien alors
  // que la feuille affichait bien l'adresse — le carnet était ouvert, l'entrée
  // visible, et le test annonçait un décor manquant.
  final wanted = addressName.toLowerCase();
  final entry = find.byWidgetPredicate(
    (w) => w is Text && (w.data?.toLowerCase().contains(wanted) ?? false),
    description: 'entrée « $addressName » (casse ignorée)',
  );

  await pumpUntil(tester, entry,
      reason: 'entrée « $addressName » dans le carnet',
      onTimeout: 'entrées réellement affichées : ${visibleTexts()}');
  await tester.tap(entry.last);
  await tester.pump(const Duration(milliseconds: 400));
}

/// Les textes visibles, pour qu'un « introuvable » dise ce qui était là.
///
/// Sans ça, l'échec précédent affirmait que le décor n'avait pas posé
/// l'adresse — alors qu'elle était à l'écran, en majuscules.
String visibleTexts() {
  final seen = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .take(25)
      .toList();
  return seen.isEmpty ? 'aucun' : seen.join(' | ');
}

/// Le pendant de [pumpUntil] pour une **disparition**.
///
/// Écrit comme une fonction et non comme un finder inversé : un `Finder` qui
/// rend un élément fabriqué pour signifier « rien » est un mensonge que la
/// couche d'assertion finit par déballer. Ici la condition est lue directement.
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  String? onTimeout,
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (finder.evaluate().isEmpty) return;
  }
  fail('Jamais atteint : $reason'
      '${onTimeout == null ? '' : '\n  → $onTimeout'}'
      '\n  Écran au moment de l’abandon : ${whatIsOnScreen()}');
}
