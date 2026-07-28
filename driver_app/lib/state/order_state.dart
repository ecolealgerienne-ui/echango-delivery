import 'package:flutter/foundation.dart';

import '../errors/app_error.dart';
import '../models/order.dart';
import '../services/bff_api_client.dart';

/// État de gestion des commandes pour le driver.
class OrderState extends ChangeNotifier {
  final BffApiClient _apiClient;

  List<Order> _orders = [];
  Order? _selectedOrder;
  bool _isLoading = false;
  String? _errorMessage;

  OrderState({required BffApiClient apiClient}) : _apiClient = apiClient;

  List<Order> get orders => _orders;
  Order? get selectedOrder => _selectedOrder;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  List<Order> get pendingOrders =>
      _orders.where((order) => order.isPending).toList();
  List<Order> get activeOrders =>
      _orders.where((order) => order.isInProgress).toList();
  List<Order> get completedOrders =>
      _orders.where((order) => order.isCompleted).toList();

  /// Charge les commandes du driver.
  ///
  /// [type] : 'assigned' (en cours), 'adhoc' (opportunités diffusées) ou
  /// 'history'. Le filtrage par driver est fait côté BFF, jamais par
  /// paramètre serveur — Fleetbase ignore les filtres non supportés et
  /// renverrait toute la compagnie.
  Future<void> loadOrders({String type = 'assigned'}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _orders = await _apiClient.getOrders(type: type);
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
