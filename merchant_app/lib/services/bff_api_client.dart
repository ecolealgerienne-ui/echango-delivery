import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../errors/app_error.dart';
import '../models/order.dart';

const _tokenKey = 'echango_merchant_token';

/// Client HTTP du BFF, côté commerçant.
///
/// Les chemins sont alignés sur `backend/bff/src/commercant/` — lus dans le
/// code du contrôleur, pas supposés.
class BffApiClient {
  final String baseUrl;
  final _storage = const FlutterSecureStorage();
  final http.Client _httpClient;

  String? _accessToken;

  BffApiClient({required this.baseUrl, http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  Future<void> restoreSession() async {
    _accessToken = await _storage.read(key: _tokenKey);
  }

  /// Présence d'un jeton, pas sa validité : une expiration ne se révèle qu'au
  /// premier appel réel (401 → session expirée).
  bool isAuthenticated() => _accessToken != null && _accessToken!.isNotEmpty;

  Future<void> _saveToken(String token) async {
    _accessToken = token;
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<void> clearSession() async {
    _accessToken = null;
    await _storage.delete(key: _tokenKey);
  }

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };

  /// Nomme la cause probable plutôt qu'un « Network error » nu : les trois
  /// pannes courantes en développement ont des messages Dart peu parlants.
  String _networkErrorMessage(Object e) {
    final raw = e.toString();
    if (raw.contains('CLEARTEXT')) {
      return 'HTTP en clair bloqué par Android. Ajouter '
          'android:usesCleartextTraffic="true" au manifeste (dev uniquement).';
    }
    if (raw.contains('Connection refused') || raw.contains('Failed host lookup')) {
      return 'BFF injoignable à $baseUrl. Sur émulateur utiliser 10.0.2.2, '
          'sur téléphone l\'IP LAN de la machine — jamais localhost.';
    }
    return 'Erreur réseau : $raw';
  }

  dynamic _parse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response.body.isEmpty ? null : jsonDecode(response.body);
    }
    if (response.statusCode == 401) {
      throw AppException(code: AppError.authSessionExpired, message: 'Session expirée');
    }
    try {
      final data = jsonDecode(response.body);
      final message = data['message'] ?? data['error'] ?? 'Une erreur est survenue';
      throw AppException(
        code: (data['code'] ?? AppError.unknown) as String,
        // Nest renvoie `message` en tableau pour les erreurs de validation :
        // les concaténer plutôt que d'afficher une liste brute.
        message: message is List ? message.join('\n') : message.toString(),
      );
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.serverError,
        message: 'Erreur serveur (${response.statusCode})',
        originalError: e,
      );
    }
  }

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.networkError,
        message: _networkErrorMessage(e),
        originalError: e,
      );
    }
  }

  // ── Authentification ───────────────────────────────────────────────────

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) =>
      _guard(() async {
        final response = await _httpClient.post(
          Uri.parse('$baseUrl/auth/merchant/login'),
          headers: _headers(),
          body: jsonEncode({'email': email, 'password': password}),
        );
        final data = _parse(response);
        if (data != null && data['token'] != null) {
          await _saveToken(data['token'] as String);
        }
        return (data ?? <String, dynamic>{}) as Map<String, dynamic>;
      });

  /// L'inscription CRÉE un Vendor et un Contact côté Fleetbase — contrairement
  /// au driver, qui se rattache à un enregistrement existant.
  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String businessName,
    String? firstName,
    String? lastName,
    String? phone,
  }) =>
      _guard(() async {
        final response = await _httpClient.post(
          Uri.parse('$baseUrl/auth/merchant/register'),
          headers: _headers(),
          body: jsonEncode({
            'email': email,
            'password': password,
            'businessName': businessName,
            if (firstName != null && firstName.isNotEmpty) 'firstName': firstName,
            if (lastName != null && lastName.isNotEmpty) 'lastName': lastName,
            if (phone != null && phone.isNotEmpty) 'phone': phone,
          }),
        );
        final data = _parse(response);
        if (data != null && data['token'] != null) {
          await _saveToken(data['token'] as String);
        }
        return (data ?? <String, dynamic>{}) as Map<String, dynamic>;
      });

  // ── Commandes ──────────────────────────────────────────────────────────

  List<T> _list<T>(dynamic data, String key, T Function(Map<String, dynamic>) build) {
    final raw = (data is Map) ? (data[key] ?? data['data'] ?? data) : data;
    if (raw is! List) return <T>[];
    return raw.whereType<Map<String, dynamic>>().map(build).toList();
  }

  Future<List<MerchantOrder>> getOrders() => _guard(() async {
        final response = await _httpClient.get(
          Uri.parse('$baseUrl/commercant/commandes'),
          headers: _headers(),
        );
        return _list(_parse(response), 'orders', MerchantOrder.fromJson);
      });

  Future<MerchantOrder> getOrder(String id) => _guard(() async {
        final response = await _httpClient.get(
          Uri.parse('$baseUrl/commercant/commandes/$id'),
          headers: _headers(),
        );
        final data = _parse(response);
        final map = (data is Map && data['order'] is Map) ? data['order'] : data;
        return MerchantOrder.fromJson(map as Map<String, dynamic>);
      });

  Future<Map<String, dynamic>> getTracking(String id) => _guard(() async {
        final response = await _httpClient.get(
          Uri.parse('$baseUrl/commercant/commandes/$id/suivi'),
          headers: _headers(),
        );
        return (_parse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
      });

  Future<Map<String, dynamic>> createOrder(Map<String, dynamic> body) =>
      _guard(() async {
        final response = await _httpClient.post(
          Uri.parse('$baseUrl/commercant/commandes'),
          headers: _headers(),
          body: jsonEncode(body),
        );
        return (_parse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
      });

  Future<void> cancelOrder(String id) => _guard(() async {
        final response = await _httpClient.post(
          Uri.parse('$baseUrl/commercant/commandes/$id/annuler'),
          headers: _headers(),
        );
        _parse(response);
      });

  // ── Carnet d'adresses ──────────────────────────────────────────────────

  Future<List<SavedAddress>> getAddresses() => _guard(() async {
        final response = await _httpClient.get(
          Uri.parse('$baseUrl/commercant/adresses'),
          headers: _headers(),
        );
        return _list(_parse(response), 'places', SavedAddress.fromJson);
      });

  Future<void> saveAddress({
    required String label,
    required String name,
    required String address,
    required double latitude,
    required double longitude,
    String? contactName,
    String? contactPhone,
  }) =>
      _guard(() async {
        final response = await _httpClient.post(
          Uri.parse('$baseUrl/commercant/adresses'),
          headers: _headers(),
          body: jsonEncode({
            'label': label,
            'name': name,
            'address': address,
            'latitude': latitude,
            'longitude': longitude,
            if (contactName != null && contactName.isNotEmpty) 'contactName': contactName,
            if (contactPhone != null && contactPhone.isNotEmpty) 'contactPhone': contactPhone,
          }),
        );
        _parse(response);
      });
}
