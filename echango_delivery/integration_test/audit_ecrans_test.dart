/// Audit des écrans (04/08/2026) : ce que les scénarios `curl` ne peuvent pas
/// voir — une VALEUR affichée à l'écran, pas seulement servie par le BFF.
///
/// ── Pourquoi un fichier cible séparé ──────────────────────────────────────
///
/// `parcours_trois_personas_test.dart` joue déjà sept scénarios lourds (argent,
/// écart, refus, échec) qui closent leurs courses. On ne les rejoue pas ici :
/// ce fichier ne porte que les vérifications AJOUTÉES par l'audit des écrans, et
/// se lance avec son propre `--target` pour rester rapide et isolé.
///
/// ── Comment le lancer ─────────────────────────────────────────────────────
///
///   # dans WSL — pose le décor pour les trois personas, imprime la commande
///   ./scripts/provision-app-parcours.sh [conducteur]
///
///   # puis, côté Windows, avec les --dart-define imprimés par le script :
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/audit_ecrans_test.dart -d <émulateur> --dart-define=…
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:echango_delivery/main.dart' as app;
import 'package:echango_delivery/i18n/order_strings.dart';
import 'package:echango_delivery/state/locale_state.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetDevice);

  testWidgets(
      'conducteur — la fiche affiche le montant à encaisser, distinct du prix',
      (tester) async {
    requireCredentials({'TEST_DRIVER_EMAIL': driverEmail});
    app.main();
    await loginAs(tester, email: driverEmail, home: Home.driver);
    await openTab(tester, 0); // les opportunités

    // ⚠️ **Attendre la LISTE, jamais la ligne cherchée.** La course à encaisser
    // est plus bas dans la liste (le décor publie une dizaine d'opportunités,
    // elle n'est pas en tête) : un `ListView.builder` ne construit que ce qui
    // est à l'écran, donc `pumpUntil` sur SA ligne n'aboutirait jamais — elle
    // n'existe pas dans l'arbre avant qu'on défile (piège documenté sur
    // `scrollUntilFound`). On attend donc qu'une opportunité — n'importe
    // laquelle — soit rendue, ce qui prouve que le chargement (~9 s) a abouti,
    // PUIS on défile jusqu'à la course voulue.
    await pumpUntil(tester, find.byType(ListTile),
        reason: 'les opportunités chargées (l’endpoint répond en ~9 s)',
        onTimeout:
            'liste : ${visibleTexts()} — le décor a-t-il publié des '
            'opportunités ? relancer scripts/provision-app-parcours.sh');

    // ⚠️ La course à encaisser s'identifie par son PRIX : le nom de son
    // destinataire est masqué tant qu'elle n'est pas prise (projection
    // expurgée). Rémunération COD_FEE=$codFee, montant à encaisser
    // codAmount=$codAmount.
    final codRow = rowContaining(codFee);
    await scrollUntilFound(tester, codRow);
    expect(codRow.evaluate(), isNotEmpty,
        reason:
            'la course à encaisser (prix $codFee) doit figurer dans les '
            'opportunités — relancer scripts/provision-app-parcours.sh si absente');
    await tapVisible(tester, codRow);

    // La fiche doit AFFICHER deux montants DISTINCTS : ce que le conducteur
    // ENCAISSE à la porte (1950) et sa RÉMUNÉRATION (777). Le curl prouve que le
    // BFF les sert ; seul l'écran prouve que le conducteur les voit — et ne les
    // confond pas. C'est sur ce nombre qu'il décide et qu'il rend la monnaie.
    final wallet = find.byIcon(Icons.account_balance_wallet_outlined);
    await pumpUntil(tester, wallet,
        reason: 'la carte « à encaisser » sur la fiche de la course',
        onTimeout: 'fiche : ${visibleTexts()}');

    expect(screenHas(codAmount), isTrue,
        reason: 'le montant à ENCAISSER ($codAmount) doit être affiché');
    expect(screenHas(codFee), isTrue,
        reason:
            'la RÉMUNÉRATION ($codFee) doit être affichée, distincte du montant à encaisser');
    // Deux nombres différents : confondre la rémunération et le montant à
    // encaisser est exactement le défaut que la séparation prix / cod_amount
    // existe pour empêcher.
    expect(codAmount, isNot(equals(codFee)));
  });

  testWidgets(
      'conducteur — « rendue au réseau » et « écartée » sont deux messages distincts',
      (tester) async {
    requireCredentials({'TEST_DRIVER_EMAIL': driverEmail});
    app.main();
    await loginAs(tester, email: driverEmail, home: Home.driver);

    // ⚠️ **La seule assertion de ce dépôt qui porte sur un MESSAGE traduit, et
    // pourquoi elle ne viole pas la règle du harness.** La distinction testée
    // EST une différence de texte : rendre et écarter passent par le même
    // bouton, le même tiroir, le même ton de SnackBar — rien de structurel ne
    // les sépare. On calcule donc les deux messages par le traducteur de
    // l'application, pour sa locale COURANTE : le test tient alors en FR comme
    // en AR (le défaut que la règle vise est un littéral figé dans une langue,
    // pas une lecture du traducteur). Confondre les deux ferait hésiter à
    // refuser — ou refuser sans mesurer qu'on a engagé le commerçant.
    final locale = _appLocale(tester);
    final releaseMsg = orderLabel('driver.order.release.done', locale);
    final declineMsg = orderLabel('driver.order.decline.done', locale);
    expect(releaseMsg, isNot(equals(declineMsg)),
        reason: 'les deux messages doivent différer, sinon rien à distinguer');

    // ── RENDRE une course CONFIÉE → « rendue au réseau » ─────────────────────
    await openTab(tester, 1); // « En cours » : les courses assignées
    await pumpUntil(tester, find.byType(ListTile),
        reason: 'les courses en cours chargées (l’endpoint répond en ~9 s)',
        onTimeout:
            'liste : ${visibleTexts()} — le décor a-t-il confié une course ? '
            'relancer scripts/provision-app-parcours.sh');

    final confided = rowContaining(confidedFee); // prix distinctif de la confiée
    await scrollUntilFound(tester, confided);
    expect(confided.evaluate(), isNotEmpty,
        reason:
            'la course confiée (prix $confidedFee) doit être « en cours » — '
            'relancer scripts/provision-app-parcours.sh si absente');
    await tapVisible(tester, confided);

    // Sur une course confiée le bouton d'écartement est « Rendre » : son icône
    // ne dépend d'aucune langue.
    final giveBack = find.byIcon(Icons.do_not_disturb_on_outlined);
    await pumpUntil(tester, giveBack,
        reason: 'le bouton « rendre » sur la course confiée',
        onTimeout: 'fiche : ${visibleTexts()}');
    await tapVisible(tester, giveBack);
    await _pickReasonAndConfirm(tester);

    await pumpUntil(tester, find.text(releaseMsg),
        reason: 'le message « rendue au réseau » après avoir rendu la course',
        onTimeout: 'écran : ${visibleTexts(40)}');
    expect(screenHas(declineMsg), isFalse,
        reason:
            'rendre une course confiée ne doit PAS afficher le message d’un '
            'simple écartement — l’un engage le commerçant, l’autre non');

    // ── ÉCARTER une OPPORTUNITÉ diffusée → « écartée » ───────────────────────
    await openTab(tester, 0); // les opportunités
    await pumpUntil(tester, find.byType(ListTile),
        reason: 'les opportunités chargées',
        onTimeout: 'liste : ${visibleTexts()}');
    await tapVisible(tester, find.byType(ListTile).first);

    final decline = find.byIcon(Icons.do_not_disturb_on_outlined);
    await pumpUntil(tester, decline,
        reason: 'le bouton « refuser » sur l’opportunité',
        onTimeout: 'fiche : ${visibleTexts()}');
    await tapVisible(tester, decline);
    await _pickReasonAndConfirm(tester);

    await pumpUntil(tester, find.text(declineMsg),
        reason: 'le message « écartée » après avoir refusé une opportunité',
        onTimeout: 'écran : ${visibleTexts(40)}');
    expect(screenHas(releaseMsg), isFalse,
        reason:
            'écarter une opportunité diffusée ne doit PAS afficher le message '
            'd’une course rendue au réseau');
  });
}

