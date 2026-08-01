import 'package:flutter_test/flutter_test.dart';

import 'package:echango_delivery/models/fleet_order_state.dart';

/// La table de vérité de l'état composé.
///
/// ── Pourquoi un test, sur ce qui ressemble à de l'affichage ───────────────
///
/// Parce que ce n'est pas de l'affichage : c'est une lecture de **quatre champs
/// Fleetbase dont trois se ressemblent**, et l'ordre des tests décide du
/// résultat. Une course livrée reste `adhoc: false` et assignée ; tester la
/// diffusion avant la fin dirait « prise, aucun conducteur » sur un colis déjà
/// remis. Ce genre d'inversion se relit très bien et se comporte très mal.
///
/// La question qui a motivé le fichier — « la commande est en `dispatched`, un
/// autre transporteur peut-il la prendre ? » — a sa réponse ici : c'est `adhoc`
/// qui tranche, pas `dispatched`, et les deux cas sont vérifiés séparément.
void main() {
  Map<String, dynamic> order({
    String? status,
    bool? adhoc,
    bool? dispatched,
    String? driver,
  }) =>
      {
        if (status != null) 'status': status,
        if (adhoc != null) 'adhoc': adhoc,
        if (dispatched != null) 'dispatched': dispatched,
        if (driver != null) 'driver_assigned_uuid': driver,
      };

  group('un fait terminal rend les autres sans objet', () {
    test('livrée, même assignée et retirée du pool', () {
      expect(
        fleetOrderStateKey(order(
          status: 'completed',
          adhoc: false,
          dispatched: true,
          driver: 'd1',
        )),
        'fleet.state.completed',
      );
    });

    test('annulée, quelle que soit l’orthographe de Fleetbase', () {
      for (final s in ['canceled', 'cancelled']) {
        expect(fleetOrderStateKey(order(status: s, driver: 'd1')),
            'fleet.state.canceled');
      }
    });

    test('en cours, sous ses trois noms', () {
      for (final s in ['started', 'enroute', 'driver_enroute']) {
        expect(fleetOrderStateKey(order(status: s, driver: 'd1')),
            'fleet.state.enroute');
      }
    });
  });

  group('le cas qui affichait « dispatched » et n’expliquait rien', () {
    test('conducteur désigné, colis pas parti', () {
      expect(
        fleetOrderStateKey(order(status: 'dispatched', dispatched: true, driver: 'd1')),
        'fleet.state.awaiting_start',
      );
    });

    test('le statut n’avance pas à l’assignation — `created` dit la même chose', () {
      // `Order::dispatch()` n'écrit jamais `status`, et assigner un conducteur
      // n'écrit que `driver_assigned_uuid` : une course confiée peut donc être
      // restée `created`. Les deux doivent se lire pareil.
      expect(
        fleetOrderStateKey(order(status: 'created', driver: 'd1')),
        'fleet.state.awaiting_start',
      );
    });

    test('la relation suffit, sans l’uuid', () {
      expect(
        fleetOrderStateKey({'status': 'dispatched', 'driver_assigned': {'name': 'Ahmed'}}),
        'fleet.state.awaiting_start',
      );
    });
  });

  group('qui peut encore la prendre : c’est `adhoc`, pas `dispatched`', () {
    test('diffusée en ce moment', () {
      expect(
        fleetOrderStateKey(order(status: 'dispatched', adhoc: true, dispatched: true)),
        'fleet.state.broadcast',
      );
    });

    test('diffusée un jour, mais plus maintenant, et sans conducteur', () {
      // L'état d'une course qu'une entreprise vient de prendre : `adhoc: false`
      // écrit par `attachFacilitator`, aucun conducteur encore désigné.
      expect(
        fleetOrderStateKey(order(status: 'dispatched', adhoc: false, dispatched: true)),
        'fleet.state.taken',
      );
    });

    test('jamais publiée', () {
      expect(
        fleetOrderStateKey(order(status: 'created', adhoc: false, dispatched: false)),
        'fleet.state.draft',
      );
    });
  });

  test('un statut inconnu ne reçoit AUCUN libellé', () {
    // Le point le plus important du fichier : afficher « en cours » sur un
    // statut qu'on ne connaît pas, c'est affirmer un fait qu'on n'a pas.
    // L'appelant retombe sur le statut brut, laid mais vrai.
    expect(fleetOrderStateKey(order(status: 'preparing')), isNull);
    expect(fleetOrderStateKey(const {}), isNull);
  });
}
