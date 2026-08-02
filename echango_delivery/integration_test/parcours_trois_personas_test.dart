/// Les trois personas, joués **dans l'application** sur un vrai appareil.
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
/// le BFF derrière, et **les trois profils s'y connectent tour à tour**. Ce qui
/// est vérifié n'est donc pas « le serveur répond » mais « quelqu'un peut le
/// faire ».
///
/// ── Comment le lancer ─────────────────────────────────────────────────────
///
///   # dans WSL — pose le décor pour les trois personas, imprime la commande
///   ./scripts/provision-app-parcours.sh [conducteur]
///
///   # côté Windows — la commande imprimée ci-dessus
///
/// ⚠️ **Aucun parcours ne dépend de l'état laissé par le précédent.** Les
/// courses libres que prennent le transporteur et l'entreprise sont posées par
/// le décor, pas par le parcours commerçant : deux tests qui se passent un état
/// échouent ensemble, et le second accuse le premier.
///
/// ⚠️ **Une exécution complète consomme jusqu'à deux inscriptions sur les dix
/// par heure** — celle du test d'inscription, et celles du décor s'il crée des
/// comptes neufs. Les emails du décor sont stables, donc un rejeu n'en consomme
/// qu'une.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:echango_delivery/i18n/fleet_strings.dart';
import 'package:echango_delivery/main.dart' as app;
import 'package:echango_delivery/screens/auth/register_screen.dart';
import 'package:echango_delivery/state/auth_state.dart' show UserRole;
import 'package:echango_delivery/widgets/error_banner.dart';
import 'package:echango_delivery/widgets/notice.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(resetDevice);

  // ── Commerçant ───────────────────────────────────────────────────────────

  testWidgets('commerçant — inscription : la demande est enregistrée, pas ouverte',
      (tester) async {
    app.main();
    await pumpUntil(tester, find.byType(TextButton), reason: 'écran de connexion');

    // ⚠️ **Le lien d'inscription ne se désigne ni par son rang, ni par son
    // type** — deux tentatives, deux échecs, tous deux instructifs.
    //
    // Le sélecteur de langue est lui aussi un bouton texte et vient **avant** :
    // taper « le premier » bascule l'application en arabe au lieu d'ouvrir
    // l'inscription, sans rien lever — le test continue sur un écran traduit et
    // échoue trois étapes plus loin, sur autre chose. Compter les `TextButton`
    // ne sauve pas non plus : mesuré sur l'appareil, l'écran n'en expose qu'un.
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

    // Profil commerçant : sélection par défaut, on ne la retouche pas.
    // Champs restreints à l'écran visé, jamais un index global.
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
    // ⚠️ **On attend l'un OU l'autre des deux bandeaux, puis on tranche.**
    //
    // Attendre le seul bandeau de succès faisait expirer le test sur « bandeau
    // jamais atteint » alors que l'application affichait, juste à côté, un
    // refus parfaitement explicite : `ThrottlerException` — le plafond de dix
    // inscriptions par heure, épuisé par les exécutions précédentes. Le
    // diagnostic accusait donc l'écran d'être muet quand il parlait.
    //
    // Lire les deux permet de dire **ce qui a été refusé**, et de distinguer une
    // limite d'environnement d'un défaut du produit.
    await pumpUntil(
      tester,
      find.byWidgetPredicate((w) => w is AppNotice || w is AppErrorBanner,
          description: 'un bandeau, quel qu’il soit'),
      reason: 'réponse à l’inscription',
      onTimeout: 'texte à l’écran : ${visibleTexts()}',
    );
    expect(find.byType(AppErrorBanner), findsNothing,
        reason: 'l’inscription a été refusée — ${visibleTexts()}\n'
            '  Si le refus parle de « Too Many Requests », c’est le plafond de '
            'dix inscriptions par heure : attendre la fenêtre, le code n’est pas '
            'en cause.');
    expect(find.byType(AppNotice), findsOneWidget,
        reason: 'la demande doit être confirmée par un bandeau');
    expect(find.byType(FloatingActionButton), findsNothing,
        reason: 'aucun écran commerçant ne doit s’ouvrir sans validation');
  });

  testWidgets('commerçant — connexion, création d’une course, publication',
      (tester) async {
    requireCredentials({'TEST_MERCHANT_EMAIL': merchantEmail});
    app.main();
    await loginAs(tester, email: merchantEmail, home: Home.merchant);

    await tester.tap(find.byType(FloatingActionButton));
    await pumpUntil(tester, find.byIcon(Icons.save_outlined),
        reason: 'formulaire de course');

    // Deux boutons « carnet » à l'écran, dans l'ordre du formulaire :
    // enlèvement puis livraison. Chacun remplit d'un coup le nom, le contact,
    // le téléphone et la position — les quatre champs obligatoires.
    await pickFromBook(tester, row: 0, addressName: pickupName);
    await pickFromBook(tester, row: 1, addressName: dropoffName);

    // La course naît en **brouillon** (décision produit du 30/07/2026) :
    // personne n'est sollicité tant qu'elle n'est pas publiée.
    final saved = await tapAndCatchOutcome(tester, find.byIcon(Icons.save_outlined));
    await pumpUntil(tester, find.byIcon(Icons.publish_outlined),
        reason: 'fiche de la course, en brouillon',
        onTimeout: 'l’application a dit : « ${saved ?? 'rien'} »');

    // C'est ici que la course devient réclamable. La disparition du bouton est
    // l'assertion : tant qu'il est là, la fiche n'a pas vu la publication.
    final published =
        await tapAndCatchOutcome(tester, find.byIcon(Icons.publish_outlined));
    await pumpUntilGone(tester, find.byIcon(Icons.publish_outlined),
        reason: 'disparition du bouton « Publier »',
        onTimeout: 'l’application a dit : « ${published ?? 'rien'} »'
            '\n  Fiche : ${visibleTexts()}');
  });

  // ── Transporteur ─────────────────────────────────────────────────────────

  testWidgets('transporteur — connexion, opportunités, prise d’une course',
      (tester) async {
    requireCredentials({'TEST_DRIVER_EMAIL': driverEmail});
    app.main();
    await loginAs(tester, email: driverEmail, home: Home.driver);

    // Onglet 0 : les opportunités. C'est le premier, et c'est délibéré côté
    // produit — ce qu'un transporteur ouvre l'application pour voir.
    await openTab(tester, 0);

    final rows = find.byType(ListTile);
    await pumpUntil(tester, rows,
        reason: 'au moins une course libre',
        onTimeout: 'aucune opportunité — le décor n’a pas publié de course, ou '
            'le véhicule du conducteur ne correspond à aucune. Relancer '
            'scripts/provision-app-parcours.sh');

    await tapVisible(tester, rows.first);

    // ⚠️ **Sur une opportunité non réclamée, la fiche n'expose qu'UN
    // `FilledButton` : « Accepter ».** Le refus est un `OutlinedButton`, et le
    // signalement d'échec n'apparaît qu'une fois la course prise
    // (`!order.isFinished && !claimable`). Le compte vaut donc assertion : s'il
    // change, le test le dit au lieu de taper sur un bouton au hasard.
    final accept = find.byType(FilledButton);
    await pumpUntil(tester, accept,
        reason: 'fiche de la course, côté transporteur',
        onTimeout: 'texte à l’écran : ${visibleTexts()}');
    expect(accept, findsOneWidget,
        reason: 'une opportunité réclamable n’offre que « Accepter » en bouton plein');

    final outcome = await tapAndCatchOutcome(tester, accept);

    // ⚠️ **L'assertion porte sur le bouton de REFUS, pas sur les boutons
    // pleins — et la première version ne pouvait pas passer.**
    //
    // Elle attendait la disparition de **tous** les `FilledButton`. Or une
    // course acceptée en affiche d'autres aussitôt : les transitions suivantes
    // servies par la configuration Fleetbase, et le signalement d'échec, qui
    // n'apparaît justement qu'**une fois la course prise**. Le test ne pouvait
    // donc réussir que sur une course sans transition suivante — ce qui est
    // arrivé une fois, et m'a fait croire l'assertion bonne.
    //
    // Le bouton de refus, lui, n'existe que tant que la course est réclamable
    // (`claimable`) ou rendable (`returnable`, qui exige `isPending`). Une
    // course démarrée par nous n'est ni l'un ni l'autre : sa disparition dit
    // exactement « elle est à moi et elle a commencé ».
    //
    // ⚠️ Ce n'est **pas** le message qui sert de preuve : `showAppOutcome`
    // affiche un bandeau dans les deux cas, succès comme refus — c'est le
    // défaut corrigé le 31/07, où dix refus s'affichaient exactement comme des
    // confirmations.
    await pumpUntilGone(tester, find.byIcon(Icons.do_not_disturb_on_outlined),
        reason: 'la course cesse d’être réclamable — elle est prise',
        onTimeout: 'l’application a dit : « ${outcome ?? 'rien'} »'
            '\n  Fiche : ${visibleTexts()}');
  });

  // ── Entreprise de transport (le facilitateur) ────────────────────────────

  testWidgets('entreprise — connexion, opportunités, prise d’une course',
      (tester) async {
    requireCredentials({'TEST_FLEET_EMAIL': fleetEmail});
    app.main();
    await loginAs(tester, email: fleetEmail, home: Home.fleet);

    // Onglet 1 : les opportunités (0 = ses courses, 2 = ses conducteurs,
    // 3 = les adhésions).
    await openTab(tester, 1);

    // Chaque ligne d'opportunité porte son bouton de prise en `trailing` : on
    // agit donc sans ouvrir la fiche, comme le ferait un dispatcheur.
    final claim = find.descendant(
        of: find.byType(ListTile), matching: find.byType(FilledButton));
    await pumpUntil(tester, claim,
        reason: 'au moins une opportunité pour l’entreprise',
        onTimeout: 'aucune opportunité — le décor n’a pas publié de course '
            'libre, ou le transporteur les a toutes prises. Relancer '
            'scripts/provision-app-parcours.sh');

    final outcome = await tapAndCatchOutcome(tester, claim.first);

    // ⚠️ **Ne PAS compter les boutons pour mesurer la prise.** La première
    // version attendait « une opportunité de moins » et n'a jamais vu la
    // différence : l'onglet « Courses » porte le même genre de bouton dans ses
    // lignes, et une course prise **quitte les opportunités pour entrer dans
    // les courses**. Le total ne bouge donc pas d'un pouce. Les journaux du BFF
    // montraient pourtant un `POST …/prendre` réussi en 267 ms : le geste avait
    // marché, c'est la mesure qui était fausse.
    //
    // On lit donc ce que l'application **dit**, en résolvant la même clé qu'elle
    // dans la même table — le test importe ce que le code exécute, il ne
    // recopie pas le texte. Le message d'échec est distinct du message de
    // succès, donc la confusion « refus affiché comme confirmation » ne peut pas
    // passer ici.
    expect(outcome, isNotNull,
        reason: 'aucun bandeau après la prise — écran : ${visibleTexts()}');
    expect(outcome, contains(fleetLabel('fleet.opportunities.taken', const Locale('fr'))),
        reason: 'la prise a été refusée, ou son message a changé');
  });
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

  // ⚠️ `tapVisible`, pas `tester.tap` — la feuille du carnet **défile**, et son
  // champ de recherche fait remonter le clavier. Mesuré : l'entrée se trouvait
  // à y = 1035 dans une fenêtre haute de 997, donc le tap partait hors de
  // l'arbre de rendu. Flutter le signale en avertissement, pas en erreur : le
  // test continuait et échouait deux étapes plus loin, sur un formulaire dont
  // on croyait les champs remplis.
  await tapVisible(tester, entry.last);
  await tester.pump(const Duration(milliseconds: 400));
}
