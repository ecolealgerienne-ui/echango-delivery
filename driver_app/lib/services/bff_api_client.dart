import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

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

  /// Connexion email/mot de passe.
  ///
  /// Route réelle : POST /auth/transporteur/login (les endpoints driver sont
  /// préfixés `transporteur`, cf. backend/bff/src/auth/auth.controller.ts).
  /// Réponse réelle : {token, user:{id,email,firstName,lastName}} — à plat,
  /// sans enveloppe `data`, et la clé est `token` (pas `access_token`).
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('$baseUrl/auth/transporteur/login'),
        headers: _buildHeaders(),
        body: jsonEncode({
          'email': email,
          'password': password,
        }),
      );
      final data = _parseResponse(response);
      if (data != null && data['token'] != null) {
        await _saveToken(data['token']);
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

  /// ⚠️ NON IMPLÉMENTÉ CÔTÉ BFF au 28/07/2026 — cet appel renverra 404.
  /// La connexion par téléphone/OTP est bien au périmètre spec
  /// (specs_app_transporteur.md §2), mais son arbitrage MVP vs V2 fait partie
  /// des questions encore ouvertes (§13). Seule la connexion email/mot de
  /// passe a une contrepartie serveur aujourd'hui.
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

  /// ⚠️ NON IMPLÉMENTÉ CÔTÉ BFF au 28/07/2026 — voir [loginWithPhone].
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

  /// ⚠️ Pas de route /auth/logout côté BFF (auth JWT sans état, rien à
  /// invalider serveur). L'appel échouera silencieusement — le `finally`
  /// efface la session locale, qui est le seul effet réellement nécessaire.
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

  /// Enregistre le jeton push FCM/APN de cet appareil auprès du BFF, qui le
  /// répercute côté Fleetbase (UserDevice) pour que le dispatch natif
  /// (`OrderPing`) puisse atteindre l'appareil.
  ///
  /// À appeler après authentification (route protégée par JWT) et à chaque
  /// rafraîchissement du jeton par Firebase (`onTokenRefresh`).
  Future<Map<String, dynamic>> registerDeviceToken({
    required String token,
    required String platform, // 'ios' ou 'android'
  }) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('$baseUrl/auth/transporteur/device-token'),
        headers: _buildHeaders(),
        body: jsonEncode({'token': token, 'platform': platform}),
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

  // ───────────────────────────────────────────────────────────────────────
  // ⚠️ TOUT CE QUI SUIT EST NON IMPLÉMENTÉ CÔTÉ BFF au 28/07/2026.
  //
  // Ces méthodes ont été écrites au scaffolding contre une API supposée, pas
  // contre l'API réelle : le module `transporteur` du BFF (dashboard,
  // commandes, statuts, POD, échec de livraison — specs_app_transporteur.md
  // §3-5) reste à construire. Les chemins et les formes de payload ci-dessous
  // sont donc à considérer comme des placeholders, à réaligner sur le serveur
  // une fois le module écrit — comme il a fallu le faire pour login().
  //
  // Seule la tranche auth email/mot de passe est fonctionnelle aujourd'hui.
  // ───────────────────────────────────────────────────────────────────────

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
