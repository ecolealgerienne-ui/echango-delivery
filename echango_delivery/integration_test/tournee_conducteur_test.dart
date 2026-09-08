/// Le conducteur parcourt une **tournée** aux écrans (spec §4, §4.6 points 1-2).
///
/// La mécanique serveur — Fleetbase avance `current_waypoint_uuid`, le BFF
/// consigne `meta.stop_collections` arrêt par arrêt — est déjà éprouvée par
/// `scripts/test-tournee-conducteur.sh` (banc `curl`, mutation prouvée). Ce
/// parcours-ci vérifie ce qu'un `curl` ne voit pas : que la fiche montre la
/// liste ordonnée des arrêts, que le tiroir d'encaissement annonce le montant
/// **de l'arrêt courant** (pas le total), et que la progression aboutit à une
/// tournée terminée.
///
/// Décor : `scripts/provision-app-parcours.sh` crée une tournée à
/// [tourneeFee], confiée au conducteur et **démarrée** — elle est donc dans
/// « En cours », au premier arrêt.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:echango_delivery/main.dart' as app;
import 'package:echango_delivery/widgets/tournee_stops.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tournée — la fiche montre les N arrêts et l’encaissement se '
      'déclare arrêt par arrêt', (tester) async {
    requireCredentials({'TEST_DRIVER_EMAIL': driverEmail});
    await resetDevice();

    app.main();
    await loginAs(tester, email: driverEmail, home: Home.driver);

    // Onglet 1 : les courses en cours (0 = opportunités, 2 = historique).
    await openTab(tester, 1);

    // ⚠️ Timeouts larges : `GET /transporteur/commandes` fait un
    // `fetchEveryOrder` chez Fleetbase, et l'organisation de test traîne des
    // dizaines de commandes de runs précédents — le chargement dépasse
    // largement les 40 s du défaut sur ce jeu de données.
    await pumpUntil(tester, find.byType(ListTile),
        reason: 'la liste des courses en cours',
        timeout: const Duration(seconds: 120));

    // La tournée est reconnue à son prix (5252) — la seule donnée que le décor
    // a posée et que la carte affiche. On défile jusqu'à ce que le texte du
    // prix soit **construit ET rendu**, puis on tape le ListTile qui le porte.
    final priceText = find.text('$tourneeFee DZD');
    for (var i = 0; i < 40 && priceText.evaluate().isEmpty; i++) {
      await tester.dragFrom(
          tester.getCenter(find.byType(Scaffold).first), const Offset(0, -280));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await pumpUntil(tester, priceText,
        reason: 'la tournée (prix $tourneeFee) dans « En cours »',
        timeout: const Duration(seconds: 20),
        onTimeout: 'introuvable — le décor ne l’a pas démarrée. '
            'Relancer scripts/provision-app-parcours.sh');

    final row = find.ancestor(of: priceText, matching: find.byType(ListTile));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    await tester.tap(row, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));

    // ── La fiche : trois arrêts, un enlèvement, deux livraisons ────────────
    await pumpUntil(tester, find.byType(TourneeStops),
        reason: 'la liste des arrêts de la tournée',
        timeout: const Duration(seconds: 90),
        onTimeout: 'la fiche n’affiche pas TourneeStops — ${visibleTexts()}');

    // Les libellés de type viennent de `driver.order.tournee.*`. On vérifie le
    // COMPTE (un enlèvement, deux livraisons) — un repère que le décor a posé,
    // pas une chaîne arbitraire.
    final pickups = find.textContaining(RegExp('Enlèvement', caseSensitive: false));
    final dropoffs = find.textContaining(RegExp('Livraison', caseSensitive: false));
    expect(pickups, findsWidgets, reason: 'au moins un arrêt d’enlèvement');
    expect(dropoffs.evaluate().length, greaterThanOrEqualTo(2),
        reason: 'deux arrêts de livraison — le décor en pose deux');

    // ── Progression : avancer arrêt par arrêt ─────────────────────────────
    //
    // Le flux « service stop » de Fleetbase a plusieurs activités par arrêt
    // (`enroute`, puis l'activité qui complète l'arrêt). On tape la transition
    // suivante ; quand un tiroir d'encaissement s'ouvre, c'est un arrêt à COD :
    // on lit le montant annoncé (celui de l'arrêt) et on confirme.
    final sheetField = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(TextField));

    final declared = <String>[];
    var completedSeen = false;

    for (var step = 0; step < 12; step++) {
      // La fiche se recharge après chaque transition : attendre que la colonne
      // d'actions soit revenue avant de taper (`.first` sur une liste vide
      // lève « Bad state »).
      final acted = await _tapNextAction(tester);
      if (!acted) {
        // Plus d'action : soit la tournée est terminée, soit un état inattendu.
        completedSeen = _screenLooksTerminal();
        break;
      }

      // Un tiroir d'encaissement ? → arrêt à COD.
      if (await _sheetAppeared(tester, sheetField)) {
        final amount = _amountInSheet();
        expect(amount, isNotNull,
            reason: 'le tiroir n’annonce aucun montant — ${visibleTexts()}');
        // Jamais le total de la tournée (1300 + 700 = 2000).
        expect(amount, isNot('2000'),
            reason: 'le tiroir montre le TOTAL, pas le montant de l’arrêt');
        declared.add(amount!);

        await tester.enterText(sheetField.first, amount);
        await tester.pump(const Duration(milliseconds: 300));
        final confirm = find.descendant(
            of: find.byType(BottomSheet), matching: find.byType(FilledButton));
        await tapVisible(tester, confirm);
        await pumpUntilGone(tester, find.byType(BottomSheet),
            reason: 'le tiroir se referme',
            onTimeout: 'écran : ${visibleTexts()}');
      }
    }

    // ── Verdict ───────────────────────────────────────────────────────────
    // Les deux arrêts à COD (1300 puis 700) ont chacun demandé une
    // déclaration, distincte, et jamais le total.
    expect(declared, containsAll(['1300', '700']),
        reason: 'chaque arrêt à COD déclare SON montant — obtenu $declared');

    expect(completedSeen, isTrue,
        reason: 'la tournée n’a pas atteint un état terminal après tous les '
            'arrêts — ${visibleTexts()}');
  });
}

