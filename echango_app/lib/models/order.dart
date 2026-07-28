import 'package:equatable/equatable.dart';

class Order extends Equatable {
  final String id;
  final String publicId;
  final String? customerId;
  /// Nullable : une commande adhoc non réclamée n'a pas de facilitateur.
  /// Le déclarer requis faisait planter tout le chargement de la liste.
  final String? facilitatorId;
  final String? driverId;
  /// Statuts Fleetbase réels : created, dispatched, started, enroute,
  /// completed, canceled (un seul « l »). Volontairement typé String et non
  /// enum : la machine à états vient de l'OrderConfig côté serveur, la figer
  /// ici la ferait diverger (journal §6.9).
  final String status;
  final String payloadType;
  /// Opportunité diffusée par le dispatch géospatial, pas encore réclamée.
  final bool adhoc;
  final String? trackingNumber;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Place? pickupPlace;
  final Place? dropoffPlace;
  final double? totalDistance;
  final int? estimatedDuration; // in seconds
  final String? proofUrl;
  final DeliveryFailure? deliveryFailure;

  const Order({
    required this.id,
    required this.publicId,
    this.customerId,
    this.facilitatorId,
    this.driverId,
    required this.status,
    required this.payloadType,
    this.adhoc = false,
    this.trackingNumber,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
    this.pickupPlace,
    this.dropoffPlace,
    this.totalDistance,
    this.estimatedDuration,
    this.proofUrl,
    this.deliveryFailure,
  });

  // Prédicats alignés sur les statuts Fleetbase réels. L'ancienne version
  // testait 'picked_up' et 'cancelled', qui n'existent pas — isInProgress
  // était donc toujours faux et aucune commande n'apparaissait en cours.
  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'canceled';
  bool get isFinished => isCompleted || isCancelled;
  bool get isPending => status == 'created' || status == 'dispatched';
  bool get isInProgress => !isFinished && !isPending;
  bool get isFailed => status == 'failed';

  Order copyWith({
    String? id,
    String? publicId,
    String? customerId,
    String? facilitatorId,
    String? driverId,
    String? status,
    String? payloadType,
    bool? adhoc,
    String? trackingNumber,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
    Place? pickupPlace,
    Place? dropoffPlace,
    double? totalDistance,
    int? estimatedDuration,
    String? proofUrl,
    DeliveryFailure? deliveryFailure,
  }) {
    return Order(
      id: id ?? this.id,
      publicId: publicId ?? this.publicId,
      customerId: customerId ?? this.customerId,
      facilitatorId: facilitatorId ?? this.facilitatorId,
      driverId: driverId ?? this.driverId,
      status: status ?? this.status,
      payloadType: payloadType ?? this.payloadType,
      adhoc: adhoc ?? this.adhoc,
      trackingNumber: trackingNumber ?? this.trackingNumber,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pickupPlace: pickupPlace ?? this.pickupPlace,
      dropoffPlace: dropoffPlace ?? this.dropoffPlace,
      totalDistance: totalDistance ?? this.totalDistance,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      proofUrl: proofUrl ?? this.proofUrl,
      deliveryFailure: deliveryFailure ?? this.deliveryFailure,
    );
  }

  /// Désérialise une commande telle que renvoyée par le BFF.
  ///
  /// ⚠️ Écrit contre la forme RÉELLE relevée le 28/07/2026 sur une commande
  /// Fleetbase (journal §6.9), pas contre l'API supposée du scaffolding. Les
  /// écarts corrigés — chacun aurait fait planter le chargement :
  ///   facilitator_id  → facilitator_uuid   (et il peut être absent)
  ///   customer_id     → customer_uuid
  ///   driver_id       → driver_assigned_uuid
  ///   pickup_place    → payload.pickup
  ///   dropoff_place   → payload.dropoff
  ///   payload.type    → type (à la racine)
  /// `notes`, `distance`, `estimated_duration`, `proof_url` et
  /// `delivery_failure` n'existent pas dans la réponse : conservés comme
  /// champs optionnels pour l'état local de l'app, jamais lus du serveur.
  ///
  /// Tolérant par principe : une commande mal formée doit être ignorable, pas
  /// faire échouer la liste entière. Tout est donc nullable ou défaillable.
  factory Order.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'] as Map<String, dynamic>?;

