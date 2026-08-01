import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../models/merchant_order.dart';
import '../services/bff_api_client.dart';
import 'locale_state.dart';
import 'write_envelope.dart';
import 'paged_list.dart';
import '../errors/error_message.dart';

class MerchantOrderState extends ChangeNotifier with WriteEnvelope {

  // Les trois lignes que `WriteEnvelope` demande : le mixin sait écrire les
  // champs sans les posséder, donc les autres références à `_isLoading` et
  // `_errorMessage` de cette classe ne bougent pas.
  @override
  set busy(bool value) => _isLoading = value;
  @override
  set failure(String? value) => _errorMessage = value;
  @override
  Locale get writeLocale => _localeState.locale;
  final BffApiClient _apiClient;
  final LocaleState _localeState;

  final PagedList<MerchantOrder> _ordersPage = PagedList<MerchantOrder>();
  List<SavedAddress> _addresses = [];
  List<KnownDriver> _favourites = [];
  MerchantOrder? _selected;
  Map<String, dynamic>? _tracking;
  bool _isLoading = false;
  String? _errorMessage;

  /// ⚠️ Le carnet a-t-il **échoué**, ou est-il vraiment vide ?
  ///
  /// [loadAddresses] avale son erreur pour ne pas faire remonter une exception
  /// nue, et laisse donc `_addresses` tel quel — c'est-à-dire vide au premier
  /// chargement. Sans ce drapeau, un commerçant dont le BFF est injoignable
  /// s'entend dire « aucune adresse enregistrée » alors qu'il en a dix, et le
  /// message est **définitif** : rien ne le recharge ensuite.
  ///
  /// Même forme que `FleetState.driversUnavailable`, et pour la même raison —
  /// une liste vide obtenue par échec ne se dit pas comme une liste vide.
  bool _addressesUnavailable = false;
  /// La lecture des favoris a-t-elle échoué ?
  ///
  /// ⚠️ Sans lui, l'écran affirmait « Aucun favori. Vos livraisons sont
  /// proposées à tout le réseau » — une phrase qui **décrit une politique de
  /// diffusion**, donc une affirmation forte, et fausse. Le commerçant croyait
  /// avoir perdu ses favoris et les ré-ajoutait.
  bool _favouritesUnavailable = false;
  /// Le relevé du journal a-t-il échoué ?
  ///
  /// ⚠️ Sur l'écran qui sert de substitut au push non branché, « Aucune
  /// notification » se lit « personne n'a pris ma course ».
  bool _notificationsUnavailable = false;

  MerchantOrderState({required BffApiClient apiClient, required LocaleState localeState})
      : _apiClient = apiClient,
        _localeState = localeState;

  /// Message d'erreur générique de la langue courante, pour les échecs qui ne
  /// portent aucun `code` serveur (erreur de parsing, exception inattendue).

  List<MerchantOrder> get orders => _ordersPage.items;
  List<MerchantOrder> get activeOrders => _matching.where((o) => !o.isFinished).toList();
  List<MerchantOrder> get pastOrders => _matching.where((o) => o.isFinished).toList();

  /// Recherche libre sur les commandes déjà chargées.
  ///
  /// ⚠️ **Locale, donc portant sur les pages chargées seulement.** Une
  /// recherche serveur serait plus juste, mais il n'en existe aucune sur les
  /// commandes : Fleetbase filtre bien par `customer`/`facilitator`/`driver`
  /// (la phrase « Fleetbase ignore les filtres de requête » qui figurait ici
  /// était fausse, corrigée le 29/07/2026), sans pour autant offrir de
  /// recherche libre — elle imposerait de parcourir toute l'organisation à
  /// chaque frappe. Le bouton « charger plus »
  /// étend le périmètre de recherche autant que la liste, ce qui rend la limite
  /// gérable — et l'écran le dit plutôt que de laisser croire à une recherche
  /// exhaustive.
  String _search = '';
  String get search => _search;

  void setSearch(String value) {
    _search = value;
    notifyListeners();
  }