/// Tape la transition suivante (premier `FilledButton` de la fiche), après
/// avoir attendu que les actions soient revenues du serveur. Rend `false` si
/// aucune action n'apparaît (fiche sans bouton = course close).
Future<bool> _tapNextAction(WidgetTester tester) async {
  final until = DateTime.now().add(const Duration(seconds: 12));
  while (DateTime.now().isBefore(until)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (find.byType(BottomSheet).evaluate().isNotEmpty) return true;
    final buttons = find.byType(FilledButton);
    if (buttons.evaluate().isNotEmpty) {
      await tapVisible(tester, buttons.first);
      await tester.pump(const Duration(milliseconds: 500));
      return true;
    }
  }
  return false;
}

Future<bool> _sheetAppeared(WidgetTester tester, Finder sheetField) async {
  final until = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(until)) {
    await tester.pump(const Duration(milliseconds: 150));
    if (sheetField.evaluate().isNotEmpty) return true;
  }
  return false;
}

String? _amountInSheet() {
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

/// La fiche est-elle dans un état terminal ? Un arrêt honoré porte « honoré » ;
/// une tournée entièrement faite n'a plus d'activité et ses arrêts sont tous
/// marqués.
bool _screenLooksTerminal() {
  final done = find.textContaining(RegExp('honoré', caseSensitive: false));
  final collected = find.textContaining(RegExp('Encaissé', caseSensitive: false));
  return done.evaluate().length >= 3 || collected.evaluate().length >= 2;
}
