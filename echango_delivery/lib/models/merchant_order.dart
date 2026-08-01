import 'dart:ui' show Locale;

import 'package:equatable/equatable.dart';

import '../i18n/order_strings.dart';
import '../utils/dates.dart';
import 'cash.dart';
import 'fleetbase_json.dart';
// `DeliveryFailure` est partagé avec le transporteur : c'est le même
// signalement, vu des deux bouts. Une seconde classe pour le même JSON finirait
// par le lire de deux façons (revue archi #14).
import 'order.dart' show DeliveryFailure, Place;

/// Le mot affiché pour un statut de livraison, à un seul endroit.
///
/// ── Pourquoi une fonction et non une méthode ────────────────────────────────
///
/// Trois écrans du commerçant lisent un statut, et deux d'entre eux ne
/// manipulent pas de `MerchantOrder` — l'écran d'encaissement lit une livraison
/// attendue, qui n'a ni adresses ni colis. Recopier la table chez eux est
/// exactement ce que la règle 4 du projet interdit : « deux tables recopiées
/// ont affiché deux textes différents pour la même commande ».
///
/// [driverName] change un seul mot, et c'est le plus important : `dispatched`
/// se dit « Recherche transporteur » tant que personne n'a pris la course, et
/// « Transporteur affecté » dès que quelqu'un l'a prise. Fleetbase ne distingue
/// pas les deux dans son statut — c'est le second champ qui tranche.
/// ⚠️ **La locale est exigée, pas optionnelle** (31/07/2026). Ce libellé est
/// employé DANS une phrase de l'écran de caisse, désormais traduit — l'y
/// laisser en français aurait mis « Recherche transporteur » au milieu d'un
/// sous-titre arabe. Un paramètre facultatif valant « français » aurait laissé
/// chaque nouvel appelant réintroduire le cas sans que personne relise ; le
/// compilateur pose la question à chaque site.
///
/// Le repli sur `status` reste tel quel : un statut inconnu de Fleetbase n'a
/// pas de traduction et n'en aura pas — le montrer brut dit au moins de quoi il
/// s'agit, l'inventer non.
String orderStatusLabel(String status, Locale locale, {String? driverName}) {
  final ar = locale.languageCode == 'ar';
  return switch (status) {
    'created' => ar ? 'مسودة' : 'Brouillon',
    'dispatched' => driverName == null
        ? (ar ? 'البحث عن ناقل' : 'Recherche transporteur')
        : (ar ? 'تم تعيين ناقل' : 'Transporteur affecté'),
    'started' || 'enroute' => ar ? 'جارية' : 'En cours',
    'completed' => ar ? 'سُلّمت' : 'Livrée',
    'canceled' || 'cancelled' => ar ? 'أُلغيت' : 'Annulée',
    _ => status,
  };
}

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

  /// Précisions d'adresse saisies à la création (« Adresse » du formulaire).
  ///
  /// Elles vivent dans `meta.pickup_notes`/`meta.dropoff_notes` et non sur le
  /// `Place` : `createPlace` ne dépose que le nom, les coordonnées et le
  /// contact. Projetées depuis le début, elles n'étaient lues nulle part — un
  /// commerçant ne pouvait donc pas relire l'adresse qu'il avait tapée.
  final String? pickupNotes;
  final String? dropoffNotes;

  /// Contenu du colis, ligne par ligne, avec poids et fragilité.
  ///
  /// [packageContents] n'en donne qu'un résumé d'une ligne, utile en liste.
  /// La fiche, elle, doit pouvoir tout montrer : le poids et la mention
  /// fragile étaient saisis puis invisibles.
  final List<OrderItemLine> items;

  /// Les favoris ont-ils été sollicités en premier ?
  ///
  /// `null` sur les commandes créées avant que ce choix soit projeté.
  final bool? preferFavourites;

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

  /// Le montant à encaisser inclut-il les frais de livraison ?
  ///
  /// Purement informatif : le règlement avec le transporteur est le même dans
  /// les deux cas. Sert au commerçant à lire son chiffre d'affaires —
  /// marchandise = encaissé moins livraison, ou encaissé tout court.
  final bool codIncludesDelivery;

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
    this.pickupNotes,
    this.dropoffNotes,
    this.items = const [],
    this.preferFavourites,
    this.driverPhone,
    this.codAmount,
    this.codCurrency,
    this.codIncludesDelivery = false,
    this.cashCollection,
    this.deliveryFailures = const [],
  });

  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'canceled';
  bool get isFinished => isCompleted || isCancelled;

  /// Brouillon : enregistrée, pas encore publiée.
  ///
  /// **Le statut Fleetbase fait foi, et lui seul** (règle projet). Le drapeau
  /// `dispatched` existe aussi côté Fleetbase et dit « c'est parti », mais s'en
  /// servir ici ferait diverger l'app du garde-fou serveur, qui décide sur le
  /// statut : une commande jugée publiée d'un côté et republiable de l'autre.
  /// Un seul champ arbitre, des deux côtés.
  ///
  /// Conséquence assumée : une commande dont le dispatch a échoué à mi-chemin
  /// reste `created`, donc reste un brouillon republiable. C'est le
  /// comportement voulu — le réessai répare, là où un second état mémorisé
  /// bloquait définitivement.
  bool get isDraft => status == 'created';

  /// Publiée, en attente qu'un transporteur la prenne.
  bool get isWaitingDispatch => status == 'dispatched';

  bool get canCancel => !isFinished;

  /// Libellé métier, **seule** traduction du vocabulaire Fleetbase vers celui
  /// du commerçant.
  ///
  /// Les écrans lisent ce getter plutôt que de refaire leur propre table : la
  /// fiche affichait `created` brut là où la liste affichait « En attente »,
  /// pour la même commande. La table elle-même vit dans [orderStatusLabel],
  /// parce que l'écran d'encaissement en a besoin sans manipuler de commande.
  ///
  /// Rien n'est mémorisé ni dérivé : c'est de l'affichage.
  /// Le libellé du statut dans la langue courante.
  ///
  /// Méthode et non plus accesseur : la langue ne se devine pas depuis le
  /// modèle, elle vient de l'écran qui l'affiche.
  String statusLabel(Locale locale) =>
      orderStatusLabel(status, locale, driverName: driverName);

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
      pickupNotes: meta?['pickup_notes'] as String?,
      dropoffNotes: meta?['dropoff_notes'] as String?,
      items: meta?['items'] is List
          ? (meta!['items'] as List)
              .whereType<Map<String, dynamic>>()
              .map(OrderItemLine.fromJson)
              .toList()
          : const [],
      preferFavourites: meta?['prefer_favourites'] as bool?,
      price: meta?['price'] as num?,
      currency: meta?['currency'] as String?,
      codAmount: meta?['cod_amount'] as num?,
      codCurrency: meta?['cod_currency'] as String?,
      codIncludesDelivery: meta?['cod_includes_delivery'] == true,
      cashCollection: json['cash_collection'] is Map<String, dynamic>
          ? CashCollectionEntry.fromJson(
              json['cash_collection'] as Map<String, dynamic>)
          : null,
    );
  }

  @override
  List<Object?> get props => [id, publicId, status, dispatched, createdAt];
}

