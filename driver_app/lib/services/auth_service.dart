import 'package:shared_preferences/shared_preferences.dart';
import 'package:logger/logger.dart';
import 'bff_client.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  late final SharedPreferences _prefs;
  late final BFFClient _bffClient;
  final Logger _logger = Logger();

  static const String _tokenKey = 'auth_token';
  static const String _driverIdKey = 'driver_id';
  static const String _driverEmailKey = 'driver_email';

  AuthService._internal() {
    _bffClient = BFFClient();
  }

  factory AuthService() {
    return _instance;
  }

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    final savedToken = _prefs.getString(_tokenKey);
    if (savedToken != null) {
      _bffClient.setAccessToken(savedToken);
    }
  }

  Future<bool> loginWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _bffClient.login(
        email: email,
        password: password,
      );

      final accessToken = response['data']['access_token'];
      final driverId = response['data']['driver']['id'];
      final driverEmail = response['data']['driver']['email'];

      await _prefs.setString(_tokenKey, accessToken);
      await _prefs.setString(_driverIdKey, driverId);
      await _prefs.setString(_driverEmailKey, driverEmail);

      _logger.i('Login successful for $email');
      return true;
    } catch (e) {
      _logger.e('Email login failed: $e');
      return false;
    }
  }

  Future<bool> loginWithPhone({
    required String phone,
  }) async {
    try {
      await _bffClient.loginWithPhone(phone: phone);
      _logger.i('OTP sent to $phone');
      return true;
    } catch (e) {
      _logger.e('Phone login request failed: $e');
      return false;
    }
  }

  Future<bool> verifyOtp({
    required String phone,
    required String otp,
  }) async {
    try {
      final response = await _bffClient.verifyOtp(
        phone: phone,
        otp: otp,
      );

      final accessToken = response['data']['access_token'];
      final driverId = response['data']['driver']['id'];
      final driverEmail = response['data']['driver']['email'];

      await _prefs.setString(_tokenKey, accessToken);
      await _prefs.setString(_driverIdKey, driverId);
      await _prefs.setString(_driverEmailKey, driverEmail);

      _logger.i('OTP verification successful for $phone');
      return true;
    } catch (e) {
      _logger.e('OTP verification failed: $e');
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await _bffClient.logout();
    } catch (e) {
      _logger.w('Logout API call failed: $e');
    } finally {
      await _prefs.remove(_tokenKey);
      await _prefs.remove(_driverIdKey);
      await _prefs.remove(_driverEmailKey);
      _bffClient.setAccessToken('');
    }
  }

  bool isAuthenticated() {
    return _bffClient.isAuthenticated() && _getStoredToken() != null;
  }

  String? getAccessToken() {
    return _getStoredToken();
  }

  String? getDriverId() {
    return _prefs.getString(_driverIdKey);
  }

  String? getDriverEmail() {
    return _prefs.getString(_driverEmailKey);
  }

  String? _getStoredToken() {
    return _prefs.getString(_tokenKey);
  }

  Future<bool> refreshToken() async {
    try {
      final response = await _bffClient.refreshToken();
      final newToken = response['data']['access_token'];
      await _prefs.setString(_tokenKey, newToken);
      return true;
    } catch (e) {
      _logger.e('Token refresh failed: $e');
      return false;
    }
  }
}
