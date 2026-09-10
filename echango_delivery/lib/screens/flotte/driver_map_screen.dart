import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../i18n/fleet_strings.dart';
import '../../models/fleet_driver_position.dart';
import '../../models/fleet_order_state.dart';
import '../../state/fleet_state.dart';
import '../../state/locale_state.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/dates.dart';
import '../../utils/order_label.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/consultation_map.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_banner.dart';

/// Où sont les conducteurs de cette entreprise.
///
/// ── Pourquoi un écran et pas un cinquième onglet ──────────────────────────
///
/// Parce qu'il se charge à la demande. Un onglet se charge en même temps que
/// les trois autres, donc à chaque ouverture de l'espace entreprise — flotte
/// entière et tuiles de carte comprises, pour quelqu'un venu consulter une
/// course. C'est exactement le défaut corrigé le 30/07 côté commerçant.
///
/// ── Ce qu'il ne prétend pas être ──────────────────────────────────────────
///
/// **Ce n'est pas un suivi en direct.** Chaque point est la dernière position
/// remontée par l'application du conducteur, et le serveur ne sait pas la
/// dater précisément (§28 : le conducteur ne porte aucun horodatage de
/// position, la fraîcheur vient d'`updated_at`, qui bouge aussi sur un passage
/// en ligne). D'où « vu il y a X » plutôt que « position datant de X », et
/// d'où le repère grisé au-delà de dix minutes : c'est la première chose qu'on
/// lit sur une carte, avant toute légende.
///
/// ── Ce qu'il permet, lui, de faire ───────────────────────────────────────
///
/// Toucher un conducteur, puis « Assigner à une course » : la carte est le
/// seul écran où l'entreprise voit **où** est chacun, donc le bon endroit pour
/// confier une course au plus proche sans repasser par la liste puis la fiche.
/// C'est le pendant de `pickAndAssignDriver` (fiche → conducteur) pris par
/// l'autre bout (conducteur → course). Le serveur revérifie l'appartenance des
/// deux avant d'appeler Fleetbase — cet écran présente, il n'autorise pas.
///
/// ⚠️ Les courses ne sont **pas** chargées par `initState` (voir plus haut) :
/// `_assignFromMap` les demande à la première ouverture de la feuille, une
/// fois, quand quelqu'un veut vraiment assigner.
class FlotteDriverMapScreen extends StatefulWidget {
  const FlotteDriverMapScreen({super.key});

  @override
  State<FlotteDriverMapScreen> createState() => _FlotteDriverMapScreenState();
}

class _FlotteDriverMapScreenState extends State<FlotteDriverMapScreen> {
  /// Le conducteur dont la fiche est ouverte sous la carte, s'il y en a un.
  String? _selected;

  @override
  void initState() {
    super.initState();
    // Après la première image : `loadDriverPositions` notifie, et notifier
    // pendant la construction lève chez Provider.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FleetState>().loadDriverPositions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleState>().locale;
    String t(String key) => fleetLabel(key, locale);

    final state = context.watch<FleetState>();
    final positions = state.driverPositions;

    return Scaffold(
      appBar: AppBar(
        title: Text(t('fleet.map.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t('fleet.map.refresh'),
            onPressed: () => context.read<FleetState>().loadDriverPositions(),
          ),
        ],
      ),
      body: Column(
        children: [
          // ⚠️ Le bandeau se pose AU-DESSUS de la carte et ne la remplace pas :
          // un rafraîchissement raté ne doit pas effacer les points déjà
          // lisibles, qui restent la meilleure information disponible.
          if (state.driverPositionsError != null)
            AppErrorBanner(
              message: state.driverPositionsError!,
              onRetry: () => context.read<FleetState>().loadDriverPositions(),
              retryLabel: t('fleet.retry'),
            ),
          Expanded(child: _body(context, t, locale, state, positions)),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    String Function(String) t,
    Locale locale,
    FleetState state,
    List<FleetDriverPosition> positions,
  ) {
    if (positions.isEmpty) {
      if (state.driverPositionsLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      // ⚠️ Deux absences, deux messages. Une lecture qui a échoué ne dit pas
      // « personne n'a remonté de position » — c'est une affirmation, et elle
      // peut être fausse. Le constructeur `unavailable` force la question à
      // l'écriture plutôt que de la laisser à la relecture.
      if (state.driverPositionsError != null) {
        return AppEmptyState.unavailable(
          title: t('fleet.map.unavailable'),
          hint: t('fleet.map.unavailable.hint'),
          onRetry: () => context.read<FleetState>().loadDriverPositions(),
        );
      }
      return AppEmptyState(
        title: t('fleet.map.empty'),
        hint: t('fleet.map.empty.hint'),
      );
    }

    final selected = _selectedOf(positions);

    return Column(
      children: [
        Expanded(
          child: AppConsultationMap(
            // Toute la flotte tient dans la vue au premier rendu ; un point
            // unique garde un zoom serré via le `maxZoom` du composant. La
            // carte reste déplaçable pour ajuster.
            fitPoints: [
              for (final p in positions)
                LatLng(p.position.latitude, p.position.longitude),
            ],
            markers: [
              for (final p in positions)
                consultationMarker(
                  context,
                  at: LatLng(p.position.latitude, p.position.longitude),
                  kind: p.position.isStale
                      ? MapMarkerKind.stale
                      : MapMarkerKind.driver,
                  selected: p.driverUuid == _selected,
                  size: 44,
                  onTap: () => setState(() => _selected = p.driverUuid),
                ),
            ],
          ),
        ),
        _Legend(
          t: t,
          locale: locale,
          positions: positions,
          selected: selected,
          onAssign: selected == null
              ? null
              : () => _assignFromMap(
                    selected.driverUuid,
                    selected.name ?? t('fleet.map.unnamed'),
                  ),
        ),
      ],
    );
  }

  /// Confier une course à ce conducteur, sans quitter la carte.
  ///
  /// Les courses viennent d'un `load()` fait **ici** et pas dans `initState` :
  /// cet écran se veut léger à l'ouverture (voir l'en-tête), et la liste des
  /// courses n'est utile qu'à ce geste-ci. On ne recharge pas si elle est déjà
  /// là.
  Future<void> _assignFromMap(String driverUuid, String driverName) async {
    final state = context.read<FleetState>();
    final locale = context.read<LocaleState>().locale;
    String tr(String key) => fleetLabel(key, locale);

    if (state.orders.isEmpty) {
      await state.load();
      if (!mounted) return;
    }

    // Une course à confier : personne dessus, et pas déjà terminée. Le même
    // couple de clés que `fleetOrderStateKey` sert à trancher — pas une
    // seconde liste de statuts terminaux (règle 5).
    final assignable = [
      for (final o in state.orders)
        if (o['driver_assigned_uuid'] == null && o['driver_assigned'] == null)
          if (fleetOrderStateKey(o) case final key
              when key != 'fleet.state.completed' &&
                  key != 'fleet.state.canceled')
            o,
    ];

    if (assignable.isEmpty) {
      showAppSnackBar(context, tr('fleet.map.assign.none'));
      return;
    }

    final orderId = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(tr('fleet.map.assign.title')),
              subtitle: Text(driverName),
            ),
            const Divider(height: 1),
            for (final o in assignable)
              ListTile(
                title: Text(fleetOrderLabel(o)),
                subtitle: Text(_orderStateText(o, tr)),
                onTap: () =>
                    Navigator.of(sheetContext).pop(o['uuid'] as String?),
              ),
          ],
        ),
      ),
    );