/// Une ligne de colis, telle que saisie à la création.
///
/// Le poids et la mention fragile étaient transmis au serveur depuis le lot du
/// 29/07 mais n'étaient réaffichés nulle part — le commerçant ne pouvait pas
/// vérifier ce qu'il avait déclaré, ni s'en servir en cas de litige.
class OrderItemLine extends Equatable {
  final String description;
  final int quantity;
  final num? weight;
  final bool fragile;

  const OrderItemLine({
    required this.description,
    this.quantity = 1,
    this.weight,
    this.fragile = false,
  });

  factory OrderItemLine.fromJson(Map<String, dynamic> json) => OrderItemLine(
        description: (json['description'] ?? '') as String,
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
        weight: json['weight'] as num?,
        fragile: json['fragile'] == true,
      );

  /// Une ligne lisible : « Gâteau · 2 kg · fragile ». Les parties absentes
  /// disparaissent au lieu d'afficher un tiret.
  ///
  /// `2×` reste littéral : c'est un signe, pas un mot, et il se lit dans les
  /// deux langues. `kg` et `fragile` non — ils étaient en français en dur au
  /// milieu d'une fiche par ailleurs traduite.
  String label(Locale locale) => [
        if (quantity > 1) '$quantity×',
        description,
        if (weight != null)
          orderLabel('order.item.weight', locale, {'weight': '$weight'}),
        if (fragile) orderLabel('order.item.fragile', locale),
      ].where((p) => p.isNotEmpty).join(' · ');

