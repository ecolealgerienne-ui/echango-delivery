import 'package:flutter/material.dart';

import '../i18n/driver_strings.dart';
import '../models/order.dart';
import '../services/location_service.dart';
import '../state/locale_state.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_spacing.dart';
import 'package:provider/provider.dart';

/// Les chiffres sur lesquels un transporteur décide de prendre une course,
/// posés ensemble comme sur une offre Uber : longueur du trajet, durée
/// estimée si le serveur la connaît, et le trajet à vide jusqu'à l'enlèvement.
///
/// ── Trois règles ─────────────────────────────────────────────────────────
///
/// 1. **Un motif, un seul endroit** (règle 6) : cette ligne apparaît sur la
///    carte d'opportunité, la fiche de course et la suggestion d'optimisation.
///    Trois copies auraient divergé au premier ajustement.
/// 2. **« de vous » est OMIS quand la position est inconnue** (règle 10). Un
///    « 0 km » de repli se lirait « je suis sur place », le pire contresens.
/// 3. **La durée n'est affichée que si elle existe.** Fleetbase ne la remplit
///    pas sans moteur de routage (OSRM, non auto-hébergé) ; l'inventer à
///    partir de la distance serait un chiffre faux présenté comme sûr.
class TripMetricsRow extends StatelessWidget {
  const TripMetricsRow({
    super.key,
    required this.order,
    this.dense = false,
  });

  final Order order;

  /// `true` sur une carte de liste : « à X km » sans « de vous », pas de fond.
  /// `false` sur une fiche : libellé long, items posés sur un `chip`.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleState>().locale;
    String t(String k, [Map<String, String>? v]) => driverLabel(k, locale, v);

    final items = <Widget>[];

    final metres = order.totalDistance;
    if (metres != null && metres > 0) {
      items.add(_Metric(
        icon: Icons.directions_car_filled_outlined,
        label: t('driver.trip.distance', {'km': _km(metres)}),
        dense: dense,
      ));
    }

    final seconds = order.estimatedDuration;
    if (seconds != null && seconds > 0) {
      items.add(_Metric(
        icon: Icons.schedule,
        label: t('driver.trip.duration', {'min': '${(seconds / 60).round()}'}),
        dense: dense,
      ));
    }

    final pickup = order.pickupPlace;
    final fromMe = (pickup?.latitude != null && pickup?.longitude != null)
        ? LocationService()
            .distanceFromMeMetres(pickup!.latitude!, pickup.longitude!)
        : null;
    if (fromMe != null) {
      items.add(_Metric(
        icon: Icons.my_location,
        label: t(
          dense ? 'driver.trip.from_me' : 'driver.trip.from_me.long',
          {'km': _km(fromMe)},
        ),
        dense: dense,
        accent: true,
      ));
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: items,
    );
  }

  /// Un chiffre de distance : deux décimales sous 1 km (« 0,80 km » se lit
  /// mieux que « 800 m » mélangé à des kilomètres), une au-dessus.
  static String _km(double metres) {
    final km = metres / 1000;
    return (km < 1 ? km.toStringAsFixed(2) : km.toStringAsFixed(1))
        .replaceAll('.', ',');
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.label,
    required this.dense,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final bool dense;

  /// La distance jusqu'à l'enlèvement est mise en avant : c'est le trajet à
  /// vide, celui qui décide un refus.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = accent
        ? context.semantic.success
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: AppSpacing.xs),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: accent ? FontWeight.w600 : FontWeight.w400,
              ),
        ),
      ],
    );

    if (dense) return row;

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: row,
    );
  }
}
