import 'package:echango_delivery/models/order.dart';
import 'package:flutter_test/flutter_test.dart';

/// Désérialisation d'une **tournée** (spec §4) par `Order.fromJson`.
///
/// Ce qui est fixé ici : les arrêts arrivent ordonnés, les espèces par arrêt
/// sont rapprochées depuis `meta.stop_cod_amounts`, les colis sont rattachés à
/// leur arrêt, et — le point qui protège ~20 écrans — `pickupPlace` /
/// `dropoffPlace` retombent sur le premier / dernier arrêt quand Fleetbase ne
/// pose pas `payload.pickup` / `payload.dropoff`.

Map<String, dynamic> tourneeJson() => {
      'uuid': 'ord-t',
      'public_id': 'order_tournee',
      'status': 'created',
      'type': 'transport',
      'created_at': '2026-09-08T10:00:00Z',
      'updated_at': '2026-09-08T10:00:00Z',
      'meta': {
        'price': 3000,
        'currency': 'DZD',
        'is_tournee': true,
        'stop_cod_amounts': [
          {'place_uuid': 'p_d1', 'amount': 1200},
          {'place_uuid': 'p_d2', 'amount': 800},
        ],
      },
      'payload': <String, dynamic>{
        'pickup': null,
        'dropoff': null,
        // Volontairement dans le désordre : `fromJson` doit trier.
        'waypoints': <dynamic>[
          {
            'uuid': 'p_d2',
            'public_id': 'PD2',
            'name': 'M. Karim',
            'type': 'dropoff',
            'order': 2,
            'status': 'created',
            'complete': false,
            'location': {
              'type': 'Point',
              'coordinates': [2.44, 36.59],
            },
          },
          {
            'uuid': 'p_pick',
            'public_id': 'PP',
            'name': 'Entrepôt',
            'type': 'pickup',
            'order': 0,
            'location': {
              'type': 'Point',
              'coordinates': [3.1, 36.75],
            },
          },
          {
            'uuid': 'p_d1',
            'public_id': 'PD1',
            'name': 'Mme Yasmine',
            'type': 'dropoff',
            'order': 1,
            'location': {
              'type': 'Point',
              'coordinates': [2.83, 36.47],
            },
          },
        ],
        'entities': [
          {
            'public_id': 'e1',
            'name': 'Colis A',
            'description': 'Documents',
            'destination_uuid': 'p_d1',
            'meta': {'stop_index': 1},
          },
          {
            'public_id': 'e2',
            'name': 'Colis B',
            'destination_uuid': 'p_d2',
            'meta': {'stop_index': 2},
          },
          {
            // Colis collecté à l'enlèvement, routé vers le dernier arrêt.
            'public_id': 'e3',
            'name': 'Colis C',
            'destination_uuid': 'p_d2',
            'meta': {'stop_index': 0, 'collected_at_stop': true},
          },
        ],
      },
    };

Map<String, dynamic> simpleOrderJson() => {
      'uuid': 'o1',
      'public_id': 'order_1',
      'status': 'created',
      'created_at': '2026-09-08T10:00:00Z',
      'updated_at': '2026-09-08T10:00:00Z',
      'payload': {
        'pickup': {
          'uuid': 'a',
          'name': 'Magasin',
          'location': {
            'coordinates': [3.0, 36.7],
          },
        },
        'dropoff': {
          'uuid': 'b',
          'name': 'Client',
          'location': {
            'coordinates': [3.1, 36.8],
          },
        },
      },
    };

