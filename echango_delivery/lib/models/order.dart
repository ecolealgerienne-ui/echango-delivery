import 'dart:ui' show Locale;

import 'package:equatable/equatable.dart';

import '../i18n/order_strings.dart';
import 'fleet_order_state.dart';
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

  /// L'uuid du `Place` de l'arrêt **en cours** d'une tournée, quand Fleetbase
  /// le suit (`payload.current_waypoint_uuid`). `null` avant le démarrage — on
  /// retombe alors sur le premier arrêt non honoré (voir [currentWaypoint]).
  final String? currentWaypointUuid;

  /// Les arrêts d'une **tournée** (spec §4), dans l'ordre. Vide pour une course
  /// 1→1 ordinaire.
  ///
  /// ── Additif, et pourquoi ─────────────────────────────────────────────────
  ///
  /// [pickupPlace] et [dropoffPlace] restent la façon de lire une course simple
  /// partout dans l'app. Sur une tournée, Fleetbase ne pose ni `payload.pickup`
  /// ni `payload.dropoff` : [Order.fromJson] les fait alors retomber sur le
  /// **premier** et le **dernier** arrêt, pour que les ~20 écrans qui lisent ces
  /// deux champs continuent d'afficher quelque chose de juste sans réécriture.
  /// Les écrans qui savent gérer N arrêts lisent [waypoints].
  final List<Waypoint> waypoints;

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
    this.waypoints = const [],
    this.currentWaypointUuid,
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

  /// Une tournée multi-arrêt : au moins deux waypoints (spec §4).
  bool get isTournee => waypoints.length >= 2;

  /// Les arrêts de livraison d'une tournée qui portent des espèces à percevoir.
  List<Waypoint> get cashStops =>
      waypoints.where((w) => (w.codAmount ?? 0) > 0).toList();

  /// L'arrêt d'une tournée sur lequel le conducteur travaille : celui que
  /// Fleetbase désigne ([currentWaypointUuid]), sinon le **premier non honoré**,
  /// sinon le dernier. `null` si ce n'est pas une tournée.
  Waypoint? get currentWaypoint {
    if (waypoints.isEmpty) return null;
    if (currentWaypointUuid != null) {
      for (final w in waypoints) {
        if (w.placeUuid == currentWaypointUuid) return w;
      }
    }
    for (final w in waypoints) {
      if (!w.complete) return w;
    }
    return waypoints.last;
  }

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
    List<Waypoint>? waypoints,
    String? currentWaypointUuid,
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
      waypoints: waypoints ?? this.waypoints,
      currentWaypointUuid: currentWaypointUuid ?? this.currentWaypointUuid,
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

    // ── Arrêts d'une tournée (spec §4) ───────────────────────────────────────
    //
    // Les espèces par arrêt vivent dans `meta.stop_cod_amounts`
    // (`[{place_uuid, amount}]`) ; les colis dans `payload.entities`, rattachés
    // par `destination_uuid` (l'uuid du `Place` de l'arrêt) et doublés par
    // `meta.stop_index`. On corrèle ici, une fois, plutôt que dans chaque écran.
    final stopCods = <String, num>{};
    final rawStopCods = meta?['stop_cod_amounts'];
    if (rawStopCods is List) {
      for (final entry in rawStopCods.whereType<Map>()) {
        final placeUuid = entry['place_uuid'];
        final amount = entry['amount'];
        if (placeUuid is String && amount is num) stopCods[placeUuid] = amount;
      }
    }

    // Ce qui a été déclaré perçu à chaque arrêt (`meta.stop_collections`).
    final stopCollected = <String, num>{};
    final rawStopCollections = meta?['stop_collections'];
    if (rawStopCollections is List) {
      for (final entry in rawStopCollections.whereType<Map>()) {
        final placeUuid = entry['place_uuid'];
        final amount = entry['collected_amount'];
        if (placeUuid is String && amount is num) {
          stopCollected[placeUuid] = amount;
        }
      }
    }

    final parcels =
        readEntitiesJson(json).map(TourneeParcel.fromJson).toList();

    final waypoints = <Waypoint>[];
    for (final wj in readWaypointsJson(json)) {
      final wpUuid = Waypoint.uuidOf(wj);
      final wpOrder = (wj['order'] as num?)?.toInt() ?? waypoints.length;
      final here = parcels
          .where((p) => p.destinationUuid != null
              ? p.destinationUuid == wpUuid
              : p.stopIndex == wpOrder)
          .toList();
      waypoints.add(Waypoint.fromJson(
        wj,
        codAmount: stopCods[wpUuid],
        collectedAmount: stopCollected[wpUuid],
        parcels: here,
      ));
    }
    waypoints.sort((a, b) => a.order.compareTo(b.order));

    final pickup = place('pickup') ??
        (waypoints.isNotEmpty ? waypoints.first.place : null);
    final dropoff = place('dropoff') ??
        (waypoints.isNotEmpty ? waypoints.last.place : null);

    final payloadJson = json['payload'];
    final currentWaypointUuid = payloadJson is Map<String, dynamic>
        ? payloadJson['current_waypoint_uuid'] as String?
        : null;

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
      pickupPlace: pickup,
      dropoffPlace: dropoff,
      waypoints: waypoints,
      currentWaypointUuid: currentWaypointUuid,
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
        waypoints,
        currentWaypointUuid,
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

