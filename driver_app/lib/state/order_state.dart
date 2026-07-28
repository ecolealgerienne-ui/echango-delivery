import 'package:flutter/foundation.dart';

import '../errors/app_error.dart';
import '../models/order.dart';
import '../services/bff_api_client.dart';

/// État de gestion des commandes pour le driver.
class OrderState extends ChangeNotifier {
  final BffApiClient _apiClient;

  List<Order> _orders = [];
  List<Order> _adhocOrders = [];
  List<Order> _historyOrders = [];
  Order? _selectedOrder;
  List<Map<String, dynamic>> _nextActivities = [];
  bool _isLoading = false;
  String? _errorMessage;

  OrderState({required BffApiClient apiClient}) : _apiClient = apiClient;

  List<Order> get orders => _orders;
  Order? get selectedOrder => _selectedOrder;

  /// Transitions applicables à la commande sélectionnée, telles que résolues
  /// par le serveur contre l'OrderConfig et l'état courant.
  ///
  /// C'est la seule source légitime : le détail de commande ne contient
  /// aucune donnée d'activité (journal §6.9), et coder la machine à états
  /// côté client la ferait diverger de la configuration serveur.
  List<Map<String, dynamic>> get nextActivities => _nextActivities;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// Commandes assignées à ce driver et non terminées.
  List<Order> get activeOrders => _orders;

  /// Opportunités diffusées par le dispatch géospatial, pas encore réclamées
  /// (specs_app_transporteur.md §4.1). Elles ne sont assignées à personne :
  /// une vue filtrée sur les commandes du driver ne les montrerait jamais.
  List<Order> get adhocOrders => _adhocOrders;

  /// Commandes terminées ou annulées.
  List<Order> get historyOrders => _historyOrders;

  List<Order> get pendingOrders =>
      _orders.where((order) => order.isPending).toList();
  List<Order> get completedOrders => _historyOrders;

  /// Charge les trois catégories en un seul appel.
  ///
  /// Le BFF les renvoie ensemble sur `GET /transporteur/commandes` sans
  /// paramètre `type` — c'est ce qu'attend l'écran liste (§4.1). L'ancienne
  /// version ne demandait que `type=assigned` : les opportunités adhoc
  /// n'étaient donc jamais chargées, et l'écran restait vide tant qu'aucune
  /// commande n'était déjà assignée au driver.
  ///
  /// Le filtrage par driver est fait côté BFF, jamais par paramètre serveur —
  /// Fleetbase ignore les filtres non supportés et renverrait toute la
  /// compagnie (journal §2.8/§6.4).
  Future<void> loadOrders() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final buckets = await _apiClient.getOrderBuckets();
      _orders = buckets['active'] ?? [];
      _adhocOrders = buckets['adhoc'] ?? [];
      _historyOrders = buckets['history'] ?? [];
    } on AppException catch (e) {
      _errorMessage = e.message;
    } catch (e) {
      _errorMessage = 'Failed to load orders';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Charge les détails d'une commande.
  Future<void> selectOrder(String orderId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _selectedOrder = await _apiClient.getOrder(orderId);

      // Une commande adhoc non réclamée n'a pas de transition : elle doit
      // d'abord être acceptée. Interroger le serveur renverrait une erreur.
      if (_selectedOrder != null &&
          !(_selectedOrder!.adhoc && _selectedOrder!.driverId == null)) {
        try {
          _nextActivities = await _apiClient.getNextActivities(orderId);
        } catch (_) {
          // Transitions indisponibles : l'écran affiche le détail sans
          // action plutôt que d'échouer entièrement.
          _nextActivities = [];
        }
      } else {
        _nextActivities = [];
      }
    } on AppException catch (e) {
      _errorMessage = e.message;
    } catch (e) {
      _errorMessage = 'Failed to load order';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Accepte une commande.
  Future<bool> acceptOrder(String orderId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _apiClient.acceptOrder(orderId);
      // Mise à jour locale optimiste
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index >= 0) {
        _orders[index] = _orders[index].copyWith(status: 'accepted');
      }
      if (_selectedOrder?.id == orderId) {
        _selectedOrder = _selectedOrder?.copyWith(status: 'accepted');
      }
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Failed to accept order';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Démarre la livraison d'une commande.
  Future<bool> startOrder(String orderId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _apiClient.startOrder(orderId);
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index >= 0) {
        _orders[index] = _orders[index].copyWith(status: 'picked_up');
      }
      if (_selectedOrder?.id == orderId) {
        _selectedOrder = _selectedOrder?.copyWith(status: 'picked_up');
      }
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Failed to start delivery';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Applique une transition proposée par [nextActivities].
  ///
  /// [activity] doit être renvoyé tel quel : le serveur valide l'objet
  /// complet, pas son seul code.
  Future<bool> applyActivity(String orderId, Map<String, dynamic> activity) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _apiClient.updateActivity(orderId, activity);
      // Recharger : la transition change l'état ET les transitions suivantes.
      await selectOrder(orderId);
      await loadOrders();
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Impossible d\'appliquer cette étape';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Marque une commande comme livrée.
  ///
  /// [proofPhotoBase64] est optionnelle : quand elle est fournie, la preuve
  /// est envoyée d'abord, puis la commande est clôturée. L'ordre compte —
  /// une preuve attachée après clôture n'aurait plus de valeur probante.
  Future<bool> completeOrder({
    required String orderId,
    String? proofPhotoBase64,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      if (proofPhotoBase64 != null) {
        await _apiClient.captureProofPhoto(orderId, [proofPhotoBase64]);
      }
      await _apiClient.completeOrder(orderId);
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index >= 0) {
        _orders[index] = _orders[index].copyWith(status: 'completed');
      }
      if (_selectedOrder?.id == orderId) {
        _selectedOrder = _selectedOrder?.copyWith(status: 'completed');
      }
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Failed to complete order';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Rapporte un échec de livraison.
  Future<bool> reportDeliveryFailure({
    required String orderId,
    required String reason,
    String? photoBase64,
    String? notes,
    String? waypointUuid,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _apiClient.reportDeliveryFailure(
        orderId,
        reason: reason,
        notes: notes,
        waypointUuid: waypointUuid,
        photo: photoBase64,
      );
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index >= 0) {
        _orders[index] = _orders[index].copyWith(
          status: 'failed',
          deliveryFailure: DeliveryFailure(
            id: orderId,
            reason: reason,
            photoUrl: null,
            notes: notes,
            createdAt: DateTime.now(),
          ),
        );
      }
      if (_selectedOrder?.id == orderId) {
        _selectedOrder = _selectedOrder?.copyWith(
          status: 'failed',
          deliveryFailure: DeliveryFailure(
            id: orderId,
            reason: reason,
            photoUrl: null,
            notes: notes,
            createdAt: DateTime.now(),
          ),
        );
      }
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Failed to report delivery failure';
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

  void clearSelection() {
    _selectedOrder = null;
    notifyListeners();
  }
}
