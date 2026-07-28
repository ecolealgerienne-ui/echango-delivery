import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../errors/app_error.dart';
import '../services/bff_api_client.dart';

enum SessionStatus { unauthenticated, authenticated }

const _emailKey = 'echango_merchant_email';
const _businessKey = 'echango_merchant_business';

class AuthState extends ChangeNotifier {
  final SharedPreferences _prefs;
  final BffApiClient _apiClient;

  SessionStatus _status = SessionStatus.unauthenticated;
  String? _email;
  String? _businessName;
  String? _errorMessage;
  bool _isLoading = false;

  AuthState({required SharedPreferences prefs, required BffApiClient apiClient})
      : _prefs = prefs,
        _apiClient = apiClient;

  SessionStatus get status => _status;
  bool get isAuthenticated => _status == SessionStatus.authenticated;
  String? get email => _email;
  String? get businessName => _businessName;
  String? get errorMessage => _errorMessage;
  bool get isLoading => _isLoading;

  Future<void> restoreSession() async {
    await _apiClient.restoreSession();
    _email = _prefs.getString(_emailKey);
    _businessName = _prefs.getString(_businessKey);
    if (_apiClient.isAuthenticated()) {
      _status = SessionStatus.authenticated;
    }
    notifyListeners();
  }

  Future<void> _persist(Map<String, dynamic> response, String email) async {
    // Réponse du BFF : {token, user:{...}} à plat, sans enveloppe `data`.
    final user = response['user'];
    _email = (user is Map ? user['email'] as String? : null) ?? email;
    _businessName = user is Map ? user['businessName'] as String? : null;
    await _prefs.setString(_emailKey, _email!);
    if (_businessName != null) {
      await _prefs.setString(_businessKey, _businessName!);
    }
    _status = SessionStatus.authenticated;
  }

  Future<bool> login({required String email, required String password}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final response = await _apiClient.login(email: email, password: password);
      await _persist(response, email);
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Connexion impossible';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> register({
    required String email,
    required String password,
    required String businessName,
    String? firstName,
    String? lastName,
    String? phone,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final response = await _apiClient.register(
        email: email,
        password: password,
        businessName: businessName,
        firstName: firstName,
        lastName: lastName,
        phone: phone,
      );
      await _persist(response, email);
      _businessName ??= businessName;
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Inscription impossible';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _apiClient.clearSession();
    _status = SessionStatus.unauthenticated;
    _errorMessage = null;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