  @override
  List<Object?> get props => [description, quantity, weight, fragile];
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

  /// Adresse **telle que Fleetbase la recompose** : nom, rue, commune, code
  /// postal, pays concaténés. C'est un accesseur côté serveur, bon à afficher
  /// et impossible à réenregistrer.
  final String address;

  /// La rue seule, telle qu'elle a été saisie — le seul champ que le
  /// commerçant remplit lui-même, et donc le seul à remettre dans un
  /// formulaire de modification.
  ///
  /// ⚠️ Préremplir le champ « Adresse » avec [address] et le réenregistrer
  /// empilerait le nom du lieu devant la rue à chaque passage.
  final String street1;

  /// Composantes rendues par le géocodage inverse, chacune dans sa colonne.
  final String? neighborhood;
  final String? city;
  final String? district;
  final String? province;
  final String? postalCode;

  /// Code ISO-2 (`DZ`), pas un nom de pays.
  final String? country;
  final double latitude;
  final double longitude;
  final String? contactName;
  final String? contactPhone;

  /// Adresse principale du commerçant — préremplit le retrait à la création
  /// d'une nouvelle livraison. Une seule à la fois, imposé côté serveur.
  final bool isDefault;

  const SavedAddress({
    required this.id,
    required this.name,
    required this.address,
    this.street1 = '',
    this.neighborhood,
    this.city,
    this.district,
    this.province,
    this.postalCode,
    this.country,
    required this.latitude,
    required this.longitude,
    this.contactName,
    this.contactPhone,
    this.isDefault = false,
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
      street1: (json['street1'] ?? '') as String,
      neighborhood: json['neighborhood'] as String?,
      city: json['city'] as String?,
      district: json['district'] as String?,
      province: json['province'] as String?,
      postalCode: json['postal_code'] as String?,
      country: json['country'] as String?,
      latitude: coords?.latitude ?? 0,
      longitude: coords?.longitude ?? 0,
      contactName: json['contact_name'] as String?,
      contactPhone: json['phone'] as String? ?? json['contact_phone'] as String?,
      isDefault: json['is_default'] == true,
    );
  }

  /// L'adresse composée **par l'app**, à partir des colonnes réelles.
  ///
  /// ⚠️ Ne PAS utiliser [address] pour ça. C'est un accesseur calculé par
  /// Fleetbase, et son comportement observé ne correspond pas à son code :
  /// un lieu portant `street1: "test1"` renvoie `address: "BOULANGERIE
  /// TEST"`, le nom seul. Dépendre de lui, c'est afficher une adresse dont
  /// la composition est décidée en amont et peut changer à toute mise à jour.
  ///
  /// Ici chaque composante vient de sa colonne, sans redite : la wilaya n'est
  /// reprise que si elle diffère de la commune — à Alger les deux portent le
  /// même nom, et « Alger, Alger » se lit comme un défaut.
  String get composedAddress {
    final parts = <String>[
      if (street1.isNotEmpty) street1,
      if (neighborhood != null && neighborhood!.isNotEmpty) neighborhood!,
      // Le district porte le quartier connu — « Belcourt » — et non la daïra
      // quand les deux existent. C'est le nom par lequel on situe une adresse
      // à Alger, donc l'omettre appauvrissait la ligne plus que la wilaya.
      if (district != null && district!.isNotEmpty && district != neighborhood)
        district!,
      if (city != null && city!.isNotEmpty) city!,
      if (province != null && province!.isNotEmpty && province != city) province!,
      if (postalCode != null && postalCode!.isNotEmpty) postalCode!,
    ];
    return parts.join(', ');
  }

  /// `false` sur `(0, 0)` : depuis que la position est facultative à
  /// l'enregistrement (décision produit, 30/07/2026), c'est l'absence, pas un
  /// point valide au large du golfe de Guinée.
  bool get hasPosition => latitude != 0 || longitude != 0;

