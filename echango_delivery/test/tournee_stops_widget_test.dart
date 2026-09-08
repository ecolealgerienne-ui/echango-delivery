import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echango_delivery/models/order.dart';
import 'package:echango_delivery/widgets/tournee_stops.dart';

/// Le widget partagé `TourneeStops` : liste ordonnée, arrêt courant surligné,
/// montant **de l'arrêt** (jamais le total), « Encaissé » une fois honoré,
/// expurgation par arrêt, et actions itinéraire/appel seulement si l'appelant
/// les fournit (conducteur).

List<Waypoint> _stops() => const [
      Waypoint(
        place: Place(id: 'p0', name: 'Entrepôt', address: 'ZI Est'),
        placeUuid: 'p0',
        type: 'pickup',
        order: 0,
        complete: true,
      ),
      Waypoint(
        place: Place(
          id: 'p1',
          name: 'Mme Y',
          address: '4 rue A',
          contactName: 'Mme Y',
          contactPhone: '0661',
          latitude: 36.4,
          longitude: 2.8,
        ),
        placeUuid: 'p1',
        type: 'dropoff',
        order: 1,
        codAmount: 1200,
        collectedAmount: 1200,
        complete: true,
      ),
      Waypoint(
        place: Place(
          id: 'p2',
          name: 'M. K',
          address: '17 lot B',
          contactName: 'M. K',
          latitude: 36.5,
          longitude: 3.1,
        ),
        placeUuid: 'p2',
        type: 'dropoff',
        order: 2,
        codAmount: 800,
      ),
    ];

// Traducteur minimal : renvoie une forme lisible de la clé + vars.
String _t(String k, [Map<String, String>? v]) {
  switch (k) {
    case 'title':
      return 'Arrêts';
    case 'count':
      return '${v!['n']} arrêts';
    case 'pickup':
      return 'Enlèvement';
    case 'dropoff':
      return 'Livraison';
    case 'current':
      return 'arrêt en cours';
    case 'done':
      return 'honoré';
    case 'cod':
      return 'À encaisser ici : ${v!['amount']}';
    case 'collected':
      return 'Encaissé : ${v!['amount']}';
    case 'parcels':
      return '${v!['n']} colis';
    case 'contact':
      return 'Contact : ${v!['name']}';
    case 'route':
      return 'Itinéraire';
    default:
      return k;
  }
}

Widget _host(TourneeStops w) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: w)));

void main() {
  testWidgets('vue suivi (commerçant) : montants par arrêt, pas d’actions',
      (tester) async {
    await tester.pumpWidget(_host(TourneeStops(
      waypoints: _stops(),
      currentWaypointUuid: 'p2',
      codCurrency: 'DZD',
      t: _t,
    )));

    expect(find.text('3 arrêts'), findsOneWidget);
    expect(find.text('Enlèvement'), findsOneWidget);
    expect(find.text('Livraison'), findsNWidgets(2));
    // p1 honoré + encaissé → « Encaissé : 1200 » ; p2 pas fait → « À encaisser ».
    expect(find.text('Encaissé : 1200 DZD'), findsOneWidget);
    expect(find.text('À encaisser ici : 800 DZD'), findsOneWidget);
    // Jamais le total.
    expect(find.textContaining('2000'), findsNothing);
    // Deux arrêts honorés (enlèvement + p1).
    expect(find.textContaining('honoré'), findsNWidgets(2));
    // p2 est l'arrêt courant.
    expect(find.textContaining('arrêt en cours'), findsOneWidget);
    // Pas d'itinéraire / appel sans callbacks.
    expect(find.text('Itinéraire'), findsNothing);
    expect(find.text('0661'), findsNothing);
  });

  testWidgets('vue conducteur : itinéraire + appel quand fournis',
      (tester) async {
    Place? navigated;
    String? called;
    await tester.pumpWidget(_host(TourneeStops(
      waypoints: _stops(),
      currentWaypointUuid: 'p2',
      codCurrency: 'DZD',
      t: _t,
      onNavigate: (p) => navigated = p,
      onCall: (ph) => called = ph,
    )));

    // p1 a un téléphone → bouton d'appel ; p1/p2 ont des coords → itinéraire.
    expect(find.text('Itinéraire'), findsNWidgets(2));
    await tester.tap(find.text('0661'));
    expect(called, '0661');
    await tester.tap(find.text('Itinéraire').first);
    expect(navigated, isNotNull);
  });

  testWidgets('redacted : l’identité des arrêts de livraison disparaît, pas l’enlèvement',
      (tester) async {
    await tester.pumpWidget(_host(TourneeStops(
      waypoints: _stops(),
      currentWaypointUuid: 'p1',
      codCurrency: 'DZD',
      t: _t,
      redacted: true,
    )));

    expect(find.text('Entrepôt'), findsOneWidget); // enlèvement : gardé
    expect(find.text('Mme Y'), findsNothing); // livraison : masqué
    expect(find.text('M. K'), findsNothing);
    expect(find.textContaining('Contact'), findsNothing);
    // L'adresse reste — c'est le critère de décision.
    expect(find.text('4 rue A'), findsOneWidget);
  });
}
