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
/// Rend `null` en cas de succès ou d'abandon, le message d'erreur traduit
/// sinon. L'abandon et le succès se ressemblent volontairement : dans les deux
/// cas il n'y a rien à dire à l'utilisateur, qui vient de voir le résultat.
///
/// La liste vient de `GET /flotte/drivers`, donc déjà bornée aux conducteurs de
/// l'entreprise ; le serveur revérifie de toute façon l'appartenance du
/// conducteur **et** de la course avant d'appeler Fleetbase (anti-IDOR validé
/// entre deux flottes le 28/07). Cet écran présente, il n'autorise pas.
Future<String?> pickAndAssignDriver(
  BuildContext context,
  String orderId,
  String Function(String key) t,
) async {
  final state = context.read<FleetState>();
  final drivers = state.drivers;

  if (drivers.isEmpty) return t('fleet.drivers.empty');
  if (orderId.isEmpty) return t('fleet.detail.not_found');

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

  if (chosen == null || !context.mounted) return null;

  return state.assignDriver(orderId, chosen);
}