  @override
  List<Object?> get props => [id, name, address, latitude, longitude, isDefault];
}

/// Résultat de géocodage renvoyé par le BFF.
///
/// [label] peut être vide : Nominatim ne connaît pas tous les points — mer,
/// zone non cartographiée. La position reste utilisable par le dispatch, c'est
/// le libellé qui manque. L'écran doit donc accepter un point sans nom plutôt
/// que de refuser la sélection.
class GeocodedPlace extends Equatable {
  final String label;

  /// Ce qui désigne la porte : numéro, rue, quartier — calculé par le serveur.
  ///
  /// C'est ce qu'on propose dans le champ « Adresse », puisque commune,
  /// wilaya, code postal et pays ont chacun leur colonne côté Fleetbase.
  final String streetLabel;
  final double latitude;
  final double longitude;

  /// Composantes de l'adresse, telles que le géocodeur les a séparées.
  ///
  /// Enregistrées chacune dans sa colonne plutôt que concaténées : c'est ce
  /// qui rend une recherche par commune ou un tri par wilaya possibles, et ce
  /// qui évite de voir « Alger » deux fois dans une adresse recomposée.
  final String? street;
  final String? neighborhood;
  final String? district;
  final String? city;
  final String? province;
  final String? postalCode;

  /// Code ISO-2 en majuscules — `DZ`, jamais « Algérie ».
  final String? country;

  const GeocodedPlace({
    required this.label,
    required this.latitude,
    required this.longitude,
    this.streetLabel = '',
    this.street,
    this.neighborhood,
    this.district,
    this.city,
    this.province,
    this.postalCode,
    this.country,
  });

  factory GeocodedPlace.fromJson(Map<String, dynamic> json) => GeocodedPlace(
        label: (json['label'] ?? '') as String,
        streetLabel: (json['shortLabel'] ?? '') as String,
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
        street: json['street'] as String?,
        neighborhood: json['neighborhood'] as String?,
        district: json['district'] as String?,
        city: json['city'] as String?,
        province: json['province'] as String?,
        postalCode: json['postalCode'] as String?,
        country: json['country'] as String?,
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
  ///
  /// ── C'était un second formateur de durée, et il ne parlait que français ──
  ///
  /// Cette méthode portait sa propre échelle — « à l'instant », « il y a X min »,
  /// « il y a X h », « position ancienne » — c'est-à-dire une **copie** de
  /// [formatRelative], à trois mots près et sans arabe. Règle 5 : la question
  /// n'est pas si les deux se ressemblent, mais si l'une doit changer quand
  /// l'autre change. Reformuler « il y a » ici et pas là afficherait deux
  /// tournures pour la même idée dans la même application.
  ///
  /// ⚠️ **Un changement d'affichage assumé** : au-delà de 24 h, le texte était
  /// « position ancienne » et devient « il y a 2 j », puis la date au-delà
  /// d'une semaine. C'est plus précis, et l'information que le point est périmé
  /// n'est pas perdue — elle est portée par [isStale], qui grise le repère dès
  /// dix minutes. « Position ancienne » ne disait pas *à quel point*.
  String? freshness(Locale locale) {
    final at = recordedAt;
    if (at == null) return null;
    return formatRelative(at, locale);
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

  /// Les variables du message — nom du transporteur, numéro de suivi.
  ///
  /// ⚠️ `title` et `body` sont écrits **en français dans le code serveur** :
  /// l'écran ne les affiche qu'en repli d'un `type` inconnu. C'est `data` qui
  /// permet de reconstruire la phrase dans la langue de l'utilisateur, l'ordre
  /// des mots n'étant pas le même en arabe.
  final Map<String, String> data;

  const MerchantNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.read,
    required this.createdAt,
    this.orderId,
    this.data = const {},
  });

