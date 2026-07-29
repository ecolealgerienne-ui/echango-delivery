import 'package:equatable/equatable.dart';

import 'cash.dart';
import 'fleetbase_json.dart';
// `DeliveryFailure` est partagé avec le transporteur : c'est le même
// signalement, vu des deux bouts. Une seconde classe pour le même JSON finirait
// par le lire de deux façons (revue archi #14).
import 'order.dart' show DeliveryFailure, Place;

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

  /// Téléphone du transporteur affecté.
  ///
  /// Le BFF le projetait déjà ; personne ne le lisait. Un commerçant qui veut
  /// savoir où en est sa livraison n'avait aucun moyen de joindre le coursier,
  /// alors que le numéro était déjà dans la réponse HTTP.
  final String? driverPhone;

  /// Somme que le destinataire doit remettre au transporteur.
  ///
  /// Distincte de [price], la rémunération du transporteur : elles circulent en
  /// sens inverse. Le commerçant est le seul à voir les deux, raison de plus
  /// pour ne jamais les présenter ensemble sans les nommer.
  final num? codAmount;
  final String? codCurrency;

  /// Ce qui a réellement été encaissé, une fois la livraison faite.
  ///
  /// `null` tant que le transporteur n'a rien déclaré. Distinct de [codAmount],
  /// qui n'est que ce qui était **demandé** : afficher le second en croyant lire
  /// le premier ferait passer une livraison à moitié payée pour une livraison
  /// réglée.
  final CashCollectionEntry? cashCollection;

  /// Signalements d'échec, du plus récent au plus ancien.
  ///
  /// Le commerçant ne recevait qu'une notification d'une ligne. C'est pourtant
  /// lui qui devra répondre à son propre client, et le justificatif n'allait
  /// qu'à celui qui l'avait produit.
  final List<DeliveryFailure> deliveryFailures;

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
    this.driverPhone,
    this.codAmount,
    this.codCurrency,
    this.cashCollection,
    this.deliveryFailures = const [],
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
      driverPhone: driver is Map<String, dynamic> ? driver['phone'] as String? : null,
      deliveryFailures: json['delivery_failures'] is List
          ? (json['delivery_failures'] as List)
              .whereType<Map<String, dynamic>>()
              .map(DeliveryFailure.fromJson)
              .toList()
          : const [],
      scheduledAt: json['scheduled_at'] is String
          ? DateTime.tryParse(json['scheduled_at'] as String)
          : null,
      vehicleType: meta?['vehicle_type'] as String?,
      podMethod: json['pod_method'] as String?,
      instructions: meta?['instructions'] as String?,
      packageContents: _firstItemDescription(meta?['items']),
      price: meta?['price'] as num?,
      currency: meta?['currency'] as String?,
      codAmount: meta?['cod_amount'] as num?,
      codCurrency: meta?['cod_currency'] as String?,
      cashCollection: json['cash_collection'] is Map<String, dynamic>
          ? CashCollectionEntry.fromJson(
              json['cash_collection'] as Map<String, dynamic>)
          : null,
    );
  }

  @override
  List<Object?> get props => [id, publicId, status, dispatched, createdAt];
}

