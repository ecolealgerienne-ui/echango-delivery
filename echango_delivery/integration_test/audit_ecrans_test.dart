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

import 'package:echango_delivery/main.dart' as app;

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
}
