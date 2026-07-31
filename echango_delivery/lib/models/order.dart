import 'package:equatable/equatable.dart';

import 'fleetbase_json.dart';

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
  final DeliveryFailure? deliveryFailure;

  /// Tous les signalements de cette commande, du plus récent au plus ancien.
  ///
  /// [deliveryFailure] n'en est que le premier : gardé pour les vues résumées,
  /// où une seule ligne a du sens. Le détail affiche la série — une livraison
  /// qui a échoué trois fois n'est pas celle qui a échoué une fois, et chaque
  /// tentative porte sa propre photo.
  final List<DeliveryFailure> deliveryFailures;

  /// Vrai quand le serveur a retiré les données personnelles : opportunité
  /// adhoc que ce transporteur n'a pas encore réclamée. Les contacts et
  /// l'adresse précise arrivent à l'acceptation.
  final bool redacted;

  /// Rémunération proposée par le commerçant, et sa devise.
  ///
  /// C'est l'information qui permet au transporteur de décider s'il prend la
  /// course. `null` quand le commerçant n'a rien proposé — l'écran doit alors
  /// le dire, et non afficher « 0 ».
  final num? price;
  final String? currency;

  /// Somme à encaisser auprès du destinataire, et sa devise.
  ///
  /// ⚠️ **Sans rapport avec [price]**, qui est ce que le transporteur gagne.
  /// Celle-ci est ce que le destinataire doit au commerçant : elle circule en
  /// sens inverse, et le transporteur ne fait que la transporter. Les afficher
  /// côte à côte sans les distinguer serait la pire confusion possible sur
  /// cet écran.
  ///
  /// `null` = livraison sans encaissement, le cas ordinaire.
  final num? codAmount;
  final String? codCurrency;

  /// Le montant à encaisser inclut-il les frais de livraison ? Sert à
  /// l'expliquer au destinataire, qui demandera pourquoi il paie ce montant.
  final bool codIncludesDelivery;

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
    this.deliveryFailure,
    this.deliveryFailures = const [],
    this.redacted = false,
    this.price,
    this.currency,
    this.codAmount,
    this.codCurrency,
    this.codIncludesDelivery = false,
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
      deliveryFailure: deliveryFailure ?? this.deliveryFailure,
      deliveryFailures: deliveryFailures,
      redacted: redacted,
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
  /// `notes`, `distance` et `estimated_duration` n'existent pas dans la
  /// réponse : conservés comme champs optionnels, jamais lus du serveur.
  ///
  /// `proofUrl` a été SUPPRIMÉ le 29/07/2026 avec le champ `proof_url` de la
  /// projection : c'était l'URL Fleetbase brute, non authentifiée. Elle n'était
  /// affichée nulle part, et un champ mort au nom évocateur est un piège — le
  /// prochain écran l'aurait affichée en croyant la preuve accessible. Les
  /// preuves passent par une route du BFF qui vérifie l'appartenance.
  ///
  /// Tolérant par principe : une commande mal formée doit être ignorable, pas
  /// faire échouer la liste entière. Tout est donc nullable ou défaillable.
  factory Order.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'] is Map<String, dynamic>
        ? json['meta'] as Map<String, dynamic>
        : null;

    Place? place(String key) {
      final raw = readPlaceJson(json, key);
      return raw == null ? null : Place.fromJson(raw);
    }

    return Order(
      // `uuid` est l'identifiant interne, `public_id` celui qu'attendent les
      // routes du BFF. On garde les deux : selon l'endroit, Fleetbase expose
      // l'un ou l'autre (journal §6.7/§6.14/§6.16).
      id: readId(json),
      publicId: readPublicId(json),
      customerId: json['customer_uuid'] as String?,
      facilitatorId: json['facilitator_uuid'] as String?,
      driverId: json['driver_assigned_uuid'] as String?,
      status: readStatus(json),
      payloadType: (json['type'] ?? 'transport') as String,
      adhoc: json['adhoc'] == true,
      trackingNumber: readTrackingNumber(json),
      notes: json['notes'] as String?,
      createdAt: readDate(json, 'created_at'),
      updatedAt: readDate(json, 'updated_at'),
      pickupPlace: place('pickup'),
      dropoffPlace: place('dropoff'),
      totalDistance: (json['distance'] as num?)?.toDouble(),
      estimatedDuration: json['estimated_duration'] as int?,
      redacted: json['redacted'] == true,
      price: meta?['price'] as num?,
      currency: meta?['currency'] as String?,
      codAmount: meta?['cod_amount'] as num?,
      codCurrency: meta?['cod_currency'] as String?,
      codIncludesDelivery: meta?['cod_includes_delivery'] == true,
      deliveryFailures: (json['delivery_failures'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(DeliveryFailure.fromJson)
              .toList() ??
          const [],
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
        deliveryFailure,
        deliveryFailures,
        redacted,
        price,
      ];

  /// Prix formaté, ou `null` si le commerçant n'a rien proposé.
  String? get formattedPrice =>
      price == null ? null : '${price!.toStringAsFixed(0)} ${currency ?? ''}'.trim();
}

class Place extends Equatable {
  final String id;
  final String name;
  final String address;
  /// Nulles quand l'adresse a été saisie sans passer par la carte. Une valeur
  /// par défaut à 0 aurait placé le point au large du golfe de Guinée, et
  /// l'itinéraire y aurait mené sans rien signaler.
  final double? latitude;
  final double? longitude;
  final String? contactName;
  final String? contactPhone;

  const Place({
    required this.id,
    required this.name,
    required this.address,
    this.latitude,
    this.longitude,
    this.contactName,
    this.contactPhone,
  });

  /// Tolérant : un lieu sans coordonnées exploitables ne doit pas empêcher
  /// d'afficher la commande. Fleetbase renvoie la position en GeoJSON
  /// (`location.coordinates` = [longitude, latitude] — l'ordre est inversé
  /// par rapport à l'usage courant lat/lng).
  factory Place.fromJson(Map<String, dynamic> json) {
    final coords = readCoordinates(json);

    return Place(
      id: readAnyId(json),
      name: (json['name'] ?? '') as String,
      address: (json['address'] ?? json['street1'] ?? '') as String,
      latitude: coords?.latitude,
      longitude: coords?.longitude,
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
