import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echango_delivery/models/order.dart';
import 'package:echango_delivery/screens/transporteur/dashboard_screen.dart';
import 'package:echango_delivery/services/bff_api_client.dart';
import 'package:echango_delivery/state/locale_state.dart';
import 'package:echango_delivery/state/order_state.dart';
import 'package:echango_delivery/widgets/empty_state.dart';

/// L'onglet Carte du conducteur : trois absences, trois messages (4cea1b3,
/// règle 10).
///
/// « aucune course en cours », « des courses mais aucune géolocalisée » et « le
/// chargement a échoué » ne disent pas la même chose. Un seul « carte vide »
/// pour les trois se lirait comme une panne dans les deux cas où c'en est une,
/// et comme une panne à tort dans le troisième.

Order _order({double? lat, double? lng}) => Order(
      id: 'o1',
      publicId: 'order_o1',
      status: 'started',
      payloadType: 'delivery',
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
      pickupPlace: (lat == null || lng == null)
          ? null
          : Place(id: 'p1', name: 'Dépôt', address: 'Alger', latitude: lat, longitude: lng),
    );

class _FakeApi extends BffApiClient {
  _FakeApi() : super(baseUrl: 'http://test');

  Object? error;
  Map<String, List<Order>> buckets = {'active': [], 'adhoc': [], 'history': []};

  @override
  Future<DriverOrderBuckets> getOrderBuckets() async {
    if (error != null) throw error!;
    return (
      active: buckets['active'] ?? const [],
      adhoc: buckets['adhoc'] ?? const [],
      history: buckets['history'] ?? const [],
      adhocAnchorMissing: false,
    );
  }
}

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final locale = LocaleState(prefs: prefs);
  final orders = OrderState(apiClient: api, localeState: locale);
  await orders.loadOrders(); // remplit l'état comme le fait le tableau de bord

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LocaleState>.value(value: locale),
        ChangeNotifierProvider<OrderState>.value(value: orders),
      ],
      child: const MaterialApp(home: Scaffold(body: MapScreen())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('aucune course : « Aucune course en cours », pas une indisponibilité',
      (tester) async {
    await _pump(tester, _FakeApi());

    expect(find.text('Aucune course en cours'), findsOneWidget);
    // Vide RÉEL : pas l'icône ni le bouton de reprise de l'indisponibilité.
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Réessayer'), findsNothing);
  });

  testWidgets('chargement échoué : « Carte indisponible » avec reprise, pas « aucune course »',
      (tester) async {
    await _pump(tester, _FakeApi()..error = Exception('BFF injoignable'));

    expect(find.text('Carte indisponible'), findsOneWidget);
    expect(find.text('Aucune course en cours'), findsNothing);
    // C'est un aveu sur nous, pas une affirmation sur le conducteur : reprise.
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });

  testWidgets('des courses mais aucune géolocalisée : « Aucune position à afficher »',
      (tester) async {
    final api = _FakeApi()
      ..buckets = {
        'active': [_order()], // sans coordonnées
        'adhoc': [],
        'history': [],
      };
    await _pump(tester, api);

    expect(find.text('Aucune position à afficher'), findsOneWidget);
    expect(find.text('Aucune course en cours'), findsNothing);
    // Vide, pas indisponible.
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
  });

  testWidgets('les trois messages sont distincts — aucun ne se recopie',
      (tester) async {
    final seen = <String>{};
    for (final api in [
      _FakeApi(),
      _FakeApi()..error = Exception('x'),
      _FakeApi()..buckets = {'active': [_order()], 'adhoc': [], 'history': []},
    ]) {
      await _pump(tester, api);
      final empty = tester.widget<AppEmptyState>(find.byType(AppEmptyState));
      seen.add(empty.title);
    }
    expect(seen, hasLength(3));
  });
}