    Place? place(String key) {
      final raw = payload?[key];
      return raw is Map<String, dynamic> ? Place.fromJson(raw) : null;
    }

    DateTime parseDate(String key) {
      final raw = json[key];
      return raw is String ? (DateTime.tryParse(raw) ?? DateTime.now()) : DateTime.now();
    }

    return Order(
      // `uuid` est l'identifiant interne, `public_id` celui qu'attendent les
      // routes du BFF. On garde les deux : selon l'endroit, Fleetbase expose
      // l'un ou l'autre (journal §6.7/§6.14/§6.16).
      id: (json['uuid'] ?? json['id'] ?? json['public_id'] ?? '') as String,
      publicId: (json['public_id'] ?? json['id'] ?? '') as String,
      customerId: json['customer_uuid'] as String?,
      facilitatorId: json['facilitator_uuid'] as String?,
      driverId: json['driver_assigned_uuid'] as String?,
      status: (json['status'] ?? 'created') as String,
      payloadType: (json['type'] ?? 'transport') as String,
      adhoc: json['adhoc'] == true,
      trackingNumber: json['tracking_number'] is Map
          ? (json['tracking_number']['tracking_number'] as String?)
          : json['tracking_number'] as String?,
      notes: json['notes'] as String?,
      createdAt: parseDate('created_at'),
      updatedAt: parseDate('updated_at'),
      pickupPlace: place('pickup'),
      dropoffPlace: place('dropoff'),
      totalDistance: (json['distance'] as num?)?.toDouble(),
      estimatedDuration: json['estimated_duration'] as int?,
      proofUrl: json['proof_url'] as String?,
      deliveryFailure: json['delivery_failure'] is Map<String, dynamic>
          ? DeliveryFailure.fromJson(json['delivery_failure'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'public_id': publicId,
      'customer_id': customerId,
      'facilitator_id': facilitatorId,
      'driver_id': driverId,
      'status': status,
      'notes': notes,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  @override
  List<Object?> get props => [
        id,
        publicId,
        customerId,
        facilitatorId,
        driverId,
        status,
        payloadType,
        adhoc,
        trackingNumber,
        notes,
        createdAt,
        updatedAt,
        pickupPlace,
        dropoffPlace,
        totalDistance,
        estimatedDuration,
        proofUrl,
        deliveryFailure,
      ];
}

class Place extends Equatable {
  final String id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final String? contactName;
  final String? contactPhone;

  const Place({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.contactName,
    this.contactPhone,
  });

  /// Tolérant : un lieu sans coordonnées exploitables ne doit pas empêcher
  /// d'afficher la commande. Fleetbase renvoie la position en GeoJSON
  /// (`location.coordinates` = [longitude, latitude] — l'ordre est inversé
  /// par rapport à l'usage courant lat/lng).
  factory Place.fromJson(Map<String, dynamic> json) {
    final coords = (json['location'] is Map<String, dynamic>)
        ? json['location']['coordinates']
        : null;
    final hasCoords = coords is List && coords.length >= 2;

    return Place(
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
  List<Object?> get props => [
        id,
        name,
        address,
        latitude,
        longitude,
        contactName,
        contactPhone,
      ];
}

class DeliveryFailure extends Equatable {
  final String id;
  final String reason;
  final String? photoUrl;
  final String? notes;
  final DateTime createdAt;

  const DeliveryFailure({
    required this.id,
    required this.reason,
    this.photoUrl,
    this.notes,
    required this.createdAt,
  });

  factory DeliveryFailure.fromJson(Map<String, dynamic> json) {
    return DeliveryFailure(
      id: json['id'] as String,
      reason: json['reason'] as String,
      photoUrl: json['photo_url'] as String?,
      notes: json['notes'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'reason': reason,
      'photo_url': photoUrl,
      'notes': notes,
    };
  }

  @override
  List<Object?> get props => [id, reason, photoUrl, notes, createdAt];
}