    if (orderId == null || !mounted) return;
    final error = await state.assignDriver(orderId, driverUuid);
    if (!mounted) return;
    showAppOutcome(context, error, tr('fleet.map.assigned'));
  }

  /// L'état d'une course pour la feuille de choix. Retombe sur le statut brut
  /// quand il n'est pas reconnu, comme la liste de l'accueil : un libellé
  /// rassurant et faux enverrait confier une course déjà close.
  String _orderStateText(Map<String, dynamic> order, String Function(String) tr) {
    final key = fleetOrderStateKey(order);
    return key != null ? tr(key) : (order['status']?.toString() ?? '—');
  }

  FleetDriverPosition? _selectedOf(List<FleetDriverPosition> positions) {
    final id = _selected;
    if (id == null) return null;
    for (final p in positions) {
      if (p.driverUuid == id) return p;
    }
    // Le conducteur sélectionné a disparu du rafraîchissement : on ne garde pas
    // une fiche qui décrirait une position qu'on ne montre plus.
    return null;
  }
}

/// Sous la carte : le compte, et la fiche du conducteur touché.
class _Legend extends StatelessWidget {
  const _Legend({
    required this.t,
    required this.locale,
    required this.positions,
    required this.selected,
    required this.onAssign,
  });

  final String Function(String) t;
  final Locale locale;
  final List<FleetDriverPosition> positions;
  final FleetDriverPosition? selected;

  /// Confier une course au conducteur touché. `null` quand aucun n'est
  /// sélectionné — le bouton n'a alors rien à cibler.
  final VoidCallback? onAssign;

  @override
  Widget build(BuildContext context) {
    final stale = positions.where((p) => p.position.isStale).length;
    final chosen = selected;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.local_shipping,
                  size: 14, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  '${positions.length} ${t('fleet.map.shown')}'
                  '${stale > 0 ? ' · $stale ${t('fleet.map.stale')}' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (chosen != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              chosen.name ?? t('fleet.map.unnamed'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              // ⚠️ « Vu il y a X » et non « position datant de X » : la date
              // vient d'`updated_at`, qui bouge aussi sur un passage en ligne.
              // Promettre une précision qu'on n'a pas ferait envoyer quelqu'un
              // à une adresse sur la foi d'un horodatage qui décrit autre chose.
              chosen.position.recordedAt == null
                  ? t('fleet.map.seen.unknown')
                  : '${t('fleet.map.seen')} '
                      '${formatRelative(chosen.position.recordedAt!, locale)}',
              style: TextStyle(
                fontSize: 12,
                color: chosen.position.isStale
                    ? Theme.of(context).colorScheme.outline
                    : context.semantic.success,
              ),
            ),
            if (onAssign != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.icon(
                  onPressed: onAssign,
                  icon: const Icon(Icons.assignment_ind_outlined),
                  label: Text(t('fleet.map.assign')),
                ),
              ),
            ],
          ] else
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                t('fleet.map.tap'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