  List<MerchantOrder> get _matching {
    final needle = _search.trim().toLowerCase();
    if (needle.isEmpty) return orders;

    return orders.where((o) {
      final haystack = [
        o.dropoff?.name,
        o.dropoff?.address,
        o.pickup?.name,
        o.trackingNumber,
        o.publicId,
        o.driverName,
      ].whereType<String>().join(' ').toLowerCase();
      return haystack.contains(needle);
    }).toList();
  }
  List<SavedAddress> get addresses => _addresses;
  bool get addressesUnavailable => _addressesUnavailable;
  bool get favouritesUnavailable => _favouritesUnavailable;
  bool get notificationsUnavailable => _notificationsUnavailable;

  /// Transporteurs favoris. Sollicités en premier à la création d'une course,
  /// avec repli automatique sur le pool commun si aucun n'est disponible.
  List<KnownDriver> get favourites => _favourites;
  MerchantOrder? get selected => _selected;
  Map<String, dynamic>? get tracking => _tracking;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// Reste-t-il des commandes à charger ?
  bool get hasMoreOrders => _ordersPage.hasMore;

  bool get isLoadingMore => _ordersPage.isLoadingMore;

  Future<void> loadOrders() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final page = await _apiClient.getMerchantOrders(
        page: 1,
        limit: _ordersPage.pageSize,
      );
      _ordersPage.reset(page.orders, page.total);
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Charge la page suivante et l'ajoute à la liste.
  ///
  /// L'app n'envoyait aucun paramètre de pagination : au-delà d'une page, les
  /// livraisons les plus anciennes devenaient inaccessibles sans que rien ne le
  /// signale. Une liste tronquée en silence n'est pas partielle — elle est
  /// fausse pour qui la lit comme complète.
  Future<void> loadMoreOrders() async {
    if (!_ordersPage.beginLoadMore()) return;
    notifyListeners();

    try {
      final page = await _apiClient.getMerchantOrders(
        page: _ordersPage.nextPage,
        limit: _ordersPage.pageSize,
      );
      _ordersPage.append(page.orders, page.total);
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
    } finally {
      _ordersPage.endLoadMore();
      notifyListeners();
    }
  }

  /// Dernière position connue du transporteur affecté à une commande.
  ///
  /// Renvoie `null` sans lever, dans les deux cas où l'absence est normale :
  /// personne n'est encore affecté, ou le transporteur n'a rien remonté. Une
  /// exception forcerait l'écran à traiter le cas courant comme une erreur.
  Future<DriverPosition?> loadDriverPosition(String orderId) async {
    try {
      return await _apiClient.getMerchantOrderPosition(orderId);
    } catch (_) {
      return null;
    }
  }

  Future<void> loadFavourites() async {
    try {
      _favourites = await _apiClient.getFavouriteDrivers();
      _favouritesUnavailable = false;
    } catch (_) {
      // Les favoris sont un confort : leur absence ne doit pas empêcher de
      // créer une course. On garde la liste précédente — MAIS on pose le
      // drapeau : sans lui, une liste jamais chargée se lit comme une liste
      // vide, et l'écran affirme une politique de diffusion au lieu d'un aveu.
      _favouritesUnavailable = true;
    }
    notifyListeners();
  }

  Future<bool> addFavourite(KnownDriver driver) async {
    try {
      await _apiClient.addFavouriteDriver(
        driver.driverUuid,
        name: driver.name,
        partyType: driver.partyType,
      );
      await loadFavourites();
      return true;
    } catch (e) {
      // ⚠️ `catch` et non `on AppException` : `addFavouriteDriver` appelle
      // `_httpClient` sans envelopper ses erreurs, donc un `SocketException`
      // traversait ce bloc sans être attrapé — l'écran restait muet et
      // l'exception remontait non gérée.
      _errorMessage = messageForError(e, _localeState.locale);
      notifyListeners();
      return false;
    }
  }

  Future<bool> removeFavourite(String favouriteId) async {
    try {
      await _apiClient.removeFavouriteDriver(favouriteId);
      await loadFavourites();
      return true;
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
      notifyListeners();
      return false;
    }
  }

