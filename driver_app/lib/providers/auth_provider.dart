import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/location_service.dart';

class AuthProvider extends ChangeNotifier {
  final _authService = AuthService();
  final _notificationService = NotificationService();
  final _locationService = LocationService();

  bool _isLoading = true;
  bool _isAuthenticated = false;
  String? _errorMessage;
  String? _driverEmail;

  bool get isLoading => _isLoading;
  bool get isAuthenticated => _isAuthenticated;
  String? get errorMessage => _errorMessage;
  String? get driverEmail => _driverEmail;

  AuthProvider() {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _authService.initialize();
      _isAuthenticated = _authService.isAuthenticated();
      _driverEmail = _authService.getDriverEmail();

      if (_isAuthenticated) {
        await _notificationService.subscribeToDriverNotifications();
        await _locationService.initialize();
      }
    } catch (e) {
      _errorMessage = 'Initialization failed: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> loginWithEmail({
    required String email,
    required String password,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final success = await _authService.loginWithEmail(
        email: email,
        password: password,
      );

      if (success) {
        _isAuthenticated = true;
        _driverEmail = email;
        await _notificationService.subscribeToDriverNotifications();
        await _locationService.initialize();
      } else {
        _errorMessage = 'Login failed';
      }

      return success;
    } catch (e) {
      _errorMessage = 'Login error: $e';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> loginWithPhone({
    required String phone,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final success = await _authService.loginWithPhone(phone: phone);
      if (!success) {
        _errorMessage = 'Failed to send OTP';
      }
      return success;
    } catch (e) {
      _errorMessage = 'Phone login error: $e';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> verifyOtp({
    required String phone,
    required String otp,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final success = await _authService.verifyOtp(
        phone: phone,
        otp: otp,
      );

      if (success) {
        _isAuthenticated = true;
        _driverEmail = _authService.getDriverEmail();
        await _notificationService.subscribeToDriverNotifications();
        await _locationService.initialize();
      } else {
        _errorMessage = 'OTP verification failed';
      }

      return success;
    } catch (e) {
      _errorMessage = 'OTP verification error: $e';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();

    try {
      await _notificationService.unsubscribeFromDriverNotifications();
      await _locationService.stopBackgroundTracking();
      await _authService.logout();
      _isAuthenticated = false;
      _driverEmail = null;
      _errorMessage = null;
    } catch (e) {
      _errorMessage = 'Logout error: $e';
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
