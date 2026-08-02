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

  // ── Argent ───────────────────────────────────────────────────────────────
  //
  // ⚠️ **Avant le parcours transporteur, et l'ordre est une contrainte, pas un
  // goût.** Un conducteur ne détient qu'une course à la fois : celui qui en
  // prend une dans le parcours suivant ne peut plus en accepter d'autre. Le
  // parcours d'argent, lui, **termine** la sienne — il rend donc le conducteur
  // libre pour la suite. L'inverse laissait le conducteur occupé et faisait
  // échouer l'argent en accusant le décor de n'avoir rien publié.
  parcoursArgentDeuxMaillons();
  parcoursEcartALaPorte();

  // ── Les sorties d'une course ─────────────────────────────────────────────
  //
  // Placées avant le parcours transporteur, pour la même raison d'ordre : le
  // signalement d'échec **clôt** la course qu'il prend, il rend donc le
  // conducteur libre. Le parcours transporteur, lui, garde la sienne.
  parcoursSortiesDeCourse();

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

/// ── Le parcours d'argent, à l'écran ────────────────────────────────────────
///
/// Le scénario `test-parcours-argent.sh` vérifie la même chose en `curl`. Ce
/// qu'il ne peut pas vérifier, et qui est tout l'enjeu : que le transporteur
/// **puisse déclarer** l'encaissement, et que les deux parties **le voient**.
/// Un registre juste que personne ne sait lire ne vaut rien.
void parcoursArgentDeuxMaillons() {
  testWidgets('argent — le transporteur encaisse, les deux caisses le voient',
      (tester) async {
    requireCredentials({
      'TEST_DRIVER_EMAIL': driverEmail,
      'TEST_MERCHANT_EMAIL': merchantEmail,
    });

    // ── 1. Le transporteur prend la course encaissée ───────────────────────
    app.main();
    await loginAs(tester, email: driverEmail, home: Home.driver);
    await openTab(tester, 0);

    // Reconnue à son **prix**, seul repère que la carte expose : le nom du
    // destinataire est masqué tant que la course n'est pas prise, et le montant
    // à encaisser n'est pas sur la carte. Motif complet dans `harness.dart`.
    final codRow = rowContaining(codFee);

    // La liste peut compter des dizaines d'opportunités, et `ListView.builder`
    // ne construit que ce qui est à l'écran : sans défilement, une course plus
    // bas dans la liste est introuvable — motif complet dans `harness.dart`.
    await pumpUntil(tester, find.byType(ListTile),
        reason: 'la liste des opportunités');
    await scrollUntilFound(tester, codRow);

    await pumpUntil(tester, codRow,
        reason: 'la course encaissée (prix $codFee) dans les opportunités',
        onTimeout: 'introuvable même après défilement — le décor ne l’a pas '
            'publiée, ou quelqu’un l’a déjà prise. '
            'Relancer scripts/provision-app-parcours.sh');
    await tapVisible(tester, codRow.first);

    final accept = find.byType(FilledButton);
    await pumpUntil(tester, accept, reason: 'fiche de la course encaissée');
    expect(accept, findsOneWidget,
        reason: 'une opportunité réclamable n’offre que « Accepter »');
    await tapAndCatchOutcome(tester, accept);
    await pumpUntilGone(tester, find.byIcon(Icons.do_not_disturb_on_outlined),
        reason: 'la course est prise',
        onTimeout: 'fiche : ${visibleTexts()}');

    // ── 2. Il la termine, et déclare l'argent ──────────────────────────────
    //
    // ⚠️ **Le premier bouton plein est la transition suivante**, et l'ordre
    // n'est pas un hasard : la fiche empile les activités, PUIS le refus, PUIS
    // le signalement d'échec. Prendre `.first` désigne donc l'action normale,
    // jamais l'action destructrice — ce qui serait le pire tap possible.
    //
    // ⚠️ **Attendre qu'il y en ait un.** La fiche se recharge après
    // l'acceptation, et sa colonne d'actions est vide le temps de l'aller-retour
    // : prendre `.first` sans attendre lève « Bad state: No element » — un
    // message qui parle de Dart et pas du produit, donc qui envoie chercher au
    // mauvais endroit.
    // ⚠️ **Attendre DEUX boutons, pas un.** La fiche d'une course prise porte
    // au minimum la transition suivante **et** le signalement d'échec, dans cet
    // ordre. Tant que les activités ne sont pas revenues du serveur, il n'y a
    // qu'un bouton — le signalement — et `.first` désignerait donc l'action
    // destructrice. Le compte est la seule façon de savoir qu'on a bien la
    // liste complète.
    await pumpUntilTrue(
        tester, () => find.byType(FilledButton).evaluate().length >= 2,
        reason: 'les actions de la course prise (transition + signalement)',
        onTimeout: 'fiche : ${visibleTexts()}');

    // Le tiroir d'encaissement ne s'ouvre QUE si la course en attend un : son
    // apparition vaut donc vérification que le montant a bien voyagé jusqu'ici.
    final sheetAmount = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(TextField));

    // La course peut demander plusieurs transitions avant d'être livrée
    // (« en route », puis « livrée ») ; la configuration Fleetbase en décide,
    // pas nous. On avance donc jusqu'à ce que l'argent soit demandé, plutôt que
    // de parier sur le nombre d'étapes.
    //
    // ⚠️ **Chaque tour attend que les actions soient revenues.** La fiche se
    // recharge après chaque transition : taper `.first` sans attendre lève
    // « Bad state: No element » — deux fois de suite, à deux endroits
    // différents, pour la même raison. Le même piège que plus haut : entre deux
    // écritures, la colonne d'actions est vide, et ce n'est pas un défaut.
    for (var step = 0; step < 5 && sheetAmount.evaluate().isEmpty; step++) {
      final ready = await _actionsReady(tester);
      if (!ready) break;
      await tapVisible(tester, find.byType(FilledButton).first);
      await _reachedSheet(tester, sheetAmount);
    }

    await pumpUntil(tester, sheetAmount,
        reason: 'tiroir de déclaration d’encaissement',
        onTimeout: 'la course a été close SANS demander l’argent — '
            'le montant à encaisser n’est pas arrivé jusqu’à l’écran. '
            'Écran : ${visibleTexts()}');

    // ⚠️ **Le montant se LIT sur le tiroir, il ne se suppose pas.** Écrire
    // `codAmount` a échoué : avec `codIncludesDelivery: false`, le destinataire
    // règle la marchandise **et** la livraison, donc 1950 + 777 = 2727. Le
    // serveur avait raison, mon attente était fausse — et un test qui impose sa
    // propre arithmétique finit par vérifier son erreur plutôt que le produit.
    final expected = amountShownInSheet();
    expect(expected, isNotNull,
        reason: 'le tiroir n’annonce aucun montant — ${visibleTexts()}');

    await tester.enterText(sheetAmount.first, expected!);
    await tester.pump(const Duration(milliseconds: 300));

    final confirm = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(FilledButton));
    expect(confirm, findsOneWidget,
        reason: 'le tiroir n’a qu’une confirmation ; un montant exact '
            'n’ouvre aucune liste de motifs');
    await tapVisible(tester, confirm);

    await pumpUntilGone(tester, find.byType(BottomSheet),
        reason: 'le tiroir se referme — la déclaration est partie',
        onTimeout: 'écran : ${visibleTexts()}');

    // ── 3. Sa caisse porte la somme ────────────────────────────────────────
    await goBack(tester);
    await pumpUntil(tester, find.byType(Tab),
        reason: 'retour au tableau de bord');

    // ⚠️ **Le NET, pas la somme encaissée** : la caisse déduit la rémunération
    // du transporteur, et l'écran le dit — « Votre rémunération est déjà
    // déduite ». Ce qu'il veut savoir, c'est ce qu'il doit **remettre**.
    // Vérifié côté serveur : /transporteur/caisse rend 1950 pour 2727 perçus
    // sur une course à 777.
    final net = (int.parse(expected) - int.parse(codFee)).toString();
    await expectCaisseShows(tester, net);

    // Le NET est repris par le test commerçant : c'est le même nombre qui doit
    // apparaître des deux côtés, et le recalculer là-bas masquerait une
    // divergence au lieu de la révéler.
    _montantEncaisse = net;
  });

  // ⚠️ **Un test à part, et surtout PAS un second `app.main()` dans le
  // précédent (02/08/2026).**
  //
  // La première version enchaînait `resetDevice()` puis `app.main()` au milieu
  // du parcours pour changer de persona. L'instance précédente reste vivante :
  // son client HTTP garde son jeton **en mémoire**, que le vidage du stockage
  // n'atteint pas. Les écrans commerçant partaient donc avec un jeton qui n'en
  // était pas un, et le serveur répondait « This endpoint requires one of:
  // merchant » — un refus parfaitement juste, sur une session fantôme.
  //
  // Un test par persona : le harnais repart d'un arbre neuf, et `setUp` vide
  // le stockage avant chacun.
  testWidgets('argent — le commerçant voit la somme que son transporteur détient',
      (tester) async {
    requireCredentials({'TEST_MERCHANT_EMAIL': merchantEmail});
    expect(_montantEncaisse, isNotNull,
        reason: 'le parcours transporteur n’a pas déclaré d’encaissement — '
            'ce test n’a rien à vérifier');

    app.main();
    await loginAs(tester, email: merchantEmail, home: Home.merchant);

    // C'est la moitié qui compte vraiment : une dette que seul le débiteur voit
    // n'est pas une dette, c'est une note personnelle.
    await expectCaisseShows(tester, _montantEncaisse!);
  });
}

