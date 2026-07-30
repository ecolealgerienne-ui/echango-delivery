/// Lectures partagées des réponses Fleetbase relayées par le BFF.
///
/// Les deux modèles de commande — celui du transporteur et celui du commerçant
/// — désérialisaient les mêmes champs chacun de son côté, et avaient déjà
/// divergé : `Order` lisait `json['id']` en second recours là où
/// `MerchantOrder` s'arrêtait avant, et seul l'un des deux traitait
/// `tracking_number` sous ses deux formes. Deux copies d'une même règle
/// finissent toujours par en devenir deux règles différentes (revue archi #14).
///
/// Le principe qui les guide toutes : **tolérance**. Une commande inattendue
/// doit rester ignorable, pas faire échouer la liste entière — c'est l'erreur
/// qui avait rendu l'app transporteur inutilisable à son premier lancement, un
/// champ déclaré obligatoire qu'aucune commande réelle ne portait.
library;

/// Identifiant interne. Fleetbase expose tantôt `uuid`, tantôt `id` — et
/// l'API publique masque `uuid` hors requête interne (journal §11.6).
String readId(Map<String, dynamic> json) =>
    (json['uuid'] ?? json['id'] ?? json['public_id'] ?? '') as String;

/// Identifiant public, celui qu'attendent la plupart des routes du BFF.
String readPublicId(Map<String, dynamic> json) =>
    (json['public_id'] ?? json['id'] ?? '') as String;

/// Identifiant d'un objet secondaire — lieu, adresse enregistrée — où l'on
/// veut le plus stable des trois, quel qu'il soit.
///
/// Distinct de [readPublicId], qui sert à adresser une route et doit donc
/// préférer `public_id` sans se rabattre sur `uuid` : les deux ne sont pas
/// interchangeables côté serveur (journal §6.7).
String readAnyId(Map<String, dynamic> json) =>
    (json['public_id'] ?? json['uuid'] ?? json['id'] ?? '') as String;

/// Statut Fleetbase réel : created, dispatched, started, enroute, completed,
/// canceled (un seul « l »). Jamais typé en énumération : la machine à états
/// vient de l'OrderConfig côté serveur, la figer ici la ferait diverger.
String readStatus(Map<String, dynamic> json) => (json['status'] ?? 'created') as String;

/// `tracking_number` est tantôt une chaîne, tantôt l'objet complet.
String? readTrackingNumber(Map<String, dynamic> json) {
  final raw = json['tracking_number'];
  if (raw is Map) return raw['tracking_number'] as String?;
  return raw as String?;
}

/// Date tolérante : une valeur absente ou illisible ne doit pas empêcher
/// d'afficher la commande.
DateTime readDate(Map<String, dynamic> json, String key) {
  final raw = json[key];
  return raw is String ? (DateTime.tryParse(raw) ?? DateTime.now()) : DateTime.now();
}

/// Lieu d'une commande, sous `payload.pickup` / `payload.dropoff`.
Map<String, dynamic>? readPlaceJson(Map<String, dynamic> json, String key) {
  final payload = json['payload'];
  if (payload is! Map<String, dynamic>) return null;
  final raw = payload[key];
  return raw is Map<String, dynamic> ? raw : null;
}

/// Coordonnées d'un lieu, au format GeoJSON.
///
/// ⚠️ `location.coordinates` est `[longitude, latitude]` — l'ordre inverse de
/// l'usage courant. Renvoie `null` quand le point est absent, ce qui arrive
/// légitimement sur une course non réclamée : le BFF retire les coordonnées du
/// point de livraison tant que le transporteur ne l'a pas acceptée.
({double latitude, double longitude})? readCoordinates(Map<String, dynamic> json) {
  final location = json['location'];
  if (location is! Map<String, dynamic>) return null;

  final coords = location['coordinates'];
  if (coords is! List || coords.length < 2) return null;

  final lon = coords[0];
  final lat = coords[1];
  if (lon is! num || lat is! num) return null;

  return (latitude: lat.toDouble(), longitude: lon.toDouble());
}
