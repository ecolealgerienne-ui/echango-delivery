import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echango_delivery/models/order.dart';
import 'package:echango_delivery/services/bff_api_client.dart';
import 'package:echango_delivery/state/locale_state.dart';
import 'package:echango_delivery/state/order_state.dart';

/// Le rafraîchissement de fond des listes ne doit pas geler la fiche (fb4d049).
///
/// ── Ce que ces lignes décident ───────────────────────────────────────────
///
/// `loadOrders` levait le même `isLoading` que les écritures. Sur un conducteur
/// à des centaines de courses closes, `GET /transporteur/commandes` prend
/// 8-17 s, et pendant ce temps la fiche remplaçait ses boutons par un
/// indicateur d'attente — assez pour faire expirer le parcours d'intégration
/// (06/09/2026). Le correctif sépare `_listRefreshing` (fond, qu'aucun écran de
/// détail ne regarde) de `isLoading` (opération portée par l'utilisateur), et
/// détache le rechargement des listes qui suit une écriture.
///
/// Aucun de ces bords ne se voit à la lecture ; ils se prouvent ici.

Order _order(String id) => Order(
      id: id,
      publicId: 'order_$id',
      status: 'dispatched',
      payloadType: 'delivery',
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
    );

class _FakeApi extends BffApiClient {
  _FakeApi() : super(baseUrl: 'http://test');

  /// Si posé, `getOrderBuckets` attend ce verrou — pour observer l'état
  /// PENDANT le rechargement de fond.
  Completer<DriverOrderBuckets>? bucketsGate;
  Object? bucketsError;
  int bucketsCalls = 0;
  Map<String, List<Order>> buckets = {'active': [], 'adhoc': [], 'history': []};

  @override
  Future<DriverOrderBuckets> getOrderBuckets() async {
    bucketsCalls++;
    if (bucketsGate != null) return bucketsGate!.future;
    if (bucketsError != null) throw bucketsError!;
    return (
      active: buckets['active'] ?? const [],
      adhoc: buckets['adhoc'] ?? const [],
      history: buckets['history'] ?? const [],
      adhocAnchorMissing: false,
    );
  }

  @override
  Future<Order> getOrder(String orderId) async => _order(orderId);

  @override
  Future<List<Map<String, dynamic>>> getNextActivities(String orderId,
          {String? waypoint}) async =>
      const [];

  @override
  Future<void> acceptOrder(String orderId) async {}
}

Future<OrderState> _state(_FakeApi api) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return OrderState(apiClient: api, localeState: LocaleState(prefs: prefs));
}

void main() {
  test('loadOrders ne touche jamais isLoading — seulement isRefreshingLists',
      () async {
    final api = _FakeApi()..bucketsGate = Completer();
    final state = await _state(api);

    final future = state.loadOrders();
    await Future<void>.delayed(Duration.zero);

    expect(state.isRefreshingLists, isTrue, reason: 'le fond tourne');
    expect(state.isLoading, isFalse,
        reason: 'isLoading est réservé aux opérations de l’utilisateur');

    api.bucketsGate!.complete((active: <Order>[], adhoc: <Order>[], history: <Order>[], adhocAnchorMissing: false));
    await future;

    expect(state.isRefreshingLists, isFalse);
    expect(state.isLoading, isFalse);
  });

  test('loadOrders(surfaceErrors: false) avale l’échec et garde les listes',
      () async {
    final api = _FakeApi()
      ..buckets = {
        'active': [_order('a')],
        'adhoc': [],
        'history': [],
      };
    final state = await _state(api);

    await state.loadOrders();
    expect(state.orders, hasLength(1));

    api.bucketsError = Exception('BFF injoignable');
    await state.loadOrders(surfaceErrors: false);

    expect(state.errorMessage, isNull,
        reason: 'un hoquet de fond ne pose pas de bandeau');
    expect(state.orders, hasLength(1),
        reason: 'les listes gardent leur contenu, pas de vidage silencieux');
  });

  test('loadOrders() (défaut) fait remonter l’échec', () async {
    final api = _FakeApi()..bucketsError = Exception('BFF injoignable');
    final state = await _state(api);

    await state.loadOrders();

    expect(state.errorMessage, isNotNull);
  });

  test(
      'acceptOrder rend la main dès selectOrder fini, sans attendre le rechargement des listes',
      () async {
    final api = _FakeApi()..bucketsGate = Completer(); // le fond ne finira pas
    final state = await _state(api);

    final ok = await state.acceptOrder('o1');

    expect(ok, isTrue);
    expect(state.isLoading, isFalse,
        reason: 'la fiche revient dès que selectOrder a fini');
    expect(state.selectedOrder?.id, 'o1');
    expect(api.bucketsCalls, greaterThanOrEqualTo(1),
        reason: 'le rechargement des listes est bien parti…');
    expect(state.isRefreshingLists, isTrue,
        reason: '…mais il n’a pas été attendu');
    expect(api.bucketsGate!.isCompleted, isFalse);

    // ménage : libérer le verrou pour ne pas laisser un future en suspens
    api.bucketsGate!.complete((active: <Order>[], adhoc: <Order>[], history: <Order>[], adhocAnchorMissing: false));
    await Future<void>.delayed(Duration.zero);
  });
}
