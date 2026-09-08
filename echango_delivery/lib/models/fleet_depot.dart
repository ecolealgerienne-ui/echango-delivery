/// Un dépôt d'un transporteur national, tel que `GET /flotte/depots` le sert.
///
/// Côté Fleetbase c'est un `Place` possédé par le `Vendor` du transporteur,
/// marqué `meta.is_depot` — le BFF le projette sous une forme stable
/// (`FlotteService.projectDepot`) et l'app ne voit jamais le `Place` brut.
class FleetDepot {
  const FleetDepot({
    required this.uuid,
    required this.name,
    this.fleetName,
    this.address,
    this.city,
    this.neighborhood,
    this.province,
    this.postalCode,
    this.phone,
    this.contactName,
    this.latitude,
    this.longitude,
  });

  final String uuid;
  final String name;

  /// Le transporteur propriétaire — renseigné seulement quand le dépôt est servi
  /// au **commerçant** (catalogue `GET /commercant/depots`), pour distinguer
  /// deux dépôts homonymes de deux transporteurs. Nul dans l'espace flotte (on y
  /// ne voit que ses propres dépôts).
  final String? fleetName;

  final String? address;
  final String? city;
  final String? neighborhood;
  final String? province;
  final String? postalCode;
  final String? phone;
  final String? contactName;

  /// Nulles quand le point n'a pas pu être lu — jamais `0` : une position à
  /// `(0,0)` mène au large du golfe de Guinée (règle 10). Le serveur les rend
  /// déjà `null` dans ce cas ; ce contrôle est une seconde barrière.
  final double? latitude;
  final double? longitude;

  bool get hasPosition => latitude != null && longitude != null;

  /// Ce qui situe le dépôt en une ligne : quartier, commune, wilaya.
  String get locationLabel => [neighborhood, city, province]
      .where((e) => e != null && e.trim().isNotEmpty)
      .map((e) => e!.trim())
      .toSet()
      .join(', ');

  factory FleetDepot.fromJson(Map<String, dynamic> json) {
    double? asDouble(Object? v) => v is num ? v.toDouble() : null;
    return FleetDepot(
      uuid: (json['uuid'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      fleetName: json['fleet_name'] as String?,
      address: json['address'] as String?,
      city: json['city'] as String?,
      neighborhood: json['neighborhood'] as String?,
      province: json['province'] as String?,
      postalCode: json['postal_code'] as String?,
      phone: json['phone'] as String?,
      contactName: json['contact_name'] as String?,
      latitude: asDouble(json['latitude']),
      longitude: asDouble(json['longitude']),
    );
  }
}
