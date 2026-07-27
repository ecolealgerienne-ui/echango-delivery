import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../errors/app_error.dart';
import '../models/order.dart';

const _tokenKey = 'echango_driver_token';

/// Client HTTP pour communiquer avec le BFF Echango Delivery.
/// Gère automatiquement l'authentification (token Bearer) et les erreurs.
class BffApiClient {
  final String baseUrl;
  final _storage = const FlutterSecureStorage();
  final http.Client _httpClient;

  String? _accessToken;

  BffApiClient({
    required this.baseUrl,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Restaure le token depuis le stockage sécurisé au démarrage de l'app.
  Future<void> restoreSession() async {
    _accessToken = await _storage.read(key: _tokenKey);
  }

  /// Stocke le token de manière sécurisée après authentification.
  Future<void> _saveToken(String token) async {
    _accessToken = token;
    await _storage.write(key: _tokenKey, value: token);
  }

  /// Efface la session (logout ou expiration).
  Future<void> clearSession() async {
    _accessToken = null;
    await _storage.delete(key: _tokenKey);
  }

  /// Ajoute le header Authorization avec le Bearer token.
  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (_accessToken != null) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    return headers;
  }

  /// Traite les réponses HTTP et mappe les erreurs.
  dynamic _parseResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    }

    if (response.statusCode == 401) {
      throw AppException(
        code: AppError.authSessionExpired,
        message: 'Session expired',
      );
    }

    if (response.statusCode == 404) {
      throw AppException(
        code: AppError.notFound,
        message: 'Resource not found',
      );
    }

    try {
      final data = jsonDecode(response.body);
      final errorCode = data['code'] ?? AppError.unknown;
      final errorMessage = data['message'] ?? data['error'] ?? 'An error occurred';
      throw AppException(
        code: errorCode,
        message: errorMessage,
      );
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.serverError,
        message: 'Server error (${response.statusCode})',
        originalError: e,
      );
    }
  }

  // Authentication endpoints

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: _buildHeaders(),
        body: jsonEncode({
          'email': email,
          'password': password,
        }),
      );
      final data = _parseResponse(response);
      if (data != null && data['data'] != null) {
        final token = data['data']['access_token'];
        await _saveToken(token);
      }
      return data ?? {};
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.networkError,
        message: 'Network error',
        originalError: e,
      );
    }
  }

  Future<Map<String, dynamic>> loginWithPhone({
    required String phone,
  }) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('$baseUrl/auth/login-phone'),
        headers: _buildHeaders(),
        body: jsonEncode({'phone': phone}),
      );
      return _parseResponse(response) ?? {};
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.networkError,
        message: 'Network error',
        originalError: e,
      );
    }
  }

  Future<Map<String, dynamic>> verifyOtp({
    required String phone,
    required String otp,
  }) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('$baseUrl/auth/verify-otp'),
        headers: _buildHeaders(),
        body: jsonEncode({
          'phone': phone,
          'otp': otp,
        }),
      );
      final data = _parseResponse(response);
      if (data != null && data['data'] != null) {
        final token = data['data']['access_token'];
        await _saveToken(token);
      }
      return data ?? {};
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.networkError,
        message: 'Network error',
        originalError: e,
      );
    }
  }

  Future<void> logout() async {
    try {
      await _httpClient.post(
        Uri.parse('$baseUrl/auth/logout'),
        headers: _buildHeaders(),
      );
    } finally {
      await clearSession();
    }
  }

  // Driver endpoints

  Future<Map<String, dynamic>> getDriver() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/driver/profile'),
      headers: _buildHeaders(),
    );
    return _parseResponse(response) ?? {};
  }

  Future<void> updateDriverLocation({
    required double latitude,
    required double longitude,
  }) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/driver/location'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'latitude': latitude,
        'longitude': longitude,
      }),
    );
    _parseResponse(response);
  }

  Future<void> updateDriverStatus(String status) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/driver/status'),
      headers: _buildHeaders(),
      body: jsonEncode({'status': status}),
    );
    _parseResponse(response);
  }

  // Order endpoints

  Future<List<Order>> getOrders({
    String status = 'assigned',
    int page = 1,
    int limit = 20,
  }) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/orders')
          .replace(queryParameters: {
        'status': status,
        'page': page.toString(),
        'limit': limit.toString(),
      }),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    if (data != null && data['data'] is List) {
      return (data['data'] as List)
          .map((order) => Order.fromJson(order as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<Order> getOrder(String orderId) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/orders/$orderId'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    if (data != null && data['data'] != null) {
      return Order.fromJson(data['data'] as Map<String, dynamic>);
    }
    throw AppException(code: AppError.orderNotFound);
  }

  Future<void> acceptOrder(String orderId) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/orders/$orderId/accept'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> startOrder(String orderId) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/orders/$orderId/start'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> completeOrder({
    required String orderId,
    required String proofUrl,
  }) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/orders/$orderId/complete'),
      headers: _buildHeaders(),
      body: jsonEncode({'proof_url': proofUrl}),
    );
    _parseResponse(response);
  }

  Future<void> reportDeliveryFailure({
    required String orderId,
    required String reason,
    String? photoUrl,
    String? notes,
  }) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/orders/$orderId/failure'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'reason': reason,
        'photo_url': photoUrl,
        'notes': notes,
      }),
    );
    _parseResponse(response);
  }

  bool isAuthenticated() => _accessToken != null;
}