/// Un arrêt d'une **tournée** (spec §4) : un lieu, sa position dans la route,
/// son avancement, les espèces à y percevoir et les colis qui y sont
/// déposés/collectés.
///
/// ── Ce qui vient d'où ─────────────────────────────────────────────────────
///
/// [place], [type], [order], [status], [complete] viennent de
/// `payload.waypoints[i]`. [codAmount] est rapproché depuis
/// `meta.stop_cod_amounts` par uuid de lieu (le `meta` de la commande n'a
/// qu'un `cod_amount` **cumulé**, qui sert au plafond de dette). [parcels]
/// vient de `payload.entities` filtré sur `destination_uuid`.
class Waypoint extends Equatable {
  final Place place;

  /// L'uuid du `Place` de l'arrêt, **brut** — la clé des mises à jour
  /// d'activité par arrêt (`getNextActivities(waypoint)` /
  /// `updateActivity(waypointUuid)`) et du rattachement des colis
  /// (`entity.destination_uuid`) et des espèces
  /// (`meta.stop_cod_amounts[].place_uuid`).
  ///
  /// ⚠️ Distinct de `place.id`, qui préfère `public_id` (règle de
  /// [readAnyId]) : l'amont corrèle sur l'`uuid`, pas sur le `public_id`.
  final String placeUuid;

  /// `pickup` (on y enlève) ou `dropoff` (on y livre). Le premier arrêt est un
  /// enlèvement, les suivants des livraisons — sauf composition explicite.
  final String type;

  /// Rang dans la route, à partir de 0.
  final int order;

  /// Statut Fleetbase de cet arrêt (`created`, `started`, `completed`…), ou
  /// `null` si l'amont ne le sert pas. Jamais figé en énumération, comme
  /// [Order.status].
  final String? status;

  /// L'arrêt a été honoré.
  final bool complete;

  /// Espèces à percevoir **à cet arrêt** — marchandise seule (la rémunération
  /// du conducteur est le prix unique de la tournée, réglé à part). `null` =
  /// pas d'encaissement ici.
  final num? codAmount;

  /// Ce que le conducteur a **déclaré avoir perçu** à cet arrêt
  /// (`meta.stop_collections`), une fois l'arrêt honoré. `null` tant que rien
  /// n'a été déclaré. Peut être `0` : un client qui refuse de payer est un fait.
  final num? collectedAmount;

  /// Les colis déposés ou collectés à cet arrêt.
  final List<TourneeParcel> parcels;

  const Waypoint({
    required this.place,
    required this.placeUuid,
    required this.type,
    required this.order,
    this.status,
    this.complete = false,
    this.codAmount,
    this.collectedAmount,
    this.parcels = const [],
  });

  bool get isPickup => type == 'pickup';

  /// L'uuid du `Place` d'un arrêt tel que l'amont l'expose — `uuid` en priorité
  /// (requête interne), `public_id` sinon.
  static String uuidOf(Map<String, dynamic> json) =>
      (json['uuid'] ?? json['public_id'] ?? json['id'] ?? '').toString();

  factory Waypoint.fromJson(
    Map<String, dynamic> json, {
    num? codAmount,
    num? collectedAmount,
    List<TourneeParcel> parcels = const [],
  }) {
    return Waypoint(
      place: Place.fromJson(json),
      placeUuid: uuidOf(json),
      type: (json['type'] ?? 'dropoff') as String,
      order: (json['order'] as num?)?.toInt() ?? 0,
      status: json['status'] as String?,
      complete: json['complete'] == true,
      codAmount: codAmount,
      collectedAmount: collectedAmount,
      parcels: parcels,
    );
  }

  @override
  List<Object?> get props => [
        place,
        placeUuid,
        type,
        order,
        status,
        complete,
        codAmount,
        collectedAmount,
        parcels,
      ];
}

/// Un colis d'une tournée (`payload.entities[i]`), rattaché à son arrêt par
/// [destinationUuid] (= [Waypoint.placeUuid]) ou, à défaut, par [stopIndex].
class TourneeParcel extends Equatable {
  final String id;
  final String name;
  final String? description;

