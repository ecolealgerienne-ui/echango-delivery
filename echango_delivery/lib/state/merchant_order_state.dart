import 'package:flutter/foundation.dart';

import '../errors/app_error.dart';
import '../models/merchant_order.dart';
import '../services/bff_api_client.dart';

class MerchantOrderState extends ChangeNotifier {
  final BffApiClient _apiClient;

  List<MerchantOrder> _orders = [];
  List<SavedAddress> _addresses = [];
  List<KnownDriver> _favourites = [];
  MerchantOrder? _selected;
  Map<String, dynamic>? _tracking;
  bool _isLoading = false;
  String? _errorMessage;

  MerchantOrderState({required BffApiClient apiClient}) : _apiClient = apiClient;

  List<MerchantOrder> get orders => _orders;
  List<MerchantOrder> get activeOrders =>
      _orders.where((o) => !o.isFinished).toList();
  List<MerchantOrder> get pastOrders =>
      _orders.where((o) => o.isFinished).toList();
  List<SavedAddress> get addresses => _addresses;

  /// Transporteurs favoris. Sollicités en premier à la création d'une course,
  /// avec repli automatique sur le pool commun si aucun n'est disponible.
  List<KnownDriver> get favourites => _favourites;
  MerchantOrder? get selected => _selected;
  Map<String, dynamic>? get tracking => _tracking;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> loadOrders() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _orders = await _apiClient.getMerchantOrders();
    } on AppException catch (e) {
      _errorMessage = e.message;
    } catch (e) {
      _errorMessage = 'Chargement des commandes impossible';
    } finally {
      _isLoading = false;
      notifyListeners();
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
      _errorMessage = e.message;
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
      _errorMessage = e.message;
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
      _errorMessage = e.message;
    } catch (e) {
      _errorMessage = 'Commande introuvable';
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
      _errorMessage = e.message;
      notifyListeners();
      return null;
    } catch (_) {
      _errorMessage = 'Impossible de reprendre cette commande';
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
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Création de la commande impossible';
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
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Annulation impossible';
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
      _errorMessage = e.message;
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
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Enregistrement de l\'adresse impossible';
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
