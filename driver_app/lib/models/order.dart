import 'package:equatable/equatable.dart';

class Order extends Equatable {
  final String id;
  final String publicId;
  final String? customerId;
  final String facilitatorId;
  final String? driverId;
  final String status; // created, accepted, picked_up, completed, failed, cancelled
  final String payloadType;
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
    required this.facilitatorId,
    this.driverId,
    required this.status,
    required this.payloadType,
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

  bool get isPending => status == 'created' || status == 'accepted';
  bool get isInProgress => status == 'picked_up';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isCancelled => status == 'cancelled';

  Order copyWith({
    String? id,
    String? publicId,
    String? customerId,
    String? facilitatorId,
    String? driverId,
    String? status,
    String? payloadType,
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

  factory Order.fromJson(Map<String, dynamic> json) {
    return Order(
      id: json['id'] as String,
      publicId: json['public_id'] as String,
      customerId: json['customer_id'] as String?,
      facilitatorId: json['facilitator_id'] as String,
      driverId: json['driver_id'] as String?,
      status: json['status'] as String,
      payloadType: json['payload']['type'] as String? ?? 'order',
      notes: json['notes'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      pickupPlace: json['pickup_place'] != null
          ? Place.fromJson(json['pickup_place'] as Map<String, dynamic>)
          : null,
      dropoffPlace: json['dropoff_place'] != null
          ? Place.fromJson(json['dropoff_place'] as Map<String, dynamic>)
          : null,
      totalDistance: (json['distance'] as num?)?.toDouble(),
      estimatedDuration: json['estimated_duration'] as int?,
      proofUrl: json['proof_url'] as String?,
      deliveryFailure: json['delivery_failure'] != null
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

  factory Place.fromJson(Map<String, dynamic> json) {
    return Place(
      id: json['id'] as String,
      name: json['name'] as String,
      address: json['address'] as String,
      latitude: (json['location']['coordinates'][1] as num).toDouble(),
      longitude: (json['location']['coordinates'][0] as num).toDouble(),
      contactName: json['contact_name'] as String?,
      contactPhone: json['contact_phone'] as String?,
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
