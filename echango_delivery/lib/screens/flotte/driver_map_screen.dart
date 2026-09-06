import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../i18n/fleet_strings.dart';
import '../../models/fleet_driver_position.dart';
import '../../state/fleet_state.dart';
import '../../state/locale_state.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/dates.dart';
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
        ),
      ],
    );
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
  });

  final String Function(String) t;
  final Locale locale;
  final List<FleetDriverPosition> positions;
  final FleetDriverPosition? selected;

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
