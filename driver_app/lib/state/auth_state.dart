import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../errors/app_error.dart';
import '../services/bff_api_client.dart';

enum SessionStatus { unauthenticated, authenticated, sessionExpired }

const _statusPrefsKey = 'echango_driver_session_status';
const _driverIdPrefsKey = 'echango_driver_id';
const _driverEmailPrefsKey = 'echango_driver_email';
const _lastActivityPrefsKey = 'echango_driver_last_activity';

/// Session expirée après 24h d'inactivité — vérifiée côté client
/// (app relancée/reprise au premier plan) en complément du
/// durcissement serveur.
const sessionInactivityLimit = Duration(hours: 24);

/// État de session local du driver. Utilisé pour piloter la navigation
/// (routes publiques vs dashboard). ChangeNotifier pour être passé en
/// refreshListenable à GoRouter (redirection auto sur changement d'état).
class AuthState extends ChangeNotifier {
  final SharedPreferences _prefs;
  final BffApiClient _apiClient;

  SessionStatus _status;
  String? _driverId;
  String? _driverEmail;
  String? _errorMessage;
  bool _isLoading = false;

  AuthState({
    required SharedPreferences prefs,
    required BffApiClient apiClient,
  })  : _prefs = prefs,
        _apiClient = apiClient,
        _status = _statusFromString(prefs.getString(_statusPrefsKey));

  SessionStatus get status => _status;
  String? get driverId => _driverId;
  String? get driverEmail => _driverEmail;
  String? get errorMessage => _errorMessage;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _status == SessionStatus.authenticated;
  bool get isSessionExpired => _status == SessionStatus.sessionExpired;

  /// Restaure la session au démarrage de l'app.
  Future<void> restoreSession() async {
    _driverId = _prefs.getString(_driverIdPrefsKey);
    _driverEmail = _prefs.getString(_driverEmailPrefsKey);
    await _apiClient.restoreSession();
    if (_apiClient.isAuthenticated()) {
      _status = SessionStatus.authenticated;
      checkInactivity();
    }
    notifyListeners();
  }

  /// Vérifie l'inactivité et expire la session si nécessaire.
  void checkInactivity() {
    final lastActivityStr = _prefs.getString(_lastActivityPrefsKey);
    if (lastActivityStr == null) {
      touchActivity();
      return;
    }

    try {
      final lastActivity = DateTime.parse(lastActivityStr);
      final now = DateTime.now();
      if (now.difference(lastActivity) > sessionInactivityLimit) {
        expireSession();
      }
    } catch (e) {
      touchActivity();
    }
  }

  /// Enregistre l'heure de la dernière activité.
  void touchActivity() {
    _prefs.setString(_lastActivityPrefsKey, DateTime.now().toIso8601String());
  }

  /// Connexion par email/password.
  Future<bool> loginWithEmail({
    required String email,
    required String password,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _apiClient.login(email: email, password: password);
      final driver = response['data']['driver'];
      _driverId = driver['id'];
      _driverEmail = driver['email'];

      await _prefs.setString(_driverIdPrefsKey, _driverId!);
      await _prefs.setString(_driverEmailPrefsKey, _driverEmail!);

      _setStatus(SessionStatus.authenticated);
      touchActivity();
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Login failed';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Initie la connexion par OTP (demande du code).
  Future<bool> loginWithPhone({required String phone}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _apiClient.loginWithPhone(phone: phone);
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Failed to send OTP';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Vérifie le code OTP et authentifie.
  Future<bool> verifyOtp({
    required String phone,
    required String otp,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _apiClient.verifyOtp(phone: phone, otp: otp);
      final driver = response['data']['driver'];
      _driverId = driver['id'];
      _driverEmail = driver['email'];

      await _prefs.setString(_driverIdPrefsKey, _driverId!);
      await _prefs.setString(_driverEmailPrefsKey, _driverEmail!);

      _setStatus(SessionStatus.authenticated);
      touchActivity();
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'OTP verification failed';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Logout complet (efface tous les données).
  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();

    try {
      await _apiClient.logout();
    } catch (e) {
      // Logout échoue : efface quand même localement
    } finally {
      _driverId = null;
      _driverEmail = null;
      _errorMessage = null;
      await _prefs.remove(_driverIdPrefsKey);
      await _prefs.remove(_driverEmailPrefsKey);
      await _prefs.remove(_lastActivityPrefsKey);
      _setStatus(SessionStatus.unauthenticated);
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Session expirée : conserve l'email du driver pour ré-authentification rapide.
  void expireSession() {
    _setStatus(SessionStatus.sessionExpired);
    notifyListeners();
  }

  void _setStatus(SessionStatus newStatus) {
    _status = newStatus;
    _prefs.setString(_statusPrefsKey, _statusToString(newStatus));
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}

SessionStatus _statusFromString(String? value) {
  switch (value) {
    case 'authenticated':
      return SessionStatus.authenticated;
    case 'sessionExpired':
      return SessionStatus.sessionExpired;
    default:
      return SessionStatus.unauthenticated;
  }
}

String _statusToString(SessionStatus status) {
  switch (status) {
    case SessionStatus.authenticated:
      return 'authenticated';
    case SessionStatus.sessionExpired:
      return 'sessionExpired';
    default:
      return 'unauthenticated';
  }
}
