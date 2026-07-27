import 'package:flutter/material.dart';
import '../models/order.dart';
import '../services/bff_client.dart';

class OrderProvider extends ChangeNotifier {
  final _bffClient = BFFClient();

  List<Order> _orders = [];
  Order? _selectedOrder;
  bool _isLoading = false;
  String? _errorMessage;

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

  Future<void> loadOrders({String status = 'assigned'}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _orders = await _bffClient.getOrders(status: status);
    } catch (e) {
      _errorMessage = 'Failed to load orders: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectOrder(String orderId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _selectedOrder = await _bffClient.getOrder(orderId);
    } catch (e) {
      _errorMessage = 'Failed to load order details: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> acceptOrder(String orderId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _bffClient.acceptOrder(orderId);
      // Update local order status
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index >= 0) {
        _orders[index] = _orders[index].copyWith(status: 'accepted');
      }
      if (_selectedOrder?.id == orderId) {
        _selectedOrder = _selectedOrder?.copyWith(status: 'accepted');
      }
      return true;
    } catch (e) {
      _errorMessage = 'Failed to accept order: $e';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> startOrder(String orderId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _bffClient.startOrder(orderId);
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index >= 0) {
        _orders[index] = _orders[index].copyWith(status: 'picked_up');
      }
      if (_selectedOrder?.id == orderId) {
        _selectedOrder = _selectedOrder?.copyWith(status: 'picked_up');
      }
      return true;
    } catch (e) {
      _errorMessage = 'Failed to start order: $e';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> completeOrder({
    required String orderId,
    required String proofUrl,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _bffClient.completeOrder(
        orderId: orderId,
        proofUrl: proofUrl,
      );
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index >= 0) {
        _orders[index] = _orders[index].copyWith(
          status: 'completed',
          proofUrl: proofUrl,
        );
      }
      if (_selectedOrder?.id == orderId) {
        _selectedOrder = _selectedOrder?.copyWith(
          status: 'completed',
          proofUrl: proofUrl,
        );
      }
      return true;
    } catch (e) {
      _errorMessage = 'Failed to complete order: $e';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> reportDeliveryFailure({
    required String orderId,
    required String reason,
    String? photoUrl,
    String? notes,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _bffClient.reportDeliveryFailure(
        orderId: orderId,
        reason: reason,
        photoUrl: photoUrl,
        notes: notes,
      );
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index >= 0) {
        _orders[index] = _orders[index].copyWith(
          status: 'failed',
          deliveryFailure: DeliveryFailure(
            id: orderId,
            reason: reason,
            photoUrl: photoUrl,
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
            photoUrl: photoUrl,
            notes: notes,
            createdAt: DateTime.now(),
          ),
        );
      }
      return true;
    } catch (e) {
      _errorMessage = 'Failed to report delivery failure: $e';
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
