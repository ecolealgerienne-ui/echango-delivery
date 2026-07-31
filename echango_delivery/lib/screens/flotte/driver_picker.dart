import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/fleet_state.dart';

/// Choisir un conducteur de l'entreprise, et le désigner sur une course.
///
/// ── Pourquoi ce fichier existe ─────────────────────────────────────────────
///
/// Le geste est réclamé à deux endroits — la ligne de la liste, et le pied de
/// la fiche. Le recopier aurait produit deux versions d'une même règle, et ce
/// projet a déjà payé ce prix-là (deux tables de libellés recopiées affichant
/// deux textes pour la même commande, deux désérialiseurs Dart divergents sur
/// `tracking_number`). Une seule copie, deux appelants.
///
/// ── Trois issues, et elles ne se confondent pas ──────────────────────────
///
/// Une première version rendait `null` pour le succès **et** pour l'abandon.
/// L'appelant rechargeait donc la fiche quand l'utilisateur avait simplement
/// fermé la feuille — un aller-retour réseau par geste annulé, et un commentaire
/// qui affirmait « le conducteur désigné change la fiche » sur une branche
/// atteinte alors que personne n'avait été désigné.
///
/// La liste vient de `GET /flotte/drivers`, donc déjà bornée aux conducteurs de
/// l'entreprise ; le serveur revérifie de toute façon l'appartenance du
/// conducteur **et** de la course avant d'appeler Fleetbase (anti-IDOR validé
/// entre deux flottes le 28/07). Cet écran présente, il n'autorise pas.
enum DriverAssignment { assigned, cancelled, failed }

class DriverAssignmentResult {
  const DriverAssignmentResult(this.outcome, [this.message]);

  final DriverAssignment outcome;
  final String? message;
}

Future<DriverAssignmentResult> pickAndAssignDriver(
  BuildContext context,
  String orderId,
  String Function(String key) t,
) async {
  final state = context.read<FleetState>();

  // ⚠️ L'identifiant d'abord : une course sans `uuid` n'a rien à voir avec le
  // nombre de conducteurs, et l'ordre inverse répondait « aucun conducteur »
  // à une flotte qui en a.
  if (orderId.isEmpty) {
    return DriverAssignmentResult(DriverAssignment.failed, t('fleet.detail.not_found'));
  }

  // ⚠️ « Aucun conducteur » n'est affirmé que si c'est **vrai**.
  //
  // `FleetState.load()` avale l'échec de `getFleetDrivers()` par un
  // `catchError` qui rend une liste vide — un BFF injoignable était donc
  // indiscernable d'une entreprise sans conducteur. On affirmait un fait
  // possiblement faux au moment précis où l'entreprise veut agir, ce qui est le
  // défaut le plus répété de ce projet.
  if (state.driversUnavailable) {
    return DriverAssignmentResult(DriverAssignment.failed, t('fleet.drivers.unavailable'));
  }

  final drivers = state.drivers;
  if (drivers.isEmpty) {
    return DriverAssignmentResult(DriverAssignment.failed, t('fleet.drivers.empty'));
  }

  final chosen = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(title: Text(t('fleet.drivers.select'))),
          const Divider(height: 1),
          for (final driver in drivers)
            ListTile(
              title: Text(driver['name'] as String? ?? '—'),
              subtitle: Text(driver['phone'] as String? ?? ''),
              onTap: () => Navigator.of(sheetContext).pop(driver['uuid'] as String?),
            ),
        ],
      ),
    ),
  );

  if (chosen == null || !context.mounted) {
    return const DriverAssignmentResult(DriverAssignment.cancelled);
  }

  final error = await state.assignDriver(orderId, chosen);
  return error == null
      ? const DriverAssignmentResult(DriverAssignment.assigned)
      : DriverAssignmentResult(DriverAssignment.failed, error);
}
