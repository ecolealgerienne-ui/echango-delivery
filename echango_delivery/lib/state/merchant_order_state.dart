import 'package:flutter/foundation.dart';

import '../errors/app_error.dart';
import '../errors/error_translator.dart';
import '../models/merchant_order.dart';
import '../services/bff_api_client.dart';
import 'locale_state.dart';

class MerchantOrderState extends ChangeNotifier {
  final BffApiClient _apiClient;
  final LocaleState _localeState;

  List<MerchantOrder> _orders = [];
  List<SavedAddress> _addresses = [];
  List<KnownDriver> _favourites = [];
  MerchantOrder? _selected;
  Map<String, dynamic>? _tracking;
  bool _isLoading = false;
  String? _errorMessage;

  MerchantOrderState({required BffApiClient apiClient, required LocaleState localeState})
      : _apiClient = apiClient,
        _localeState = localeState;

  /// Message d'erreur générique de la langue courante, pour les échecs qui ne
  /// portent aucun `code` serveur (erreur de parsing, exception inattendue).
  String get _genericError => translateErrorCode(AppError.unknown, _localeState.locale);

  List<MerchantOrder> get orders => _orders;
  List<MerchantOrder> get activeOrders => _matching.where((o) => !o.isFinished).toList();
  List<MerchantOrder> get pastOrders => _matching.where((o) => o.isFinished).toList();

  /// Recherche libre sur les commandes déjà chargées.
  ///
  /// ⚠️ **Locale, donc portant sur les pages chargées seulement.** Une
  /// recherche serveur serait plus juste, mais tout le filtrage du BFF est
  /// applicatif (Fleetbase ignore les filtres de requête) : elle imposerait de
  /// parcourir toute l'organisation à chaque frappe. Le bouton « charger plus »
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
    if (needle.isEmpty) return _orders;

    return _orders.where((o) {
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

  /// Transporteurs favoris. Sollicités en premier à la création d'une course,
  /// avec repli automatique sur le pool commun si aucun n'est disponible.
  List<KnownDriver> get favourites => _favourites;
  MerchantOrder? get selected => _selected;
  Map<String, dynamic>? get tracking => _tracking;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  static const _pageSize = 25;
  int _loadedPages = 1;
  int _totalOrders = 0;

  /// Reste-t-il des commandes à charger ?
  ///
  /// Le total vient du serveur : le comparer à ce qu'on a permet de distinguer
  /// « dernière page » de « page pleine par coïncidence ». Sans lui, l'app
  /// afficherait un bouton « charger plus » qui ne rapporte rien.
  bool get hasMoreOrders => _orders.length < _totalOrders;

  bool _loadingMore = false;
  bool get isLoadingMore => _loadingMore;

  Future<void> loadOrders() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final page = await _apiClient.getMerchantOrders(page: 1, limit: _pageSize);
      _orders = page.orders;
      _totalOrders = page.total;
      _loadedPages = 1;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
    } catch (e) {
      _errorMessage = _genericError;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Charge la page suivante et l'ajoute à la liste.
  ///
  /// L'app n'envoyait aucun paramètre de pagination : au-delà de 25
  /// livraisons, les plus anciennes devenaient inaccessibles sans que rien ne
  /// le signale. Une liste tronquée en silence n'est pas partielle — elle est
  /// fausse pour qui la lit comme complète.
  Future<void> loadMoreOrders() async {
    if (_loadingMore || !hasMoreOrders) return;

    _loadingMore = true;
    notifyListeners();
    try {
      final page = await _apiClient.getMerchantOrders(
        page: _loadedPages + 1,
        limit: _pageSize,
      );
      _orders = [..._orders, ...page.orders];
      _totalOrders = page.total;
      _loadedPages++;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
    } catch (e) {
      _errorMessage = _genericError;
    } finally {
      _loadingMore = false;
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
    } catch (_) {
      // Les favoris sont un confort : leur absence ne doit pas empêcher de
      // créer une course. On garde la liste précédente.
    }
    notifyListeners();
  }

  Future<bool> addFavourite(KnownDriver driver) async {
    try {
      await _apiClient.addFavouriteDriver(driver.driverUuid, name: driver.name);
      await loadFavourites();
      return true;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
      notifyListeners();
      return false;
    }
  }

  Future<bool> removeFavourite(String favouriteId) async {
    try {
      await _apiClient.removeFavouriteDriver(favouriteId);
      await loadFavourites();
      return true;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
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
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
    } catch (e) {
      _errorMessage = _genericError;
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
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
      notifyListeners();
      return null;
    } catch (_) {
      _errorMessage = _genericError;
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
      notifyListeners();
    } catch (_) {
      // On garde ce qu'on avait.
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

  Future<bool> createOrder(Map<String, dynamic> body) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _apiClient.createMerchantOrder(body);
      await loadOrders();
      return true;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
      return false;
    } catch (e) {
      _errorMessage = _genericError;
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> cancelOrder(String id) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _apiClient.cancelMerchantOrder(id);
      await loadOrders();
      if (_selected?.id == id || _selected?.publicId == id) {
        await selectOrder(id);
      }
      return true;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
      return false;
    } catch (e) {
      _errorMessage = _genericError;
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadAddresses() async {
    try {
      _addresses = await _apiClient.getMerchantAddresses();
      notifyListeners();
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
      notifyListeners();
    }
  }

  Future<bool> saveAddress({
    required String label,
    required String name,
    required String address,
    required double latitude,
    required double longitude,
    String? contactName,
    String? contactPhone,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _apiClient.saveMerchantAddress(
        label: label,
        name: name,
        address: address,
        latitude: latitude,
        longitude: longitude,
        contactName: contactName,
        contactPhone: contactPhone,
      );
      await loadAddresses();
      return true;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
      return false;
    } catch (e) {
      _errorMessage = _genericError;
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Modifie une adresse existante.
  ///
  /// Une adresse enregistrée pré-remplit chaque livraison qui la choisit : une
  /// erreur ne gêne pas une fois, elle se répète.
  Future<bool> updateAddress(
    String id, {
    required String label,
    required String name,
    required String address,
    required double latitude,
    required double longitude,
    String? contactName,
    String? contactPhone,
  }) =>
      _addressWrite(
        () => _apiClient.updateMerchantAddress(
          id,
          label: label,
          name: name,
          address: address,
          latitude: latitude,
          longitude: longitude,
          contactName: contactName,
          contactPhone: contactPhone,
        ),
      );

  Future<bool> deleteAddress(String id) => _addressWrite(
        () => _apiClient.deleteMerchantAddress(id),
      );

  /// Toute écriture sur le carnet est suivie d'une relecture : la liste est la
  /// seule vue de ce carnet, et la laisser périmée après une modification
  /// donnerait à croire que rien ne s'est passé.
  Future<bool> _addressWrite(Future<void> Function() action) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await action();
      await loadAddresses();
      return true;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
      return false;
    } catch (e) {
      _errorMessage = _genericError;
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