/// ── L'écart à la porte ─────────────────────────────────────────────────────
///
/// Le destinataire ne paie pas la somme annoncée. Ce n'est pas un cas limite :
/// c'est le quotidien d'une livraison contre espèces, et c'est **précisément**
/// ce que l'application doit rendre déclarable à la porte plutôt que découvert
/// cinq jours plus tard au dépôt.
///
/// Ce que ce parcours vérifie, et qu'aucun `curl` ne peut vérifier : que le
/// tiroir **refuse** une déclaration incomplète. Un motif obligatoire dont on
/// n'a jamais vu le refus n'est pas obligatoire, c'est une intention.
void parcoursEcartALaPorte() {
  testWidgets('argent — un écart à la porte exige un motif, et le tiroir refuse sans',
      (tester) async {
    requireCredentials({'TEST_DRIVER_EMAIL': driverEmail});

    app.main();
    await loginAs(tester, email: driverEmail, home: Home.driver);
    await openTab(tester, 0);

    final gapRow = rowContaining(codGapFee);
    await pumpUntil(tester, find.byType(ListTile),
        reason: 'la liste des opportunités');
    await scrollUntilFound(tester, gapRow);
    await pumpUntil(tester, gapRow,
        reason: 'la course d’écart (prix $codGapFee)',
        onTimeout: 'introuvable même après défilement — relancer '
            'scripts/provision-app-parcours.sh');
    await tapVisible(tester, gapRow.first);

    final accept = find.byType(FilledButton);
    await pumpUntil(tester, accept, reason: 'fiche de la course d’écart');
    expect(accept, findsOneWidget);
    await tapAndCatchOutcome(tester, accept);
    await pumpUntilGone(tester, find.byIcon(Icons.do_not_disturb_on_outlined),
        reason: 'la course est prise', onTimeout: 'fiche : ${visibleTexts()}');

    final sheetFields = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(TextField));
    for (var step = 0; step < 5 && sheetFields.evaluate().isEmpty; step++) {
      if (!await _actionsReady(tester)) break;
      await tapVisible(tester, find.byType(FilledButton).first);
      await _reachedSheet(tester, sheetFields);
    }
    await pumpUntil(tester, sheetFields,
        reason: 'tiroir de déclaration',
        onTimeout: 'écran : ${visibleTexts()}');

    // ── Un montant INFÉRIEUR à celui annoncé ───────────────────────────────
    final expected = amountShownInSheet();
    expect(expected, isNotNull, reason: 'le tiroir n’annonce aucun montant');
    final short = (int.parse(expected!) - 200).toString();

    await tester.enterText(sheetFields.first, short);
    await tester.pump(const Duration(milliseconds: 400));

    // ⚠️ **L'assertion centrale : le tiroir REFUSE.** Un écart ouvre une liste
    // de motifs, et la confirmation reste inerte tant qu'aucun n'est choisi.
    // C'est la seule façon de savoir que l'obligation existe : un contrôle
    // qu'on n'a jamais vu dire non n'a montré que sa capacité à dire oui.
    final confirm = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(FilledButton));
    await pumpUntil(tester, confirm, reason: 'bouton de confirmation');
    expect(tester.widget<FilledButton>(confirm.first).onPressed, isNull,
        reason: 'un écart sans motif doit rester non confirmable — '
            'écran : ${visibleTexts(40)}');

    // ── Un motif choisi, et elle passe ─────────────────────────────────────
    //
    // Les motifs sont une liste fermée servie par le serveur ; on prend le
    // premier, sans présumer de son libellé — il est traduit.
    final reasons = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(ListTile));
    await pumpUntil(tester, reasons,
        reason: 'la liste des motifs d’écart',
        onTimeout: 'aucun motif proposé alors que le montant diffère — '
            'écran : ${visibleTexts(40)}');
    await tapVisible(tester, reasons.first);

    await pumpUntilTrue(
        tester,
        () => tester.widget<FilledButton>(confirm.first).onPressed != null,
        reason: 'la confirmation s’active une fois le motif choisi',
        onTimeout: 'écran : ${visibleTexts(40)}');

    await tapVisible(tester, confirm.first);
    await pumpUntilGone(tester, find.byType(BottomSheet),
        reason: 'le tiroir se referme — l’écart est déclaré',
        onTimeout: 'écran : ${visibleTexts(40)}');

    // La somme réellement perçue, pas celle annoncée : c'est tout l'objet.
    await goBack(tester);
    await pumpUntil(tester, find.byType(Tab), reason: 'retour au tableau de bord');
    // Le net de la somme RÉELLEMENT perçue — c'est tout l'objet d'un écart :
    // la caisse suit ce qui a été encaissé, pas ce qui était annoncé.
    final netShort = (int.parse(short) - int.parse(codGapFee)).toString();
    await expectCaisseShows(tester, netShort);
  });
}

