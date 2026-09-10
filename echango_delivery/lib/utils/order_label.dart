/// De quoi titrer une ligne de commande entreprise : le nom de la porte de
/// livraison, avec des replis, jusqu'au `public_id` en dernier recours.
///
/// Partagé entre la liste de l'accueil entreprise et le tiroir « assigner
/// depuis la carte » (règle 5 : une seule façon de nommer une course).
///
/// ⚠️ `??` ne suffit pas : `address` vaut `''` quand le commerçant a saisi une
/// adresse sans passer par la carte, et une chaîne vide n'est pas nulle.
String fleetOrderLabel(Map<String, dynamic> order) {
  final payload = order['payload'] as Map<String, dynamic>?;
  final dropoff = payload?['dropoff'] as Map<String, dynamic>?;

  for (final candidate in [
    dropoff?['name'],
    dropoff?['address'],
    dropoff?['street1'],
    dropoff?['city'],
    order['public_id'],
  ]) {
    if (candidate is String && candidate.trim().isNotEmpty) {
      return candidate.trim();
    }
  }
  return '—';
}