  factory MerchantNotification.fromJson(Map<String, dynamic> json) =>
      MerchantNotification(
        id: (json['id'] ?? '') as String,
        type: (json['type'] ?? '') as String,
        title: (json['title'] ?? '') as String,
        body: (json['body'] ?? '') as String,
        orderId: json['order_id'] as String?,
        data: {
          for (final e in ((json['data'] as Map?) ?? const {}).entries)
            if (e.value != null) '${e.key}': '${e.value}',
        },
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

  /// `driver` ou `fleet` — un transporteur, ou une entreprise de transport.
  ///
  /// ── Pourquoi le type doit voyager, et pas seulement l'uuid ───────────────
  ///
  /// `Driver` et `Vendor` sont **deux espaces d'identifiants distincts** chez
  /// Fleetbase : rien n'interdit qu'un uuid apparaisse dans les deux. C'est la
  /// raison pour laquelle l'unicité, côté serveur, porte sur le couple
  /// `(partyType, uuid)` et non sur l'uuid seul — et l'écran doit raisonner sur
  /// la même clé, sinon une entreprise en favori marquerait un conducteur
  /// homonyme comme « déjà en favori ».
  ///
  /// **`driver` par défaut** : c'est ce que valent toutes les réponses écrites
  /// avant que le serveur serve ce champ, et toutes celles d'un serveur plus
  /// ancien. Le défaut ne change donc le sens d'aucune donnée existante.
  final String partyType;

  bool get isFleet => partyType == 'fleet';

  /// Ce transporteur a-t-il installé l'application ?
  ///
  /// La recherche porte sur l'annuaire Fleetbase — celui que l'opérateur
  /// alimente — et un transporteur peut y figurer sans avoir encore créé son
  /// compte. Sans ce drapeau, le mettre en favori serait un geste **sans
  /// effet** : `pickAvailableFavourite` ne retient que ceux qui ont un compte,
  /// et le commerçant croirait sa préférence enregistrée.
  ///
  /// `true` par défaut : les listes qui ne renseignent pas ce champ — favoris,
  /// historique — ne décrivent que des transporteurs déjà actifs.
  final bool hasAccount;

  const KnownDriver({
    required this.driverUuid,
    this.name,
    this.favouriteId,
    this.hasAccount = true,
    this.partyType = 'driver',
  });

  factory KnownDriver.fromJson(Map<String, dynamic> json) => KnownDriver(
        driverUuid: (json['driver_uuid'] ?? '') as String,
        name: json['name'] as String?,
        favouriteId: json['id'] as String?,
        hasAccount: json['has_account'] == null || json['has_account'] == true,
        // Un type inconnu retombe sur `driver` plutôt que d'être propagé tel
        // quel : l'écran s'en sert pour choisir une icône et un libellé, et un
        // troisième type inattendu produirait une ligne muette.
        partyType: json['party_type'] == 'fleet' ? 'fleet' : 'driver',
      );

  /// La clé qui identifie cette partie **sans ambiguïté**.
  ///
  /// L'uuid seul ne suffit pas : voir [partyType]. Utilisée par l'écran des
  /// favoris pour savoir ce qui est déjà enregistré.
  String get partyKey => '$partyType:$driverUuid';

  /// Le nom affichable, avec un repli **traduit** quand il manque.
  ///
  /// ⚠️ La locale est exigée, comme pour `orderStatusLabel` et `vehicleLabel` :
  /// le repli produit des mots. La version précédente rendait « Transporteur
  /// 3f2a… » en français quelle que soit la langue — dette héritée que le
  /// balayage i18n du 01/08 avait manquée, et que le passage aux entreprises
  /// aurait doublée.
  String displayName(Locale locale) {
    if (name != null && name!.isNotEmpty) return name!;
    final short = driverUuid.substring(0, driverUuid.length.clamp(0, 8));
    return orderLabel(
      isFleet ? 'order.party.fleet.unnamed' : 'order.party.driver.unnamed',
      locale,
      {'id': short},
    );
  }

  @override
  List<Object?> get props => [partyType, driverUuid, name, favouriteId];
}

/// Résultat d'une recherche de transporteur.
///
/// [tooMany] distingue « aucun résultat » de « trop de résultats » : les deux
/// donnent une liste vide, et les confondre ferait conclure au commerçant que
/// la personne n'existe pas alors qu'il faut seulement préciser sa recherche.
class DriverSearchResult {
  final List<KnownDriver> drivers;
  final bool tooMany;

  const DriverSearchResult({required this.drivers, this.tooMany = false});
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