/// ── Deux des trois sorties d'une course, côté transporteur ────────────────
///
/// Une course ne se termine pas toujours par une livraison. `test-sorties-de-
/// course.sh` le vérifie côté serveur ; ce qui manque, et qui décide de tout,
/// c'est que le transporteur **puisse le dire** — un refus qu'on ne sait pas
/// exprimer se transforme en course abandonnée, et une course abandonnée n'a
/// pas de trace.
void parcoursSortiesDeCourse() {
  testWidgets('sortie — écarter une opportunité exige un motif', (tester) async {
    requireCredentials({'TEST_DRIVER_EMAIL': driverEmail});

    app.main();
    await loginAs(tester, email: driverEmail, home: Home.driver);
    await openTab(tester, 0);

    final rows = find.byType(ListTile);
    await pumpUntil(tester, rows,
        reason: 'au moins une opportunité à écarter',
        onTimeout: 'relancer scripts/provision-app-parcours.sh');
    await tapVisible(tester, rows.first);

    // Le bouton de refus est le seul `OutlinedButton` d'une fiche réclamable,
    // et son icône ne dépend d'aucune langue.
    final decline = find.byIcon(Icons.do_not_disturb_on_outlined);
    await pumpUntil(tester, decline,
        reason: 'le bouton d’écartement',
        onTimeout: 'fiche : ${visibleTexts()}');
    await tapVisible(tester, decline);

    // ⚠️ **Le motif est obligatoire, et le tiroir doit le prouver en refusant.**
    // Un refus sans motif serait une course qui disparaît sans que personne
    // sache pourquoi — exactement ce que la trace existe pour empêcher.
    final confirm = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(FilledButton));
    await pumpUntil(tester, confirm,
        reason: 'tiroir d’écartement',
        onTimeout: 'écran : ${visibleTexts()}');
    expect(tester.widget<FilledButton>(confirm.first).onPressed, isNull,
        reason: 'écarter sans motif doit rester impossible');

    final reasons = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(ListTile));
    await pumpUntil(tester, reasons, reason: 'la liste des motifs');
    await tapVisible(tester, reasons.first);

    await pumpUntilTrue(
        tester,
        () => tester.widget<FilledButton>(confirm.first).onPressed != null,
        reason: 'la confirmation s’active une fois le motif choisi',
        onTimeout: 'écran : ${visibleTexts(40)}');
    await tapVisible(tester, confirm.first);

    // La fiche d'une course écartée n'a plus de contenu : l'application revient
    // d'elle-même à la liste, et c'est ce retour qui prouve que l'écartement a
    // été enregistré plutôt qu'affiché.
    await pumpUntil(tester, find.byType(Tab),
        reason: 'retour au tableau de bord après l’écartement',
        onTimeout: 'écran : ${visibleTexts(40)}');
  });

  testWidgets('sortie — signaler un échec de livraison', (tester) async {
    requireCredentials({'TEST_DRIVER_EMAIL': driverEmail});

    app.main();
    await loginAs(tester, email: driverEmail, home: Home.driver);
    await openTab(tester, 0);

    final rows = find.byType(ListTile);
    await pumpUntil(tester, rows,
        reason: 'une opportunité à prendre',
        onTimeout: 'relancer scripts/provision-app-parcours.sh');
    await tapVisible(tester, rows.first);

    final accept = find.byType(FilledButton);
    await pumpUntil(tester, accept, reason: 'fiche de la course');
    expect(accept, findsOneWidget);
    await tapAndCatchOutcome(tester, accept);
    await pumpUntilGone(tester, find.byIcon(Icons.do_not_disturb_on_outlined),
        reason: 'la course est prise', onTimeout: 'fiche : ${visibleTexts()}');

    // ⚠️ **Le signalement est le DERNIER bouton plein**, à l'inverse des
    // transitions qui viennent en tête. C'est la contrepartie de la règle
    // employée plus haut : `.first` est l'action normale, `.last` l'action de
    // sortie. Les confondre ferait terminer la course qu'on veut signaler.
    await pumpUntilTrue(
        tester, () => find.byType(FilledButton).evaluate().length >= 2,
        reason: 'les actions de la course prise',
        onTimeout: 'fiche : ${visibleTexts()}');
    await tapVisible(tester, find.byType(FilledButton).last);

    // L'écran d'échec : un motif pré-sélectionné, des notes, une photo
    // **facultative** — un destinataire absent n'a rien à montrer, et l'exiger
    // pousserait à photographier n'importe quoi pour débloquer l'écran.
    final notes = find.byType(TextField);
    await pumpUntil(tester, notes,
        reason: 'l’écran de signalement d’échec',
        onTimeout: 'écran : ${visibleTexts()}');
    await tester.enterText(notes.first, 'Destinataire absent (parcours de test)');
    await tester.pump(const Duration(milliseconds: 300));

    final submit = find.byType(FilledButton).last;
    final said = await tapAndCatchOutcome(tester, submit);

    // ⚠️ **Le retour se fait sur la FICHE, pas sur la liste — et c'est une
    // décision produit, écrite dans le code : « un seul pop […] deux pops
    // renvoyaient à la liste, où rien ne change ; le driver ne voyait aucune
    // trace de ce qu'il venait de déclarer ».**
    //
    // Attendre les onglets du tableau de bord était donc viser le mauvais
    // écran : le test échouait sur un signalement que le serveur avait accepté
    // en 3 secondes. La bonne assertion est que la fiche **porte** désormais le
    // signalement — c'est exactement ce que le pop unique existe pour montrer.
    await pumpUntil(tester, find.byIcon(Icons.error_outline),
        reason: 'la fiche affiche le signalement d’échec',
        onTimeout: 'l’application a dit : « ${said ?? 'rien'} »'
            '\n  Écran : ${visibleTexts(40)}');
  });
}