  Future<void> selectOrder(String id) async {
    _isLoading = true;
    _errorMessage = null;
    _tracking = null;
    notifyListeners();
    try {
      _selected = await _apiClient.getMerchantOrder(id);
      // Le suivi n'existe pas tant que la commande n'est pas dispatchée :
      // son absence est normale, pas une erreur à remonter.
      try {
        _tracking = await _apiClient.getMerchantTracking(id);
      } catch (_) {
        _tracking = null;
      }
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearSelection() {
    _selected = null;
    _tracking = null;
  }

  /// Champs à reprendre pour recommencer une livraison identique.
  ///
  /// Renvoie `null` en cas d'échec plutôt que de lever : l'appelant ouvre alors
  /// le formulaire vide plutôt que rien du tout. Une duplication qui échoue
  /// doit dégrader vers la création manuelle, pas vers une impasse.
  Future<Map<String, dynamic>?> loadOrderTemplate(String id) async {
    try {
      return await _apiClient.getMerchantOrderTemplate(id);
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
      notifyListeners();
      return null;
    }
  }

  // ── Notifications ────────────────────────────────────────────────────────

  List<MerchantNotification> _notifications = [];
  int _unreadNotifications = 0;

  List<MerchantNotification> get notifications => _notifications;

  /// Compté par le serveur, pas dérivé de [notifications] : la liste est
  /// plafonnée côté serveur, et la compter ici donnerait une pastille fausse
  /// dès qu'un commerçant accumule les évènements.
  int get unreadNotifications => _unreadNotifications;

  /// Relève le journal. Silencieux en cas d'échec : les notifications sont un
  /// complément, et une erreur réseau ne doit pas masquer la liste des
  /// commandes, qui est la raison d'être de l'écran.
  Future<void> loadNotifications() async {
    try {
      final result = await _apiClient.getNotifications();
      _notifications = result.items;
      _unreadNotifications = result.unread;
      _notificationsUnavailable = false;
      notifyListeners();
    } catch (_) {
      // On garde ce qu'on avait — et on dit qu'on n'a pas pu savoir. « Aucune
      // notification » est une affirmation ; ne pas avoir pu relever n'en est
      // pas une.
      _notificationsUnavailable = true;
      notifyListeners();
    }
  }

  Future<void> markNotificationRead(String id) async {
    // Marquage local immédiat : le compte de non-lues est l'unique retour
    // visible du geste, et l'attendre du réseau donnerait l'impression que le
    // tapotement n'a pas été pris en compte.
    final index = _notifications.indexWhere((n) => n.id == id);
    if (index >= 0 && !_notifications[index].read) {
      final n = _notifications[index];
      _notifications[index] = MerchantNotification(
        id: n.id,
        type: n.type,
        title: n.title,
        body: n.body,
        orderId: n.orderId,
        read: true,
        createdAt: n.createdAt,
      );
      if (_unreadNotifications > 0) _unreadNotifications--;
      notifyListeners();
    }

    try {
      await _apiClient.markNotificationRead(id);
    } catch (_) {
      // L'écart local/serveur se résorbe au prochain relevé.
    }
  }

  Future<void> markAllNotificationsRead() async {
    try {
      await _apiClient.markAllNotificationsRead();
      await loadNotifications();
    } catch (_) {
      // Idem.
    }
  }

  /// Crée une commande et renvoie son identifiant local, ou `null` en cas
  /// d'échec.
  ///
  /// L'identifiant sert à ouvrir directement la fiche créée — un brouillon
  /// tout juste enregistré, en particulier, où le commerçant a un « Publier »
  /// à portée de main sans repasser par la liste.
  Future<String?> createOrder(Map<String, dynamic> body) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final response = await _apiClient.createMerchantOrder(body);
      await loadOrders();
      return response['id'] as String?;
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Publie un brouillon : déclenche le dispatch (favori ou pool commun).
  Future<bool> publishOrder(String id) =>
      _orderWrite(id, () => _apiClient.publishMerchantOrder(id));

  Future<bool> cancelOrder(String id) =>
      _orderWrite(id, () => _apiClient.cancelMerchantOrder(id));

  /// Écrire sur une commande, puis **relire la liste et la fiche ouverte**.
  ///
  /// La relecture n'est pas cosmétique : sans elle, l'écran de détail continue
  /// d'afficher l'état d'avant l'écriture, et le commerçant republie ou
  /// réannule une commande qui a déjà changé.
  ///
  /// ⚠️ `publishOrder` et `cancelOrder` étaient identiques à 98 % — même
  /// drapeau, même relecture, même traduction d'erreur, à un appel près. Le
  /// jour où la relecture change (ou disparaît), une copie oubliée laisse un
  /// écran périmé sans lever la moindre erreur.
  Future<bool> _orderWrite(String id, Future<void> Function() action) =>
      runWrite(action, reload: () async {
        await loadOrders();
        if (_selected?.id == id || _selected?.publicId == id) {
          await selectOrder(id);
        }
      });

  Future<void> loadAddresses() async {
    try {
      _addresses = await _apiClient.getMerchantAddresses();
      _addressesUnavailable = false;
      notifyListeners();
    } catch (e) {
      // Même raison : `getMerchantAddresses` ne passe pas par une enveloppe,
      // et un carnet illisible ne doit pas faire remonter une exception nue.
      //
      // ⚠️ Mais avaler l'erreur laisse `_addresses` vide, et un écran ne peut
      // pas distinguer « vous n'avez rien enregistré » de « je n'ai pas pu
      // lire ». Le drapeau porte cette différence ; sans lui l'écran affirme
      // la première, ce qui est faux et définitif.
      _addressesUnavailable = true;
      _errorMessage = messageForError(e, _localeState.locale);
      notifyListeners();
    }
  }

  /// Seuls [name] et [contactPhone] sont obligatoires (décision produit,
  /// 30/07/2026) : [address] et la position se complètent souvent après coup.
  Future<bool> saveAddress({
    required String label,
    required String name,
    String? address,
    String? neighborhood,
    String? city,
    String? district,
    String? province,
    String? postalCode,
    String? country,
    double? latitude,
    double? longitude,
    String? contactName,
    required String contactPhone,
    bool isDefault = false,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _apiClient.saveMerchantAddress(
        label: label,
        name: name,
        address: address,
        neighborhood: neighborhood,
        city: city,
        district: district,
        province: province,
        postalCode: postalCode,
        country: country,
        latitude: latitude,
        longitude: longitude,
        contactName: contactName,
        contactPhone: contactPhone,
        isDefault: isDefault,
      );
      await loadAddresses();
      return true;
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Modifie une adresse existante.
  ///
  /// Une adresse enregistrée pré-remplit chaque livraison qui la choisit : une
  /// erreur ne gêne pas une fois, elle se répète. Seuls [name] et
  /// [contactPhone] sont obligatoires, comme pour [saveAddress].
  Future<bool> updateAddress(
    String id, {
    required String label,
    required String name,
    String? address,
    String? neighborhood,
    String? city,
    String? district,
    String? province,
    String? postalCode,
    String? country,
    double? latitude,
    double? longitude,
    String? contactName,
    required String contactPhone,
    bool isDefault = false,
  }) =>
      _addressWrite(
        () => _apiClient.updateMerchantAddress(
          id,
          label: label,
          name: name,
          address: address,
          neighborhood: neighborhood,
          city: city,
          district: district,
          province: province,
          postalCode: postalCode,
          country: country,
          latitude: latitude,
          longitude: longitude,
          contactName: contactName,
          contactPhone: contactPhone,
          isDefault: isDefault,
        ),
      );

  Future<bool> deleteAddress(String id) => _addressWrite(
        () => _apiClient.deleteMerchantAddress(id),
      );

  /// Toute écriture sur le carnet est suivie d'une relecture : la liste est la
  /// seule vue de ce carnet, et la laisser périmée après une modification
  /// donnerait à croire que rien ne s'est passé.
  Future<bool> _addressWrite(Future<void> Function() action) =>
      runWrite(action, reload: loadAddresses);

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
