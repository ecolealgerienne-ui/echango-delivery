import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../errors/error_message.dart';
import '../../i18n/driver_strings.dart';
import '../../models/route_optimization_result.dart';
import '../../services/bff_api_client.dart';
import '../../state/locale_state.dart';
import '../../state/order_state.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/place_label.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/notice.dart';

/// Depuis une course déjà tenue, d'autres courses du pool proches de sa
/// dépose — pour enchaîner sans rien réserver
/// (`docs/specs_localisation_client_et_optimisation_parcours.md` §2).
///
/// Lecture seule : accepter une suggestion réutilise `POST
/// .../accepter`, avec son verrou habituel — un autre transporteur peut
/// prendre la course entre l'affichage et le clic (`order.already_taken`),
/// exactement comme depuis « Opportunités ».
class RouteOptimizationScreen extends StatefulWidget {
  const RouteOptimizationScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<RouteOptimizationScreen> createState() =>
      _RouteOptimizationScreenState();
}

class _RouteOptimizationScreenState extends State<RouteOptimizationScreen> {
  RouteOptimizationResult? _result;
  String? _error;
  bool _loading = true;

  String _d(String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final locale = context.read<LocaleState>().locale;
    try {
      final result =
          await context.read<BffApiClient>().optimizeRoute(widget.orderId);
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = messageForError(e, locale);
        _loading = false;
      });
    }
  }

  /// Accepte une suggestion — même geste, même verrou, que depuis
  /// « Opportunités ». Un refus (course déjà prise entre-temps) s'affiche par
  /// le mécanisme d'erreur habituel, sans code particulier à ce chemin.
  Future<void> _accept(String suggestionId) async {
    final locale = context.read<LocaleState>().locale;
    try {
      await context.read<BffApiClient>().acceptOrder(suggestionId);
    } catch (e) {
      if (!mounted) return;
      showAppError(context, messageForError(e, locale));
      return;
    }

    if (!mounted) return;
    // La liste du conducteur (En cours/Opportunités) doit refléter la
    // nouvelle course acceptée dès le retour à l'écran précédent.
    await context.read<OrderState>().loadOrders();
    if (!mounted) return;
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_d('driver.optimize.title'))),
      body: _loading
          ? Center(child: Text(_d('driver.optimize.loading')))
          : _error != null
              ? AppEmptyState.unavailable(
                  title: _d('driver.optimize.unavailable'),
                  hint: _d('driver.optimize.unavailable.hint'),
                  onRetry: _load,
                )
              : _buildResult(context, _result!),
    );
  }

  Widget _buildResult(BuildContext context, RouteOptimizationResult result) {
    if (result.suggestions.isEmpty) {
      return AppEmptyState(
        title: _d('driver.optimize.empty'),
        hint: _d('driver.optimize.empty.hint'),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.sm),
        children: [
          _totalBanner(context, result),
          for (final suggestion in result.suggestions)
            _SuggestionCard(
              suggestion: suggestion,
              t: _d,
              onAccept: () => _accept(suggestion.order.id),
            ),
        ],
      ),
    );
  }

  Widget _totalBanner(BuildContext context, RouteOptimizationResult result) {
    // La devise vient des suggestions elles-mêmes : l'application n'a jamais
    // de constante « DZD » en dur (règle 1 — Fleetbase fait foi), et un total
    // sans devise connue ne l'invente pas.
    final currency = result.suggestions
        .map((s) => s.order.currency)
        .firstWhere((c) => c != null && c.isNotEmpty, orElse: () => null);
    final amount =
        '${result.totalKnownPrice.toStringAsFixed(0)} ${currency ?? ''}'.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppNotice.info(
        icon: Icons.savings_outlined,
        message: result.unknownPriceCount > 0
            ? '${_d('driver.optimize.total', {'amount': amount})}\n'
                '${_d('driver.optimize.unknown_price', {
                    'count': '${result.unknownPriceCount}',
                  })}'
            : _d('driver.optimize.total', {'amount': amount}),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.suggestion,
    required this.t,
    required this.onAccept,
  });

  final RouteSuggestion suggestion;
  final String Function(String key, [Map<String, String>? vars]) t;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final order = suggestion.order;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: ListTile(
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${placeLabel(order.pickupPlace)} → ${placeLabel(order.dropoffPlace)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (order.formattedPrice != null)
              Text(
                order.formattedPrice!,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: context.semantic.success,
                      fontWeight: FontWeight.bold,
                    ),
              ),
          ],
        ),
        subtitle: Text(
          t('driver.optimize.distance', {
            'km': suggestion.distanceKm.toStringAsFixed(1),
          }),
        ),
        trailing: FilledButton(
          onPressed: onAccept,
          child: Text(t('driver.optimize.accept')),
        ),
      ),
    );
  }
}
