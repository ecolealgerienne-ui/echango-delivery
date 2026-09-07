import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echango_delivery/models/order.dart';
import 'package:echango_delivery/state/locale_state.dart';
import 'package:echango_delivery/widgets/trip_metrics.dart';

/// La ligne de métriques d'une course — les chiffres sur lesquels un
/// transporteur décide de prendre ou refuser.
///
/// ── Ce que ces lignes décident (règle 10) ────────────────────────────────
///
/// Pas « combien de chips s'affichent » mais **quel chiffre le transporteur
/// lit, et lesquels on tait faute de les connaître** : « 0,80 km » plutôt que
/// « 800 m » perdu au milieu de kilomètres ; pas de « à 0 km de vous » quand la
/// position est inconnue, ce qui se lirait « je suis sur place ».

Order _order({double? distance, int? duration, Place? pickup}) => Order(
      id: 'o1',
      publicId: 'order_1',
      status: 'dispatched',
      payloadType: 'delivery',
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
      totalDistance: distance,
      estimatedDuration: duration,
      pickupPlace: pickup,
    );

Place _place(double lat, double lng) =>
    Place(id: 'p1', name: 'Dépôt', address: 'Alger', latitude: lat, longitude: lng);

Future<void> _pump(WidgetTester tester, Order order) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ChangeNotifierProvider<LocaleState>(
      create: (_) => LocaleState(prefs: prefs),
      child: MaterialApp(
        home: Scaffold(body: TripMetricsRow(order: order)),
      ),
    ),
  );
}

void main() {
  group('tripKm — le formatage d’un trajet', () {
    test('sous 1 km : deux décimales, virgule', () {
      expect(tripKm(800), '0,80');
      expect(tripKm(500), '0,50');
      expect(tripKm(50), '0,05');
    });

    test('au-dessus de 1 km : une décimale, virgule', () {
      expect(tripKm(1000), '1,0');
      expect(tripKm(12345), '12,3');
      expect(tripKm(2727), '2,7');
    });

    test('jamais de point décimal — l’arabe et le français écrivent la virgule', () {
      expect(tripKm(1500).contains('.'), isFalse);
      expect(tripKm(750).contains('.'), isFalse);
    });

    test('le seuil de 1 km : 999 m bascule côté « une décimale » par arrondi', () {
      // 0,999 km arrondi à 2 décimales donne « 1,00 » ; le code garde ce cas
      // sous la barre du kilomètre. C'est un bord, il est figé ici pour qu'un
      // ajustement du seuil soit un choix visible.
      expect(tripKm(999), '1,00');
      expect(tripKm(1001), '1,0');
    });
  });

  group('TripMetricsRow — ce qui s’affiche, et ce qui se tait', () {
    testWidgets('la distance de trajet s’affiche quand elle est connue',
        (tester) async {
      await _pump(tester, _order(distance: 12000));
      expect(find.text('Trajet 12,0 km'), findsOneWidget);
    });

    testWidgets('une distance nulle ou absente ne s’affiche pas',
        (tester) async {
      await _pump(tester, _order(distance: 0));
      expect(find.textContaining('Trajet'), findsNothing);
      await _pump(tester, _order(distance: null));
      expect(find.textContaining('Trajet'), findsNothing);
    });

    testWidgets('la durée ne s’affiche que si le serveur la donne',
        (tester) async {
      await _pump(tester, _order(distance: 5000, duration: 900));
      expect(find.text('~15 min'), findsOneWidget);
      await _pump(tester, _order(distance: 5000, duration: null));
      expect(find.textContaining('min'), findsNothing);
    });

    testWidgets(
        'position inconnue : PAS de « à X km de vous », même avec des coordonnées d’enlèvement',
        (tester) async {
      // LocationService n'a aucune position dans un test : le trajet à vide ne
      // peut pas être calculé, et un « 0 km » de repli se lirait « je suis sur
      // place ». La chip doit être absente, pas fausse.
      await _pump(
        tester,
        _order(distance: 8000, pickup: _place(36.75, 3.06)),
      );
      expect(find.textContaining('de vous'), findsNothing);
      expect(find.textContaining('Enlèvement à'), findsNothing);
      // La distance de trajet, elle, reste affichée.
      expect(find.text('Trajet 8,0 km'), findsOneWidget);
    });

    testWidgets('aucune métrique connue : la ligne disparaît entièrement',
        (tester) async {
      await _pump(tester, _order());
      expect(find.byType(Wrap), findsNothing);
      expect(find.textContaining('km'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(TripMetricsRow),
          matching: find.byType(SizedBox),
        ),
        findsOneWidget,
      );
    });
  });
}