/// Résumé lisible du contenu du colis, à partir de `meta.items`.
///
/// Une ligne, pas la liste : le détail sert au transporteur qui charge, le
/// commerçant veut seulement reconnaître sa commande. Le nombre d'articles
/// restants est dit plutôt que caché — « Gâteau » et « Gâteau (+3) » ne
/// décrivent pas la même livraison.
String? _firstItemDescription(dynamic items) {
  if (items is! List || items.isEmpty) return null;

  final first = items.first;
  final description = first is Map ? first['description'] : null;
  if (description is! String || description.isEmpty) return null;

  return items.length > 1 ? '$description (+${items.length - 1})' : description;
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

/// Une page de commandes, avec le total que le serveur en connaît.
///
/// Le total vient du serveur et non d'un comptage local : c'est lui qui dit
/// s'il reste quelque chose à charger. Sans lui, l'app ne peut pas distinguer
/// « dernière page » de « page pleine par coïncidence ».
class MerchantOrderPage {
  final List<MerchantOrder> orders;
  final int total;

  const MerchantOrderPage({required this.orders, required this.total});
}

/// Position d'un transporteur, avec sa fraîcheur.
///
/// [recordedAt] n'est pas décoratif : une position vieille d'une heure affichée
/// comme actuelle est pire qu'aucune position — le commerçant croirait son
/// transporteur immobile alors qu'il a simplement perdu le réseau. L'écran doit
/// dire quand le point a été relevé.
class DriverPosition extends Equatable {
  final double latitude;
  final double longitude;
  final DateTime? recordedAt;

  const DriverPosition({
    required this.latitude,
    required this.longitude,
    this.recordedAt,
  });

  factory DriverPosition.fromJson(Map<String, dynamic> json) => DriverPosition(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        recordedAt: json['recorded_at'] is String
            ? DateTime.tryParse(json['recorded_at'] as String)
            : null,
      );

  /// Ancienneté du relevé, en clair. `null` quand la date manque — on ne
  /// prétend alors pas savoir.
  String? get freshness {
    final at = recordedAt;
    if (at == null) return null;

    final delta = DateTime.now().difference(at);
    if (delta.inMinutes < 2) return 'à l\'instant';
    if (delta.inMinutes < 60) return 'il y a ${delta.inMinutes} min';
    if (delta.inHours < 24) return 'il y a ${delta.inHours} h';
    return 'position ancienne';
  }

  /// Au-delà de dix minutes, le point ne décrit plus où se trouve le
  /// transporteur mais où il se trouvait. L'écran doit le signaler plutôt que
  /// de laisser croire à un suivi en direct.
  bool get isStale =>
      recordedAt == null || DateTime.now().difference(recordedAt!).inMinutes > 10;

  @override
  List<Object?> get props => [latitude, longitude, recordedAt];
}

/// Évènement porté à la connaissance du commerçant.
///
/// Le serveur en est la mémoire : une notification non vue reste ici jusqu'à
/// ce que le commerçant l'ouvre. C'est ce qui distingue ce journal d'un push,
/// qui disparaît avec le téléphone éteint.
class MerchantNotification extends Equatable {
  final String id;
  final String type;
  final String title;
  final String body;

  /// Commande concernée, identifiant local — celui que le module commerçant
  /// sait résoudre. `null` pour une notification qui n'en vise aucune.
  final String? orderId;

  final bool read;
  final DateTime createdAt;

  const MerchantNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.read,
    required this.createdAt,
    this.orderId,
  });

  factory MerchantNotification.fromJson(Map<String, dynamic> json) =>
      MerchantNotification(
        id: (json['id'] ?? '') as String,
        type: (json['type'] ?? '') as String,
        title: (json['title'] ?? '') as String,
        body: (json['body'] ?? '') as String,
        orderId: json['order_id'] as String?,
        read: json['read'] == true,
        createdAt: readDate(json, 'created_at'),
      );

  @override
  List<Object?> get props => [id, read];
}

/// Le journal et son compte de non-lues, tels que le serveur les renvoie.
///
/// Le compte vient du serveur plutôt que d'un `where(...).length` local : la
/// liste est plafonnée, et compter sur une liste tronquée donnerait une
/// pastille fausse dès que le commerçant accumule des notifications.
class MerchantNotifications {
  final List<MerchantNotification> items;
  final int unread;

  const MerchantNotifications({required this.items, required this.unread});

  factory MerchantNotifications.fromJson(Map<String, dynamic> json) {
    final raw = json['data'];
    return MerchantNotifications(
      items: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(MerchantNotification.fromJson)
              .toList()
          : const [],
      unread: (json['unread'] as num?)?.toInt() ?? 0,
    );
  }
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

/// Devis renvoyé par le serveur.
///
/// [amount] est `null` tant que le barème n'est pas implémenté : l'écran
/// conserve alors la saisie manuelle du commerçant. Le jour où la formule
/// existe, il portera un montant et la saisie s'effacera — **sans changement
/// côté application**, c'est tout l'intérêt d'avoir posé l'appel avant la
/// formule.
class OrderQuote extends Equatable {
  final num? amount;
  final String currency;

  /// `merchant` = montant à saisir par le commerçant ; `computed` = tarif de la
  /// plateforme. Les deux ne se présentent pas de la même façon à l'écran.
  final String source;

  final int? distanceMetres;

  /// `haversine` = distance à vol d'oiseau, qui sous-estime la distance
  /// routière. À dire quand on l'affiche, plutôt que de laisser croire à une
  /// précision qu'elle n'a pas.
  final String? distanceMethod;

  const OrderQuote({
    this.amount,
    required this.currency,
    required this.source,
    this.distanceMetres,
    this.distanceMethod,
  });

  factory OrderQuote.fromJson(Map<String, dynamic> json) => OrderQuote(
        amount: json['amount'] as num?,
        currency: (json['currency'] ?? '') as String,
        source: (json['source'] ?? 'merchant') as String,
        distanceMetres: (json['distanceMetres'] as num?)?.round(),
        distanceMethod: json['distanceMethod'] as String?,
      );

  bool get isComputed => source == 'computed' && amount != null;

  String? get formattedAmount =>
      amount == null ? null : '${amount!.toStringAsFixed(0)} $currency'.trim();

  String? get approximateDistance => distanceMetres == null
      ? null
      : '${(distanceMetres! / 1000).toStringAsFixed(1)} km à vol d\'oiseau';

  @override
  List<Object?> get props => [amount, currency, source, distanceMetres];
}