/// Ce que le transporteur a déclaré, repris par le test commerçant.
///
/// Une variable de fichier plutôt qu'un recalcul : c'est le **même** montant
/// qui doit apparaître des deux côtés, et le recalculer des deux côtés
/// laisserait passer une divergence au lieu de la révéler.
String? _montantEncaisse;

/// La fiche a-t-elle fini de recharger ses actions ?
///
/// Deux boutons au minimum : la transition suivante **et** le signalement
/// d'échec. Un seul signifie que les activités ne sont pas revenues — taper
/// alors `.first` viserait l'action destructrice.
///
/// ⚠️ **Les délais sont calés sur la latence MESURÉE, pas sur une intuition.**
/// Relevé le 02/08/2026 dans les journaux du BFF : chaque écriture prend 3 à
/// 4,5 secondes, et une transition en enchaîne **deux** — l'application puis la
/// relecture des activités suivantes. Des attentes de six et douze secondes
/// laissaient donc la boucle repartir avant la fin du rechargement, sur des
/// boutons périmés : une seule transition partait, la course n'atteignait jamais
/// sa clôture, et l'échec se présentait comme « la caisse n'affiche rien ».
Future<bool> _actionsReady(WidgetTester tester) async {
  final until = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(until)) {
    await tester.pump(const Duration(milliseconds: 150));
    if (find.byType(FilledButton).evaluate().length >= 2) return true;
  }
  return false;
}

