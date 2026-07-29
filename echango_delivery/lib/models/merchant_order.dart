import 'package:equatable/equatable.dart';

import 'fleetbase_json.dart';
import 'order.dart' show Place;

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
  /// L'état Fleetbase n'a pas pu être récupéré : afficher « indisponible »
  /// plutôt qu'un statut faux.
  final bool degraded;
  final DateTime createdAt;
  /// Même type que côté transporteur : `OrderPlace` n'était qu'un
  /// sous-ensemble de `Place`, et deux classes pour la même donnée finissent
  /// par lire le même JSON de deux façons.
  final Place? pickup;
  final Place? dropoff;
  final String? driverName;

  /// Options telles qu'elles ont été demandées à la création.
  ///
  /// Le détail les affichait pas — le commerçant ne pouvait donc pas vérifier
  /// ce qu'il avait commandé, ni le rappeler en cas de litige. Elles viennent
  /// de `meta` et des colonnes natives, toutes projetées par le BFF.
  final DateTime? scheduledAt;
  final String? vehicleType;
  final String? podMethod;
  final String? instructions;
  final String? packageContents;
  final num? price;
  final String? currency;

  const MerchantOrder({
    required this.id,
    required this.publicId,
    required this.status,
    required this.createdAt,
    this.trackingNumber,
    this.dispatched = false,
    this.degraded = false,
    this.pickup,
    this.dropoff,
    this.driverName,
    this.scheduledAt,
    this.vehicleType,
    this.podMethod,
    this.instructions,
    this.packageContents,
    this.price,
    this.currency,
  });

  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'canceled';
  bool get isFinished => isCompleted || isCancelled;

  /// Une commande non dispatchée attend qu'un opérateur la diffuse : le
  /// commerçant peut encore l'annuler sans conséquence.
  bool get isWaitingDispatch => !dispatched && !isFinished;
  bool get canCancel => !isFinished;

  /// ⚠️ Le BFF fusionne son cache local avec l'état Fleetbase : la réponse a
  /// donc la forme d'une commande Fleetbase, plus `bff_order_id`. Deux cas
  /// dégradés existent et doivent rester lisibles plutôt que planter :
  /// `stale` (Fleetbase injoignable) et `missing` (commande disparue) — dans
  /// les deux, seuls l'identifiant et la date sont fiables.
  factory MerchantOrder.fromJson(Map<String, dynamic> json) {
    Place? place(String key) {
      final raw = readPlaceJson(json, key);
      return raw == null ? null : Place.fromJson(raw);
    }

    final driver = json['driver_assigned'];
    final meta = json['meta'] is Map<String, dynamic>
        ? json['meta'] as Map<String, dynamic>
        : null;

    return MerchantOrder(
      id: readId(json),
      publicId: readPublicId(json),
      status: readStatus(json),
      trackingNumber: readTrackingNumber(json),
      dispatched: json['dispatched'] == true,
      degraded: json['stale'] == true || json['missing'] == true,
      createdAt: readDate(json, 'created_at'),
      pickup: place('pickup'),
      dropoff: place('dropoff'),
      driverName: driver is Map<String, dynamic> ? driver['name'] as String? : null,
      scheduledAt: json['scheduled_at'] is String
          ? DateTime.tryParse(json['scheduled_at'] as String)
          : null,
      vehicleType: meta?['vehicle_type'] as String?,
      podMethod: json['pod_method'] as String?,
      instructions: meta?['instructions'] as String?,
      packageContents: _firstItemDescription(meta?['items']),
      price: meta?['price'] as num?,
      currency: meta?['currency'] as String?,
    );
  }

  @override
  List<Object?> get props => [id, publicId, status, dispatched, createdAt];
}

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
    // Une adresse enregistrée sans coordonnées est inexploitable : elle sert à
    // pré-remplir une commande, qui exige un point. D'où le repli à 0 ici, là
    // où `Place` laisse la valeur nulle — la nuance est délibérée.
    final coords = readCoordinates(json);

    return SavedAddress(
      id: readAnyId(json),
      name: (json['name'] ?? '') as String,
      address: (json['address'] ?? json['street1'] ?? '') as String,
      latitude: coords?.latitude ?? 0,
      longitude: coords?.longitude ?? 0,
      contactName: json['contact_name'] as String?,
      contactPhone: json['phone'] as String? ?? json['contact_phone'] as String?,
    );
  }

  @override
  List<Object?> get props => [id, name, address, latitude, longitude];
}

/// Résultat de géocodage renvoyé par le BFF.
///
/// [label] peut être vide : Nominatim ne connaît pas tous les points — mer,
/// zone non cartographiée. La position reste utilisable par le dispatch, c'est
/// le libellé qui manque. L'écran doit donc accepter un point sans nom plutôt
/// que de refuser la sélection.
class GeocodedPlace extends Equatable {
  final String label;
  final double latitude;
  final double longitude;
  final String? city;
  final String? postalCode;

  const GeocodedPlace({
    required this.label,
    required this.latitude,
    required this.longitude,
    this.city,
    this.postalCode,
  });

  factory GeocodedPlace.fromJson(Map<String, dynamic> json) => GeocodedPlace(
        label: (json['label'] ?? '') as String,
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
        city: json['city'] as String?,
        postalCode: json['postalCode'] as String?,
      );

  /// Libellé court pour l'écran : la commune suffit à situer, alors que le
  /// `display_name` de Nominatim tient sur trois lignes.
  String get shortLabel {
    if (city != null && city!.isNotEmpty) {
      return postalCode != null ? '$city ($postalCode)' : city!;
    }
    return label.split(',').take(2).join(',').trim();
  }

  @override
  List<Object?> get props => [label, latitude, longitude, city, postalCode];
}

/// Transporteur connu du commerçant — déjà vu sur une de ses livraisons.
///
/// [favouriteId] n'est renseigné que sur la liste des favoris : c'est
/// l'identifiant de la mise en favori, pas celui du transporteur, et c'est lui
/// qu'attend la suppression.
class KnownDriver extends Equatable {
  final String driverUuid;
  final String? name;
  final String? favouriteId;

  const KnownDriver({required this.driverUuid, this.name, this.favouriteId});

  factory KnownDriver.fromJson(Map<String, dynamic> json) => KnownDriver(
        driverUuid: (json['driver_uuid'] ?? '') as String,
        name: json['name'] as String?,
        favouriteId: json['id'] as String?,
      );

  String get displayName => (name != null && name!.isNotEmpty)
      ? name!
      : 'Transporteur ${driverUuid.substring(0, driverUuid.length.clamp(0, 8))}';

  @override
  List<Object?> get props => [driverUuid, name, favouriteId];
}
