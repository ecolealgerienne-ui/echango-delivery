import 'package:flutter/material.dart';

import '../models/order.dart' show Place, Waypoint, resolveCurrentWaypoint;
import '../theme/app_spacing.dart';

/// La liste ordonnée des arrêts d'une **tournée** (spec §4).
///
/// ── Pourquoi un widget partagé ────────────────────────────────────────────
///
/// Trois personas regardent la même tournée : le conducteur (progression), le
/// commerçant et l'entreprise (suivi). Recopier la mise en page pour chacun,
/// c'est s'engager à la corriger partout — le défaut que la règle 6 nomme.
/// Ce qui diffère d'un persona à l'autre — les mots, les actions
/// d'itinéraire/appel — passe par des paramètres, pas par des copies.
///
/// Le widget n'affiche que l'**état** : rang, type d'arrêt, avancement, montant
/// **de l'arrêt** (jamais le total de la tournée), colis, et — une fois honoré
/// — ce qui y a été encaissé. La progression elle-même reste pilotée par les
/// transitions serveur, chez l'appelant conducteur.
class TourneeStops extends StatelessWidget {
  const TourneeStops({
    super.key,
    required this.waypoints,
    required this.currentWaypointUuid,
    required this.t,
    this.codCurrency,
    this.redacted = false,
    this.onNavigate,
    this.onCall,
  });

  final List<Waypoint> waypoints;
  final String? currentWaypointUuid;

  /// Traducteur fourni par l'appelant : `t('title')`, `t('cod', {'amount': …})`.
  /// Chaque persona le branche sur sa propre table (`driver.order.tournee.*`,
  /// `order.tournee.*`, `fleet.tournee.*`).
  final String Function(String key, [Map<String, String>? vars]) t;

  final String? codCurrency;

  /// Course non réclamée : le nom et le téléphone du destinataire d'un arrêt de
  /// livraison sont retirés (le serveur les a déjà expurgés ; ceci évite juste
  /// d'afficher une ligne vide).
  final bool redacted;

  /// Fournis par le conducteur seulement : affichent la ligne « Itinéraire /
  /// Appeler » sous chaque arrêt.
  final void Function(Place place)? onNavigate;
  final void Function(String phone)? onCall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = resolveCurrentWaypoint(waypoints, currentWaypointUuid);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(t('title'), style: theme.textTheme.titleMedium),
            const Spacer(),
            Text(t('count', {'n': '${waypoints.length}'}),
                style: theme.textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < waypoints.length; i++)
          _stop(
            context,
            waypoints[i],
            i,
            isCurrent:
                current != null && waypoints[i].placeUuid == current.placeUuid,
            isLast: i == waypoints.length - 1,
          ),
      ],
    );
  }

  Widget _stop(
    BuildContext context,
    Waypoint w,
    int index, {
    required bool isCurrent,
    required bool isLast,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final done = w.complete;
    final hideIdentity = redacted && !w.isPickup;
    final showName = !hideIdentity && w.place.name.trim().isNotEmpty;

    return Container(
      margin: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: isCurrent
          ? BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.control),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor:
                done || isCurrent ? cs.primary : cs.surfaceContainerHighest,
            foregroundColor:
                done || isCurrent ? cs.onPrimary : cs.onSurfaceVariant,
            child: done
                ? const Icon(Icons.check, size: 16)
                : Text('${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      t(w.isPickup ? 'pickup' : 'dropoff'),
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    if (isCurrent && !done)
                      Text('· ${t('current')}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.onPrimaryContainer)),
                    if (done)
                      Text('· ${t('done')}', style: theme.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                if (showName)
                  Text(w.place.name,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                if (w.place.address.trim().isNotEmpty)
                  Text(w.place.address, style: theme.textTheme.bodyMedium),
                if (!hideIdentity && (w.place.contactName ?? '').trim().isNotEmpty)
                  Text(t('contact', {'name': w.place.contactName!}),
                      style: theme.textTheme.bodySmall),
                if (onNavigate != null || onCall != null) _actions(context, w),
                if (w.codAmount != null) _cod(context, w),
                if (w.parcels.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(t('parcels', {'n': '${w.parcels.length}'}),
                        style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, Waypoint w) {
    final p = w.place;
    return Wrap(
      spacing: AppSpacing.sm,
      children: [
        if (onNavigate != null && p.latitude != null && p.longitude != null)
          TextButton.icon(
            onPressed: () => onNavigate!(p),
            icon: const Icon(Icons.directions_outlined),
            label: Text(t('route')),
          ),
        if (onCall != null && (p.contactPhone ?? '').isNotEmpty)
          TextButton.icon(
            onPressed: () => onCall!(p.contactPhone!),
            icon: const Icon(Icons.phone_outlined),
            label: Text(p.contactPhone!),
          ),
      ],
    );
  }

  Widget _cod(BuildContext context, Waypoint w) {
    final theme = Theme.of(context);
    final collected = w.collectedAmount != null;
    final amount = (collected ? w.collectedAmount! : w.codAmount!)
        .toStringAsFixed(0);
    final label = '$amount ${codCurrency ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        children: [
          Icon(
            collected
                ? Icons.check_circle_outline
                : Icons.account_balance_wallet_outlined,
            size: 16,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            t(collected ? 'collected' : 'cod', {'amount': label}),
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