/// Laisse au tiroir le temps d'apparaître, sans échouer s'il ne vient pas —
/// l'appelant enchaîne alors la transition suivante.
Future<void> _reachedSheet(WidgetTester tester, Finder sheet) async {
  final until = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(until)) {
    await tester.pump(const Duration(milliseconds: 150));
    if (sheet.evaluate().isNotEmpty) return;
  }
}

/// Le montant que le tiroir annonce comme attendu.
///
/// Lu sur l'écran plutôt que recalculé : c'est le serveur qui décide si la
/// livraison s'ajoute à la marchandise, et le test n'a pas à refaire ce calcul.
String? amountShownInSheet() {
  final texts = find
      .descendant(of: find.byType(BottomSheet), matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>();
  for (final t in texts) {
    final m = RegExp(r'(\d[\d\s]*)').firstMatch(t);
    if (m != null) return m.group(1)!.replaceAll(RegExp(r'\s'), '');
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

  // ⚠️ `tapVisible`, pas `tester.tap` — la feuille du carnet **défile**, et son
  // champ de recherche fait remonter le clavier. Mesuré : l'entrée se trouvait
  // à y = 1035 dans une fenêtre haute de 997, donc le tap partait hors de
  // l'arbre de rendu. Flutter le signale en avertissement, pas en erreur : le
  // test continuait et échouait deux étapes plus loin, sur un formulaire dont
  // on croyait les champs remplis.
  await tapVisible(tester, entry.last);
  await tester.pump(const Duration(milliseconds: 400));
}
