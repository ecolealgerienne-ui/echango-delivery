import 'order.dart';

/// Une commande suggérée par l'optimisation de parcours, avec sa distance à
/// la dépose de la course déjà tenue
/// (`docs/specs_localisation_client_et_optimisation_parcours.md` §2).
///
/// Distincte du modèle [Order] : cette distance n'a de sens que dans CE
/// contexte précis — une comparaison à une autre course — pas une propriété
/// intrinsèque d'une commande, contrairement à `totalDistance` (l'itinéraire
/// propre de la course, servi par Fleetbase).
class RouteSuggestion {
  final Order order;
  final double distanceKm;

  const RouteSuggestion({required this.order, required this.distanceKm});
}

/// Résultat de `GET /transporteur/commandes/:id/optimisation`.
class RouteOptimizationResult {
  final List<RouteSuggestion> suggestions;

  /// Somme des `price` connus des suggestions retenues.
  ///
  /// Jamais un prix manquant compté comme 0 (règle 10 de CLAUDE.md) :
  /// [unknownPriceCount] dit combien de suggestions n'y sont pas comptées,
  /// pour ne jamais laisser croire à un total complet.
  final num totalKnownPrice;
  final int unknownPriceCount;

  const RouteOptimizationResult({
    required this.suggestions,
    required this.totalKnownPrice,
    required this.unknownPriceCount,
  });

  factory RouteOptimizationResult.fromJson(Map<String, dynamic> json) {
    final raw = json['suggestions'];
    final suggestions = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map((o) => RouteSuggestion(
                  order: Order.fromJson(o),
                  distanceKm: (o['distanceKm'] as num?)?.toDouble() ?? 0,
                ))
            .toList()
        : const <RouteSuggestion>[];
    return RouteOptimizationResult(
      suggestions: suggestions,
      totalKnownPrice: (json['totalKnownPrice'] as num?) ?? 0,
      unknownPriceCount: (json['unknownPriceCount'] as num?)?.toInt() ?? 0,
    );
  }
}