void main() {
  test('les arrêts arrivent triés par ordre', () {
    final order = Order.fromJson(tourneeJson());
    expect(order.isTournee, isTrue);
    expect(order.waypoints.map((w) => w.order), [0, 1, 2]);
    expect(order.waypoints.map((w) => w.type), ['pickup', 'dropoff', 'dropoff']);
    expect(order.waypoints.first.isPickup, isTrue);
  });

  test('pickupPlace/dropoffPlace retombent sur le premier/dernier arrêt', () {
    final order = Order.fromJson(tourneeJson());
    expect(order.pickupPlace?.name, 'Entrepôt');
    expect(order.dropoffPlace?.name, 'M. Karim');
  });

  test('les espèces par arrêt sont rapprochées depuis meta.stop_cod_amounts', () {
    final order = Order.fromJson(tourneeJson());
    final byUuid = {for (final w in order.waypoints) w.placeUuid: w};
    expect(byUuid['p_pick']!.codAmount, isNull);
    expect(byUuid['p_d1']!.codAmount, 1200);
    expect(byUuid['p_d2']!.codAmount, 800);
    // `cashStops` ne retient que les arrêts qui portent des espèces.
    expect(order.cashStops.map((w) => w.placeUuid), ['p_d1', 'p_d2']);
  });

  test('les encaissements déclarés sont rapprochés depuis meta.stop_collections',
      () {
    final json = tourneeJson();
    (json['meta'] as Map)['stop_collections'] = [
      {
        'place_uuid': 'p_d1',
        'collected_amount': 1200,
        'collected_at': '2026-09-08T12:00:00Z',
      },
      {
        'place_uuid': 'p_d2',
        'collected_amount': 0,
        'collected_at': '2026-09-08T12:30:00Z',
        'collection_reason': 'refus_de_payer',
      },
    ];
    final order = Order.fromJson(json);
    final byUuid = {for (final w in order.waypoints) w.placeUuid: w};
    expect(byUuid['p_d1']!.collectedAmount, 1200);
    // Zéro est une valeur déclarée, pas « rien déclaré ».
    expect(byUuid['p_d2']!.collectedAmount, 0);
    expect(byUuid['p_pick']!.collectedAmount, isNull);
  });

  test('les colis sont rattachés à leur arrêt par destination_uuid', () {
    final order = Order.fromJson(tourneeJson());
    final byUuid = {for (final w in order.waypoints) w.placeUuid: w};
    expect(byUuid['p_d1']!.parcels.map((p) => p.name), ['Colis A']);
    // p_d2 reçoit son propre colis + celui collecté à l'enlèvement.
    expect(byUuid['p_d2']!.parcels.map((p) => p.name), ['Colis B', 'Colis C']);
    expect(byUuid['p_pick']!.parcels, isEmpty);
  });

  test('une course 1→1 ordinaire n’a aucun waypoint', () {
    final order = Order.fromJson(simpleOrderJson());
    expect(order.isTournee, isFalse);
    expect(order.waypoints, isEmpty);
    expect(order.pickupPlace?.name, 'Magasin');
    expect(order.dropoffPlace?.name, 'Client');
    expect(order.currentWaypoint, isNull);
  });

  group('currentWaypoint', () {
    test('suit current_waypoint_uuid quand Fleetbase le donne', () {
      final json = tourneeJson();
      (json['payload'] as Map)['current_waypoint_uuid'] = 'p_d1';
      final order = Order.fromJson(json);
      expect(order.currentWaypoint?.placeUuid, 'p_d1');
    });

    test('retombe sur le premier arrêt non honoré si aucun uuid courant', () {
      final json = tourneeJson();
      // Le premier arrêt est marqué honoré.
      ((json['payload'] as Map)['waypoints'] as List)
          .firstWhere((w) => (w as Map)['order'] == 0)['complete'] = true;
      final order = Order.fromJson(json);
      expect(order.currentWaypoint?.order, 1);
    });

    test('retombe sur le dernier arrêt si tous sont honorés', () {
      final json = tourneeJson();
      for (final w in (json['payload'] as Map)['waypoints'] as List) {
        (w as Map)['complete'] = true;
      }
      final order = Order.fromJson(json);
      expect(order.currentWaypoint?.order, 2);
    });
  });
}
