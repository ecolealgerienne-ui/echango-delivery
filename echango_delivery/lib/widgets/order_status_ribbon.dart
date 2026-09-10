import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/order_strings.dart';
import '../state/locale_state.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_spacing.dart';

/// Le suivi d'une livraison en trois pas : **Créée → En route → Livrée**.
///
/// ── Pourquoi un ruban et pas seulement un libellé ────────────────────────
///
/// Le commerçant a surtout besoin de savoir *où ça en est*, d'un coup d'œil.
/// Un mot (« En route ») le dit ; un ruban dit en plus **ce qui reste**. C'est
/// le motif de toutes les pages de suivi de colis.
///
/// ── Le statut annulé n'est pas un quatrième pas ──────────────────────────
///
/// Une course annulée n'a pas « avancé » — elle s'est arrêtée. Le ruban se
/// grise alors et porte le mot « Annulée », plutôt que de suggérer une
/// progression qui n'a pas eu lieu (règle 10 : ne pas déguiser une absence en
/// donnée).
class OrderStatusRibbon extends StatelessWidget {
  /// Le statut Fleetbase brut (`created`, `dispatched`, `started`, `enroute`,
  /// `completed`, `canceled`).
  final String status;

  const OrderStatusRibbon({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleState>().locale;
    String t(String k) => orderLabel(k, locale);
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semantic;

    if (status == 'canceled' || status == 'cancelled') {
      return _CanceledBar(label: t('order.track.canceled'));
    }

    // 0 = Créée, 1 = En route, 2 = Livrée.
    final current = switch (status) {
      'created' || 'dispatched' => 0,
      'started' || 'enroute' => 1,
      'completed' => 2,
      _ => 0,
    };

    final steps = [
      t('order.track.created'),
      t('order.track.enroute'),
      t('order.track.delivered'),
    ];

    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                color: i <= current ? semantic.success : scheme.outlineVariant,
              ),
            ),
          _Step(
            label: steps[i],
            done: i < current,
            active: i == current,
            doneColor: semantic.success,
            onDone: semantic.onSuccess,
            activeColor: scheme.primary,
            onActive: scheme.onPrimary,
            idleColor: scheme.outlineVariant,
            onIdle: scheme.onSurfaceVariant,
          ),
        ],
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.label,
    required this.done,
    required this.active,
    required this.doneColor,
    required this.onDone,
    required this.activeColor,
    required this.onActive,
    required this.idleColor,
    required this.onIdle,
  });

  final String label;
  final bool done;
  final bool active;
  final Color doneColor;
  final Color onDone;
  final Color activeColor;
  final Color onActive;
  final Color idleColor;
  final Color onIdle;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = done
        ? (doneColor, onDone)
        : active
            ? (activeColor, onActive)
            : (idleColor, onIdle);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: AppSpacing.xl,
          height: AppSpacing.xl,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(
            done ? Icons.check : Icons.circle,
            size: done ? AppSpacing.lg : 10,
            color: fg,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
        ),
      ],
    );
  }
}

class _CanceledBar extends StatelessWidget {
  const _CanceledBar({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        children: [
          Icon(Icons.cancel_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
