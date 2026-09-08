import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echango_delivery/models/order.dart';
import 'package:echango_delivery/screens/transporteur/order_detail_screen.dart';
import 'package:echango_delivery/services/bff_api_client.dart';
import 'package:echango_delivery/state/locale_state.dart';
import 'package:echango_delivery/state/order_state.dart';

/// La fiche conducteur d'une **tournée** (spec §4) : elle montre la liste
/// ordonnée des arrêts à la place des deux blocs enlèvement / livraison, avec
/// le type de chaque arrêt, l'arrêt en cours surligné, et le montant à
/// percevoir **de cet arrêt** (pas le total de la course).

Order _tournee() => Order(
      id: 't1',
      publicId: 'order_tournee',
      status: 'started',
      payloadType: 'transport',
      createdAt: DateTime(2026, 9, 8),
      updatedAt: DateTime(2026, 9, 8),
      codAmount: 2000,
      codCurrency: 'DZD',
      currentWaypointUuid: 'p_d1',
      waypoints: const [
        Waypoint(
          place: Place(id: 'p_pick', name: 'Entrepôt Est', address: 'Zone Est'),
          placeUuid: 'p_pick',
          type: 'pickup',
          order: 0,
          complete: true,
        ),
        Waypoint(
          place: Place(id: 'p_d1', name: 'Mme Yasmine', address: '4 rue des Oliviers'),
          placeUuid: 'p_d1',
          type: 'dropoff',
          order: 1,
          codAmount: 1200,
          parcels: [TourneeParcel(id: 'e1', name: 'Colis A')],
        ),
        Waypoint(
          place: Place(id: 'p_d2', name: 'M. Karim', address: '17 lot Bounab'),
          placeUuid: 'p_d2',
          type: 'dropoff',
          order: 2,
          codAmount: 800,
        ),
      ],
    );

class _FakeApi extends BffApiClient {
  _FakeApi() : super(baseUrl: 'http://test');
  @override
  Future<Order> getOrder(String orderId) async => _tournee();
  @override
  Future<List<Map<String, dynamic>>> getNextActivities(String orderId,
          {String? waypoint}) async =>
      const [];
}

void main() {
  testWidgets('la fiche montre les N arrêts d’une tournée', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final locale = LocaleState(prefs: prefs);
    final orderState =
        OrderState(apiClient: _FakeApi(), localeState: locale);
    await orderState.selectOrder('t1');

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LocaleState>.value(value: locale),
          ChangeNotifierProvider<OrderState>.value(value: orderState),
        ],
        child: const MaterialApp(home: OrderDetailScreen(orderId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    // L'en-tête de la liste d'arrêts, et le compte.
    expect(find.text('Arrêts de la tournée'), findsOneWidget);
    expect(find.text('3 arrêts'), findsOneWidget);

    // Un enlèvement, deux livraisons.
    expect(find.text('Enlèvement'), findsOneWidget);
    expect(find.text('Livraison'), findsNWidgets(2));

    // Les trois lieux.
    expect(find.text('Entrepôt Est'), findsOneWidget);
    expect(find.text('Mme Yasmine'), findsOneWidget);
    expect(find.text('M. Karim'), findsOneWidget);

    // L'arrêt en cours est nommé, et le premier est honoré.
    expect(find.textContaining('arrêt en cours'), findsOneWidget);
    expect(find.textContaining('honoré'), findsOneWidget);

    // Le COD affiché est celui de CHAQUE arrêt, jamais le total (2000).
    expect(find.textContaining('1200'), findsOneWidget);
    expect(find.textContaining('800'), findsOneWidget);
    expect(find.textContaining('2000'), findsNothing);

    // Les colis de l'arrêt 2.
    expect(find.text('1 colis'), findsOneWidget);
  });
}
