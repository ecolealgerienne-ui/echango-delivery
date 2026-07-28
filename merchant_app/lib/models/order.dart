import 'package:equatable/equatable.dart';

/// Commande vue par le commerçant.
///
/// Désérialiseur écrit contre la forme RÉELLE renvoyée par Fleetbase, relevée
/// le 28/07/2026 (journal §6.9) : identifiants en `uuid`/`public_id`, lieux
/// dans `payload.pickup`/`payload.dropoff`, statut parmi
/// created/dispatched/started/enroute/completed/canceled.
///
/// Tolérant par principe : une commande inattendue doit être ignorable, pas
/// faire échouer la liste entière — l'erreur qui avait rendu l'app driver
/// inutilisable au premier lancement.
class MerchantOrder extends Equatable {
  final String id;
  final String publicId;
  final String status;
  final String? trackingNumber;
  final bool dispatched;
  final DateTime createdAt;
  final OrderPlace? pickup;
  final OrderPlace? dropoff;
  final String? driverName;

  const MerchantOrder({
    required this.id,
    required this.publicId,
    required this.status,
    required this.createdAt,
    this.trackingNumber,
    this.dispatched = false,
    this.pickup,
    this.dropoff,
    this.driverName,
  });

  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'canceled';
  bool get isFinished => isCompleted || isCancelled;

  /// Une commande non dispatchée attend qu'un opérateur la diffuse : le
  /// commerçant peut encore l'annuler sans conséquence.
  bool get isWaitingDispatch => !dispatched && !isFinished;
  bool get canCancel => !isFinished;

  factory MerchantOrder.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'] as Map<String, dynamic>?;

    OrderPlace? place(String key) {
      final raw = payload?[key];
      return raw is Map<String, dynamic> ? OrderPlace.fromJson(raw) : null;
    }

    DateTime parseDate(String key) {
      final raw = json[key];
      return raw is String ? (DateTime.tryParse(raw) ?? DateTime.now()) : DateTime.now();
    }

    final driver = json['driver_assigned'];

    return MerchantOrder(
      id: (json['uuid'] ?? json['id'] ?? json['public_id'] ?? '') as String,
      publicId: (json['public_id'] ?? json['id'] ?? '') as String,
      status: (json['status'] ?? 'created') as String,
      // `tracking_number` est tantôt une chaîne, tantôt l'objet complet.
      trackingNumber: json['tracking_number'] is Map
          ? json['tracking_number']['tracking_number'] as String?
          : json['tracking_number'] as String?,
      dispatched: json['dispatched'] == true,
      createdAt: parseDate('created_at'),
      pickup: place('pickup'),
      dropoff: place('dropoff'),
      driverName: driver is Map<String, dynamic> ? driver['name'] as String? : null,
    );
  }

  @override
  List<Object?> get props => [id, publicId, status, dispatched, createdAt];
}

class OrderPlace extends Equatable {
  final String name;
  final String address;

  const OrderPlace({required this.name, required this.address});

  factory OrderPlace.fromJson(Map<String, dynamic> json) {
    return OrderPlace(
      name: (json['name'] ?? '') as String,
      address: (json['address'] ?? json['street1'] ?? '') as String,
    );
  }

  @override
  List<Object?> get props => [name, address];
}

/// Adresse du carnet, réutilisable d'une commande à l'autre.
///
/// Côté Fleetbase c'est un `Place` rattaché au Vendor du commerçant par
/// `owner_uuid` — un vrai filtre serveur, vérifié en réel (journal §2.7),
/// contrairement aux filtres de `/orders` et `/drivers` qui sont ignorés.
class SavedAddress extends Equatable {
  final String id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final String? contactName;
  final String? contactPhone;

  const SavedAddress({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.contactName,
    this.contactPhone,
  });

  factory SavedAddress.fromJson(Map<String, dynamic> json) {
    // GeoJSON : coordinates = [longitude, latitude], ordre inverse de
    // l'habitude lat/lng.
    final coords = (json['location'] is Map<String, dynamic>)
        ? json['location']['coordinates']
        : null;
    final hasCoords = coords is List && coords.length >= 2;

    return SavedAddress(
      id: (json['public_id'] ?? json['uuid'] ?? json['id'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      address: (json['address'] ?? json['street1'] ?? '') as String,
      latitude: hasCoords ? (coords[1] as num).toDouble() : 0,
      longitude: hasCoords ? (coords[0] as num).toDouble() : 0,
      contactName: json['contact_name'] as String?,
      contactPhone: json['phone'] as String? ?? json['contact_phone'] as String?,
    );
  }

  @override
  List<Object?> get props => [id, name, address, latitude, longitude];
}