/// La locale COURANTE de l'application, lue dans l'arbre — pour calculer un
/// message attendu par le même traducteur que l'écran, quelle que soit la
/// langue de l'émulateur.
Locale _appLocale(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first).read<LocaleState>().locale;

/// Le tiroir de refus : choisir un motif (obligatoire) puis confirmer.
///
/// Le motif est un `ListTile` du `BottomSheet` ; la confirmation ne s'active
/// qu'une fois un motif choisi — on l'attend plutôt que de la supposer.
Future<void> _pickReasonAndConfirm(WidgetTester tester) async {
  final reasons = find.descendant(
      of: find.byType(BottomSheet), matching: find.byType(ListTile));
  await pumpUntil(tester, reasons,
      reason: 'la liste des motifs de refus',
      onTimeout: 'tiroir : ${visibleTexts(40)}');
  await tapVisible(tester, reasons.first);

  final confirm = find.descendant(
      of: find.byType(BottomSheet), matching: find.byType(FilledButton));
  await pumpUntilTrue(
      tester,
      () => tester.widget<FilledButton>(confirm.first).onPressed != null,
      reason: 'la confirmation s’active une fois le motif choisi',
      onTimeout: 'tiroir : ${visibleTexts(40)}');
  await tapVisible(tester, confirm.first);
}