  /// L'uuid du `Place` de l'arrêt de destination. `null` si l'amont ne le sert
  /// pas — on retombe alors sur [stopIndex].
  final String? destinationUuid;

  /// Rang de l'arrêt (0-based), déposé dans `meta.stop_index` à la création.
  final int? stopIndex;

  const TourneeParcel({
    required this.id,
    required this.name,
    this.description,
    this.destinationUuid,
    this.stopIndex,
  });

  factory TourneeParcel.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'];
    return TourneeParcel(
      id: readAnyId(json),
      name: (json['name'] ?? '') as String,
      description: json['description'] as String?,
      destinationUuid:
          (json['destination_uuid'] ?? json['destination']) as String?,
      stopIndex: meta is Map ? (meta['stop_index'] as num?)?.toInt() : null,
    );
  }

  @override
  List<Object?> get props =>
      [id, name, description, destinationUuid, stopIndex];
}

/// Les motifs d'échec de livraison, **dans l'ordre où on les propose**.
///
/// ── Pourquoi une liste de codes et une fonction de libellé, et non une map ──
///
/// Le code part au serveur, y est stocké et sera compté ; le libellé est de la
/// langue. Les mêler dans un seul objet fait itérer sur du français pour
/// construire un sélecteur — c'est le défaut corrigé le 31/07 sur
/// `cashDiscrepancyLabels`, reproduit ici à l'identique.
///
/// ⚠️ **Ils existaient en deux copies, et trois libellés sur six avaient
/// divergé** (01/08/2026) : `delivery_failure_screen` proposait « Client a
/// refusé le colis », « Accès impossible (site fermé, zone inaccessible) » et
/// « Autre » là où `order_detail_screen` affichait « Colis refusé par le
/// client », « Accès impossible » et « Autre motif ». Le conducteur déclarait
/// donc un motif et le commerçant en lisait un autre, pour le même code. C'est
/// exactement le défaut que ce projet a déjà payé (« deux tables recopiées ont
/// affiché deux textes différents pour la même commande »), et le critère de la
/// règle 5 tranche sans hésiter : si l'un change, l'autre doit changer.
///
/// La liste fermée est celle du BFF (`specs_app_transporteur.md` §4.3) — un
/// code absent de cette liste est refusé côté serveur en 400.
const List<String> deliveryFailureReasons = [
  'client_absent',
  'adresse_introuvable',
  'colis_refuse',
  'colis_endommage',
  'acces_impossible',
  'autre',
];

/// Le libellé d'un motif, dans la langue courante.
///
/// Un code inconnu est rendu **tel quel** plutôt que remplacé par un message
/// générique : si le serveur en introduit un, le voir à l'écran est le seul
/// moyen de s'en apercevoir.
String deliveryFailureLabel(String code, Locale locale) {
  final key = 'order.failure.$code';
  final label = orderLabel(key, locale);
  return label == key ? code : label;
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

/// Le libellé d'état d'une course, **pour le transporteur**.
///
/// ── Ce qui est partagé, et ce qui ne l'est pas ─────────────────────────────
///
/// La **décision** vient d'`orderStateKey`, écrite une seule fois et partagée
/// avec le profil entreprise : « dans quel état est cette course » est un
/// invariant, et une seconde copie divergerait sans bruit (règle 5).
///
/// Les **libellés** restent séparés, et le critère répond non : l'entreprise
/// parle d'un tiers (« Conducteur désigné — en attente de démarrage »), le
/// transporteur parle de lui-même (« À démarrer »). Si l'un change, l'autre n'a
/// aucune raison de changer.
///
/// ⚠️ Le repli sur le statut brut est **délibéré** : un statut Fleetbase que
/// cette version ne connaît pas n'a pas de traduction et n'en aura pas.
/// L'afficher tel quel dit au moins de quoi il s'agit ; lui inventer un libellé
/// rassurant affirmerait un fait qu'on ignore (règle 10).
String orderStateLabelForDriver(Order order, String Function(String) t) {
  final key = orderStateKey(
    status: order.status,
    // Une course servie au transporteur est la sienne dès qu'elle porte un
    // conducteur : `driverId` est le seul champ dont il dispose, et il suffit.
    hasDriver: order.driverId != null,
    adhoc: order.adhoc,
    // `dispatched` n'est pas projeté vers le transporteur : une course non
    // diffusée et non assignée n'apparaît de toute façon jamais dans sa liste.
    dispatched: false,
  );
  if (key == null) return order.status;
  return t('driver.state.${key.substring('fleet.state.'.length)}');
}
