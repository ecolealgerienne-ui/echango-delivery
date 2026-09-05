import '../models/order.dart';

/// Le libellé d'un point, à partir des seules composantes structurées —
/// jamais un identifiant technique en repli (règle 10 de CLAUDE.md : un
/// repli qui affiche `order_1sn4fzn6e2` est un repli qui ment poliment).
///
/// Extrait le 05/09/2026 : `dashboard_screen.dart` et l'optimisation de
/// parcours (`route_optimization_screen.dart`) posaient exactement la même
/// question sur le même type — une troisième copie identique aurait été le
/// défaut que la règle 5 vise, pas une variante légitime.
String placeLabel(Place? place) {
  if (place == null) return '—';
  if (place.name.trim().isNotEmpty) return place.name.trim();
  if (place.address.trim().isNotEmpty) return place.address.trim();
  return '—';
}
