import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../errors/app_error.dart';
import '../models/order.dart';
import '../models/merchant_order.dart';

const _tokenKey = 'echango_session_token';

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

  /// Un jeton est-il présent en mémoire ?
  ///
  /// Ne dit rien de sa validité : le BFF signe des JWT expirables, et seul un
  /// appel réel révèle une expiration (traitée en 401 → [AppError
  /// .authSessionExpired] par [_parseResponse]). Sert uniquement à décider,
  /// au démarrage, s'il vaut la peine de restaurer la session plutôt que
  /// d'afficher l'écran de connexion.
  bool isAuthenticated() => _accessToken != null && _accessToken!.isNotEmpty;

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

  /// Rend une erreur réseau diagnosticable depuis l'écran, sans avoir à
  /// brancher un debugger. Les trois causes courantes sur un poste de dev ont
  /// des symptômes distincts mais des messages Dart peu parlants.
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
        // Le détail sous-jacent, pas un « Network error » nu : c'est presque
        // toujours une adresse injoignable (localhost pointe sur l'appareil,
        // pas sur la machine de dev) ou du HTTP en clair bloqué par Android.
        // Sans ce texte, les trois causes sont indiscernables à l'écran.
        message: _networkErrorMessage(e),
        originalError: e,
      );
    }
  }

  /// Inscription transporteur, sur invitation d'un opérateur.
  ///
  /// Le driver visé est porté par le jeton d'invitation, plus par la requête :
  /// l'ancienne version laissait l'appelant désigner n'importe quel
  /// `driverUuid`, ce qui permettait de s'enregistrer à la place d'un vrai
  /// transporteur (revue de sécurité C2).
  Future<Map<String, dynamic>> registerDriverWithInvitation({
    required String invitationToken,
    required String email,
    required String password,
    String? firstName,
    String? lastName,
    String? phone,
  }) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('$baseUrl/auth/transporteur/register'),
        headers: _buildHeaders(),
        body: jsonEncode({
          'invitationToken': invitationToken,
          'email': email,
          'password': password,
          if (firstName != null && firstName.isNotEmpty) 'firstName': firstName,
          if (lastName != null && lastName.isNotEmpty) 'lastName': lastName,
          if (phone != null && phone.isNotEmpty) 'phone': phone,
        }),
      );
      final data = _parseResponse(response);
      if (data != null && data['token'] != null) {
        await _saveToken(data['token'] as String);
      }
      return (data ?? <String, dynamic>{}) as Map<String, dynamic>;
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.networkError,
        message: _networkErrorMessage(e),
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
        // Le détail sous-jacent, pas un « Network error » nu : c'est presque
        // toujours une adresse injoignable (localhost pointe sur l'appareil,
        // pas sur la machine de dev) ou du HTTP en clair bloqué par Android.
        // Sans ce texte, les trois causes sont indiscernables à l'écran.
        message: _networkErrorMessage(e),
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
        // Le détail sous-jacent, pas un « Network error » nu : c'est presque
        // toujours une adresse injoignable (localhost pointe sur l'appareil,
        // pas sur la machine de dev) ou du HTTP en clair bloqué par Android.
        // Sans ce texte, les trois causes sont indiscernables à l'écran.
        message: _networkErrorMessage(e),
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
        // Le détail sous-jacent, pas un « Network error » nu : c'est presque
        // toujours une adresse injoignable (localhost pointe sur l'appareil,
        // pas sur la machine de dev) ou du HTTP en clair bloqué par Android.
        // Sans ce texte, les trois causes sont indiscernables à l'écran.
        message: _networkErrorMessage(e),
        originalError: e,
      );
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // Module transporteur — réaligné le 28/07/2026 sur les routes réelles du
  // BFF (backend/bff/src/transporteur/). Formes de payload vérifiées contre
  // le code source Fleetbase, mais la plupart ne sont PAS encore validées par
  // un appel réel : voir docs/journal_implementation_bff.md §6.
  // ───────────────────────────────────────────────────────────────────────

  // Driver endpoints

  Future<Map<String, dynamic>> getDriver() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/transporteur/profil'),
      headers: _buildHeaders(),
    );
    return _parseResponse(response) ?? {};
  }

  /// Remonte une position GPS. Appelé par le suivi en tâche de fond.
  Future<void> updateDriverLocation({
    required double latitude,
    required double longitude,
    double? heading,
    double? speed,
    double? altitude,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/position'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'latitude': latitude,
        'longitude': longitude,
        if (heading != null) 'heading': heading,
        if (speed != null) 'speed': speed,
        if (altitude != null) 'altitude': altitude,
      }),
    );
    _parseResponse(response);
  }

  /// Bascule la disponibilité. Toujours explicite : omettre la valeur ferait
  /// inverser l'état courant côté Fleetbase, donc désynchroniser sur un rejeu.
  Future<void> setOnline(bool online) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/statut'),
      headers: _buildHeaders(),
      body: jsonEncode({'online': online}),
    );
    _parseResponse(response);
  }

  // Order endpoints

  /// Sans [type], le BFF renvoie les trois catégories d'un coup
  /// (active/adhoc/history) — c'est ce qu'attend l'écran liste (§4.1).
  /// Avec [type], une seule liste à plat.
  Future<Map<String, List<Order>>> getOrderBuckets() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/transporteur/commandes'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    if (data == null) return {'active': [], 'adhoc': [], 'history': []};

    List<Order> parse(String key) {
      final raw = data[key];
      if (raw is! List) return [];
      return raw
          .map((o) => Order.fromJson(o as Map<String, dynamic>))
          .toList();
    }

    return {
      'active': parse('active'),
      'adhoc': parse('adhoc'),
      'history': parse('history'),
    };
  }

  Future<List<Order>> getOrders({String type = 'assigned'}) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/transporteur/commandes')
          .replace(queryParameters: {'type': type}),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    if (data != null && data['orders'] is List) {
      return (data['orders'] as List)
          .map((order) => Order.fromJson(order as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  /// Le BFF renvoie la commande Fleetbase telle quelle, sans enveloppe.
  /// Une commande qui n'appartient pas au driver remonte en 404 (jamais 403 :
  /// un driver n'a pas à apprendre qu'un identifiant existe).
  Future<Order> getOrder(String orderId) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    if (data != null) {
      return Order.fromJson(data as Map<String, dynamic>);
    }
    throw AppException(code: AppError.orderNotFound);
  }

  /// Accepte une commande adhoc : côté Fleetbase, l'assignation et le
  /// démarrage sont une seule opération (§4.2 « assigne le driver et démarre
  /// immédiatement »). Peut échouer si un autre driver a été plus rapide.
  Future<void> acceptOrder(String orderId) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId/accepter'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> startOrder(String orderId) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId/demarrer'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  /// Marque la commande comme terminée. Distinct de [updateActivity] : c'est
  /// la transition terminale dédiée côté Fleetbase.
  Future<void> completeOrder(String orderId) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId/terminer'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  /// Transitions possibles sur cette commande à l'instant T.
  ///
  /// À appeler AVANT [updateActivity] : le détail de commande ne contient
  /// aucune donnée d'activité (vérifié sur une vraie commande, journal §6.9),
  /// il n'y a donc rien à renvoyer sans passer par ici.
  ///
  /// Chaque entrée porte au moins `code`, `status`, `details`, `complete`, et
  /// `require_pod`/`pod_method` quand l'étape exige une preuve — c'est ce
  /// drapeau qui doit router vers l'écran POD (§5) avant de valider l'étape.
  Future<List<Map<String, dynamic>>> getNextActivities(String orderId,
      {String? waypoint}) async {
    final uri = Uri.parse('$baseUrl/transporteur/commandes/$orderId/activites-suivantes');
    final response = await _httpClient.get(
      waypoint != null ? uri.replace(queryParameters: {'waypoint': waypoint}) : uri,
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    if (data is Map && data['activities'] is List) {
      return (data['activities'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Fait progresser la commande dans sa machine à états.
  ///
  /// [activity] doit être un objet Activity COMPLET tel que renvoyé par
  /// [getNextActivities], pas une chaîne de statut — c'est ce que valide
  /// POST /v1/orders/{id}/update-activity côté Fleetbase.
  Future<void> updateActivity(String orderId, Map<String, dynamic> activity,
      {String? proof}) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId/activite'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'activity': activity,
        if (proof != null) 'proof': proof,
      }),
    );
    _parseResponse(response);
  }

  /// Preuve de livraison photo (§5). [photos] sont des images encodées en
  /// base64 — le contrôleur Fleetbase les accepte au même titre qu'un upload
  /// multipart, ce qui évite au BFF de gérer du multipart.
  Future<void> captureProofPhoto(String orderId, List<String> photos,
      {String? remarks, String? subjectId}) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId/preuve'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'photos': photos,
        if (remarks != null) 'remarks': remarks,
        if (subjectId != null) 'subjectId': subjectId,
      }),
    );
    _parseResponse(response);
  }

  /// Signale un échec de livraison (§4.3).
  ///
  /// [reason] doit appartenir à la liste fermée du BFF : client_absent,
  /// adresse_introuvable, colis_refuse, colis_endommage, acces_impossible,
  /// autre. La photo est optionnelle et son upload est best-effort côté
  /// serveur — le signalement est conservé même si l'envoi échoue, pour qu'un
  /// driver en mauvaise couverture puisse quand même le déclarer.
  Future<Map<String, dynamic>> reportDeliveryFailure(
    String orderId, {
    required String reason,
    String? notes,
    String? waypointUuid,
    String? photo,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId/echec'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'reason': reason,
        if (notes != null) 'notes': notes,
        if (waypointUuid != null) 'waypointUuid': waypointUuid,
        if (photo != null) 'photo': photo,
      }),
    );
    return _parseResponse(response) ?? {};
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Profil COMMERÇANT
  //
  // Même client, même jeton : les trois profils partagent l'émetteur JWT du
  // BFF, seul le `type` porté par le jeton diffère. C'est ce qui permet une
  // app unique sans dupliquer la couche réseau.
  // ═══════════════════════════════════════════════════════════════════════

  /// Connexion unifiée : le serveur résout le profil depuis l'email.
  ///
  /// Préférée aux endpoints par persona, qui obligeraient l'app à demander
  /// son profil à l'utilisateur — une information que le serveur détient.
  /// La réponse porte `user.type`, ou `requiresRoleSelection` dans le cas
  /// rare où un même identifiant vaut pour plusieurs profils.
  Future<Map<String, dynamic>> loginUnified({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: _buildHeaders(),
        body: jsonEncode({'email': email, 'password': password}),
      );
      final data = _parseResponse(response);
      if (data != null && data['token'] != null) {
        await _saveToken(data['token'] as String);
      }
      return (data ?? <String, dynamic>{}) as Map<String, dynamic>;
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.networkError,
        message: _networkErrorMessage(e),
        originalError: e,
      );
    }
  }

  Future<Map<String, dynamic>> loginMerchant({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('$baseUrl/auth/merchant/login'),
        headers: _buildHeaders(),
        body: jsonEncode({'email': email, 'password': password}),
      );
      final data = _parseResponse(response);
      if (data != null && data['token'] != null) {
        await _saveToken(data['token'] as String);
      }
      return (data ?? <String, dynamic>{}) as Map<String, dynamic>;
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.networkError,
        message: _networkErrorMessage(e),
        originalError: e,
      );
    }
  }

  /// L'inscription commerçant CRÉE un Vendor et un Contact côté Fleetbase —
  /// contrairement au driver, qui se rattache à un enregistrement existant
  /// provisionné par un opérateur.
  Future<Map<String, dynamic>> registerMerchant({
    required String email,
    required String password,
    required String businessName,
    String? firstName,
    String? lastName,
    String? phone,
  }) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('$baseUrl/auth/merchant/register'),
        headers: _buildHeaders(),
        body: jsonEncode({
          'email': email,
          'password': password,
          'businessName': businessName,
          if (firstName != null && firstName.isNotEmpty) 'firstName': firstName,
          if (lastName != null && lastName.isNotEmpty) 'lastName': lastName,
          if (phone != null && phone.isNotEmpty) 'phone': phone,
        }),
      );
      final data = _parseResponse(response);
      if (data != null && data['token'] != null) {
        await _saveToken(data['token'] as String);
      }
      return (data ?? <String, dynamic>{}) as Map<String, dynamic>;
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException(
        code: AppError.networkError,
        message: _networkErrorMessage(e),
        originalError: e,
      );
    }
  }

  List<T> _listOf<T>(dynamic data, String key, T Function(Map<String, dynamic>) build) {
    final raw = (data is Map) ? (data[key] ?? data['data'] ?? data) : data;
    if (raw is! List) return <T>[];
    return raw.whereType<Map<String, dynamic>>().map(build).toList();
  }

  Future<List<MerchantOrder>> getMerchantOrders() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/commandes'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'orders', MerchantOrder.fromJson);
  }

  Future<MerchantOrder> getMerchantOrder(String id) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/commandes/$id'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    final map = (data is Map && data['order'] is Map) ? data['order'] : data;
    return MerchantOrder.fromJson(map as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> getMerchantTracking(String id) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/commandes/$id/suivi'),
      headers: _buildHeaders(),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createMerchantOrder(Map<String, dynamic> body) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/commandes'),
      headers: _buildHeaders(),
      body: jsonEncode(body),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  Future<void> cancelMerchantOrder(String id) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/commandes/$id/annuler'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<List<SavedAddress>> getMerchantAddresses() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/adresses'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'places', SavedAddress.fromJson);
  }

  Future<void> saveMerchantAddress({
    required String label,
    required String name,
    required String address,
    required double latitude,
    required double longitude,
    String? contactName,
    String? contactPhone,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/adresses'),
      headers: _buildHeaders(),
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
    _parseResponse(response);
  }
}
