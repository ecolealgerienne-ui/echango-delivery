import 'package:flutter/foundation.dart';

import '../errors/app_error.dart';
import '../models/order.dart';
import '../services/bff_api_client.dart';

class OrderState extends ChangeNotifier {
  final BffApiClient _apiClient;

  List<MerchantOrder> _orders = [];
  List<SavedAddress> _addresses = [];
  MerchantOrder? _selected;
  Map<String, dynamic>? _tracking;
  bool _isLoading = false;
  String? _errorMessage;

  OrderState({required BffApiClient apiClient}) : _apiClient = apiClient;

  List<MerchantOrder> get orders => _orders;
  List<MerchantOrder> get activeOrders =>
      _orders.where((o) => !o.isFinished).toList();
  List<MerchantOrder> get pastOrders =>
      _orders.where((o) => o.isFinished).toList();
  List<SavedAddress> get addresses => _addresses;
  MerchantOrder? get selected => _selected;
  Map<String, dynamic>? get tracking => _tracking;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> loadOrders() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _orders = await _apiClient.getOrders();
    } on AppException catch (e) {
      _errorMessage = e.message;
    } catch (e) {
      _errorMessage = 'Chargement des commandes impossible';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectOrder(String id) async {
    _isLoading = true;
    _errorMessage = null;
    _tracking = null;
    notifyListeners();
    try {
      _selected = await _apiClient.getOrder(id);
      // Le suivi n'existe pas tant que la commande n'est pas dispatchée :
      // son absence est normale, pas une erreur à remonter.
      try {
        _tracking = await _apiClient.getTracking(id);
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

  Future<bool> createOrder(Map<String, dynamic> body) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _apiClient.createOrder(body);
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
      await _apiClient.cancelOrder(id);
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
      _addresses = await _apiClient.getAddresses();
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
      await _apiClient.saveAddress(
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
