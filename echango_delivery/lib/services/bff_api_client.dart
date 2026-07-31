import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../config/app_rules.dart';
import '../errors/app_error.dart';
import '../models/order.dart';
import '../models/merchant_order.dart';
import '../models/fleet_driver_position.dart';
import '../models/cash.dart';

const _tokenKey = 'echango_session_token';

/// Client HTTP qui borne chaque requête dans le temps.
///
/// `package:http` n'applique aucun délai maximal : une requête partie vers un
/// réseau qui cesse de répondre reste en attente indéfiniment, et l'écran
/// garde son indicateur de chargement sans jamais afficher d'erreur ni
/// permettre de réessayer. Sur le téléphone d'un transporteur en zone de
/// couverture faible, c'est le mode d'échec le plus courant — et le plus
/// difficile à distinguer d'une application figée.
///
/// Enveloppé ici plutôt qu'appliqué à chaque appel : un `.timeout()` par site
/// se serait fait oublier au premier nouvel endpoint.
class _TimeoutClient extends http.BaseClient {
  final http.Client _inner;
  final Duration _timeout;

  _TimeoutClient(this._inner, this._timeout);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request).timeout(_timeout);

  @override
  void close() => _inner.close();
}

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
  }) : _httpClient = _TimeoutClient(
          httpClient ?? http.Client(),
          const Duration(seconds: ApiConfig.apiTimeout),
        );

  /// Restaure le token depuis le stockage sécurisé au démarrage de l'app.
  Future<void> restoreSession() async {
    _accessToken = await _storage.read(key: _tokenKey);
  }

  /// Un jeton est-il présent en mémoire ?
  ///
  /// Ne dit rien de sa validité : le BFF signe des JWT expirables, et seul un
  /// appel réel révèle une expiration (401, [AppError.authTokenInvalid] ou
  /// [AppError.authSessionRevoked] selon le motif exact, lus depuis le corps
  /// de la réponse par [_parseResponse]). Sert uniquement à décider, au
  /// démarrage, s'il vaut la peine de restaurer la session plutôt que
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
    if (e is TimeoutException) {
      return 'Le serveur n\'a pas répondu en ${ApiConfig.apiTimeout} s. '
          'Vérifiez votre connexion et réessayez.';
    }
    return 'Erreur réseau : $raw';
  }

  /// Traite les réponses HTTP et mappe les erreurs.
  dynamic _parseResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    }

    // ── 401 et 404 passent désormais par le même chemin que le reste ─────────
    //
    // Ces deux statuts avaient un traitement à part qui **écrasait** le `code`
    // réel envoyé par le BFF : un mot de passe erroné (401,
    // `auth.invalid_credentials`) et un jeton expiré (401, `auth.token_invalid`)
    // recevaient tous deux le même code générique côté client, sans moyen de
    // les distinguer à l'écran. `HttpExceptionFilter` pose déjà `code` sur
    // toutes les réponses d'erreur du BFF (401/404 compris) — il n'y avait
    // aucune raison de le jeter sur ces deux statuts précisément.
    try {
      final data = jsonDecode(response.body);
      final errorCode = data['code'] ??
          (response.statusCode == 404 ? AppError.notFound : AppError.unknown);
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

  /// Télécharge une image servie par le BFF (preuve de livraison).
  ///
  /// Passe par le client plutôt que par `Image.network` : la route est
  /// protégée par le JWT, et le widget ne porte pas l'en-tête d'autorisation.
  /// Le jeton reste ainsi enfermé ici, jamais recopié dans un écran.
  Future<Uint8List> fetchImage(String path) async {
    final uri = Uri.parse(path.startsWith('http') ? path : '$baseUrl$path');
    final response = await _httpClient.get(uri, headers: _buildHeaders());

    if (response.statusCode >= 400) {
      throw AppException(
        code: AppError.unknown,
        message: 'Image indisponible (HTTP ${response.statusCode})',
      );
    }
    return response.bodyBytes;
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
  ///
  /// Sur une course payée à la réception, [collectedAmount] est **obligatoire**
  /// et le serveur refuse la clôture sans lui : « livré » et « perçu X » sont un
  /// seul fait, et les séparer garantirait que le second soit oublié. Un écart
  /// avec le montant annoncé exige [discrepancyReason].
  Future<void> completeOrder(
    String orderId, {
    double? collectedAmount,
    String? discrepancyReason,
    String? cashNotes,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId/terminer'),
      headers: _buildHeaders(),
      body: collectedAmount == null
          ? null
          : jsonEncode({
              'collectedAmount': collectedAmount,
              if (discrepancyReason != null) 'discrepancyReason': discrepancyReason,
              if (cashNotes != null && cashNotes.isNotEmpty) 'notes': cashNotes,
            }),
    );
    _parseResponse(response);
  }

  // ── Caisse (transporteur) ──────────────────────────────────────────────
  //
  // Le transporteur conserve les espèces qu'il encaisse ; ces routes servent le
  // compte de ce qu'il doit, commerçant par commerçant. Echango ne détient
  // jamais ces sommes.

  Future<CashLedger> getDriverCashLedger() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/transporteur/caisse'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    return _ledgerFrom(data, CashBalance.fromDriverJson);
  }

  Future<List<CashRemittance>> getDriverRemittances() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/transporteur/caisse/remises'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'data', CashRemittance.fromJson);
  }

  Future<void> declareDriverRemittance({
    required String merchantId,
    required double amount,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/caisse/remises'),
      headers: _buildHeaders(),
      body: jsonEncode({'merchantId': merchantId, 'amount': amount}),
    );
    _parseResponse(response);
  }

  Future<void> confirmDriverRemittance(String id) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/caisse/remises/$id/confirmer'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> disputeDriverRemittance(String id, {String? reason}) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/caisse/remises/$id/contester'),
      headers: _buildHeaders(),
      body: jsonEncode({if (reason != null) 'reason': reason}),
    );
    _parseResponse(response);
  }

  // ── Encaissements (commerçant) ─────────────────────────────────────────

  Future<CashLedger> getMerchantCashLedger() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/encaissements'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    return _ledgerFrom(data, CashBalance.fromMerchantJson);
  }

  /// Le détail des encaissements, livraison par livraison.
  ///
  /// Le total dû est une somme de différences : sans ce détail, un commerçant
  /// ne peut pas vérifier d'où viennent les espèces qu'on lui doit — et c'est
  /// pourtant ce qu'il contrôle avant de confirmer une remise, geste qui éteint
  /// une dette.
  Future<List<CashCollectionEntry>> getMerchantCollections() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/encaissements/details'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'data', CashCollectionEntry.fromJson);
  }

  /// Ce qui sera réclamé aux portes, et n'est encore dans la poche de personne.
  ///
  /// Sert une question que le registre ne sait pas poser : il n'enregistre que
  /// le perçu, donc un commerçant dont les courses sont en route lisait « 0 DZD
  /// / aucune somme en attente » pendant qu'on réclamait son argent ailleurs.
  /// Deux listes servies ensemble : ce qui est en route, et ce qui est livré
  /// **sans encaissement enregistré** — un cas qui n'aurait pas dû exister et
  /// qui existe, parce qu'une clôture depuis la console Fleetbase ne passe par
  /// aucune de nos gardes.
  Future<PendingCollections> getMerchantPendingCollections() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/encaissements/attendus'),
      headers: _buildHeaders(),
    );
    return PendingCollections.fromJson(_parseResponse(response));
  }

  /// « Ce transporteur a bien encaissé X sur cette livraison. »
  ///
  /// Régularise une course clôturée hors application, dont le registre ne sait
  /// rien. La déclaration n'établit rien seule : elle attend la confirmation du
  /// transporteur — ici le déclarant engage quelqu'un d'autre.
  ///
  /// [fleetbaseDriverUuid] n'est requis que si la livraison ne porte aucun
  /// transporteur, cas réel sur une course close depuis la console. Ignoré
  /// sinon : la course fait foi.
  Future<void> declareMissingCollection({
    required String orderId,
    required double collectedAmount,
    String? fleetbaseDriverUuid,
    String? discrepancyReason,
    String? notes,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/commandes/$orderId/encaissement'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'collectedAmount': collectedAmount,
        if (fleetbaseDriverUuid != null) 'fleetbaseDriverUuid': fleetbaseDriverUuid,
        if (discrepancyReason != null) 'discrepancyReason': discrepancyReason,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      }),
    );
    _parseResponse(response);
  }

  /// Le transporteur confirme un encaissement déclaré par le commerçant.
  ///
  /// Aucun corps : la rémunération vient de la commande, jamais de lui — la
  /// saisir au moment où il confirme sa propre dette lui laisserait fixer ce
  /// qu'il retient dessus.
  Future<void> confirmDeclaredCollection(String collectionId) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/caisse/encaissements/$collectionId/confirmer'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> disputeDeclaredCollection(String collectionId, {String? reason}) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/caisse/encaissements/$collectionId/contester'),
      headers: _buildHeaders(),
      body: jsonEncode({if (reason != null && reason.isNotEmpty) 'reason': reason}),
    );
    _parseResponse(response);
  }

  /// Idem côté transporteur : ce qu'il détient, course par course.
  Future<List<CashCollectionEntry>> getDriverCollections() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/transporteur/caisse/encaissements'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'data', CashCollectionEntry.fromJson);
  }

  Future<List<CashRemittance>> getMerchantRemittances() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/encaissements/remises'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'data', CashRemittance.fromJson);
  }

  Future<void> declareMerchantRemittance({
    required String driverId,
    required double amount,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/encaissements/remises'),
      headers: _buildHeaders(),
      body: jsonEncode({'driverId': driverId, 'amount': amount}),
    );
    _parseResponse(response);
  }

  Future<void> confirmMerchantRemittance(String id) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/encaissements/remises/$id/confirmer'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> disputeMerchantRemittance(String id, {String? reason}) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/encaissements/remises/$id/contester'),
      headers: _buildHeaders(),
      body: jsonEncode({if (reason != null) 'reason': reason}),
    );
    _parseResponse(response);
  }

  /// Désérialisation commune aux deux profils : même forme, seule la clé
  /// d'identifiant de la contrepartie change.
  CashLedger _ledgerFrom(
    dynamic data,
    CashBalance Function(Map<String, dynamic>) build,
  ) {
    final raw = (data is Map) ? data['balances'] : null;
    return CashLedger(
      balances: raw is List
          ? raw.whereType<Map<String, dynamic>>().map(build).toList()
          : const [],
      currency: (data is Map ? data['currency'] as String? : null) ?? '',
      ceiling: (data is Map ? (data['ceiling'] as num?) : null)?.toDouble(),
      platformCommission:
          (data is Map ? (data['platform_commission'] as num?) : null)?.toDouble(),
    );
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
  ///
  /// [collectedAmount] accompagne la transition **terminale** d'une livraison
  /// payée à la réception : le serveur la refuse sans lui. C'est ce chemin, et
  /// non `completeOrder`, que l'application emprunte pour clore une course —
  /// les boutons viennent des transitions proposées par le serveur.
  Future<void> updateActivity(String orderId, Map<String, dynamic> activity,
      {String? proof,
      double? collectedAmount,
      String? discrepancyReason,
      String? cashNotes}) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId/activite'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'activity': activity,
        if (proof != null) 'proof': proof,
        if (collectedAmount != null)
          'cash': {
            'collectedAmount': collectedAmount,
            if (discrepancyReason != null) 'discrepancyReason': discrepancyReason,
            if (cashNotes != null && cashNotes.isNotEmpty) 'notes': cashNotes,
          },
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

  /// Refuse une course, avec un motif.
  ///
  /// [reason] appartient à la liste fermée du BFF : prix_insuffisant,
  /// trop_loin, vehicule_inadapte, creneau_impossible, colis_inadapte,
  /// indisponible, autre.
  ///
  /// La réponse porte `releasedToPool` : `true` quand la course était assignée
  /// à ce transporteur et vient de repartir au réseau, `false` quand elle était
  /// simplement diffusée et se contente de disparaître de sa liste. Les deux
  /// ne se disent pas de la même façon à l'écran — le premier cas a une
  /// conséquence pour le commerçant, le second non.
  Future<Map<String, dynamic>> declineOrder(
    String orderId, {
    required String reason,
    String? notes,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/commandes/$orderId/refuser'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'reason': reason,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      }),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
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

  /// Une page de commandes du commerçant.
  ///
  /// ⚠️ Le serveur pagine depuis toujours (`page`, `limit`, 25 par défaut) et
  /// l'app n'envoyait **aucun paramètre** : au-delà de 25 livraisons, les plus
  /// anciennes devenaient inaccessibles sans que rien ne le signale. Même
  /// défaut que le plafond de 100 corrigé côté transporteur — une liste
  /// tronquée en silence n'est pas partielle, elle est fausse pour qui la lit
  /// comme complète.
  Future<MerchantOrderPage> getMerchantOrders({int page = 1, int limit = AppRules.listPageSize}) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/commandes').replace(
        queryParameters: {'page': '$page', 'limit': '$limit'},
      ),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    return MerchantOrderPage(
      orders: _listOf(data, 'orders', MerchantOrder.fromJson),
      total: (data is Map ? (data['pagination']?['total'] as num?) : null)?.toInt() ?? 0,
    );
  }

  /// Dernière position connue du transporteur affecté à cette course.
  ///
  /// `null` tant que personne n'est affecté — état normal d'une course en
  /// attente, pas une erreur.
  Future<DriverPosition?> getMerchantOrderPosition(String id) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/commandes/$id/position'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    final raw = (data is Map) ? data['position'] : null;
    return raw is Map<String, dynamic> ? DriverPosition.fromJson(raw) : null;
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

  // ── Caisse de l'entreprise ───────────────────────────────────────────────
  //
  // ⚠️ Ces routes ne sont pas un supplément d'agrément : sans elles, une dette
  // envers une entreprise n'est **confirmable par personne**, et elle reste
  // ouverte jusqu'à ce que le plafond bloque le conducteur.

  Future<CashLedger> getFleetCashLedger() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/caisse'),
      headers: _buildHeaders(),
    );
    // ⚠️ `fromMerchantJson` et non un désérialiseur dédié : le champ qui compte
    // est `counterparty_*`, servi identiquement aux trois personas depuis la
    // généralisation du registre. Les deux fabriques ne diffèrent que par leur
    // repli sur les anciens noms — et l'entreprise n'en a aucun à replier.
    return _ledgerFrom(_parseResponse(response), CashBalance.fromMerchantJson);
  }

  Future<List<CashRemittance>> getFleetRemittances() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/caisse/remises'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'data', CashRemittance.fromJson);
  }

  Future<List<CashCollectionEntry>> getFleetCollections() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/caisse/encaissements'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'data', CashCollectionEntry.fromJson);
  }

  Future<void> declareFleetRemittance({
    required String counterpartyId,
    required double amount,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/flotte/caisse/remises'),
      headers: _buildHeaders(),
      body: jsonEncode({'counterpartyId': counterpartyId, 'amount': amount}),
    );
    _parseResponse(response);
  }

  Future<void> confirmFleetRemittance(String id) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/flotte/caisse/remises/$id/confirmer'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> disputeFleetRemittance(String id, {String? reason}) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/flotte/caisse/remises/$id/contester'),
      headers: _buildHeaders(),
      // La clé est OMISE quand il n'y a pas de motif, comme dans les deux
      // variantes persona voisines. Cette ligne envoyait `{"reason": null}`,
      // seule divergence de surface des trois — et c'est en la remarquant
      // qu'on a trouvé que la route flotte n'avait aucun DTO, donc aucune
      // validation.
      body: jsonEncode({if (reason != null) 'reason': reason}),
    );
    _parseResponse(response);
  }

  // ── Profil entreprise de transport (« flotte ») ─────────────────────────
  //
  // Le module BFF existait depuis le 28/07 et **aucune de ces routes n'était
  // appelée** : l'application affichait « Espace non disponible » (défaut D20).
  // C'est le fil rouge du projet pris à l'envers — ici l'app ignorait ce que le
  // serveur savait déjà faire.

  /// Les courses confiées à cette entreprise.
  Future<Map<String, dynamic>> getFleetOrders({int page = 1, int limit = AppRules.listPageSize}) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/commandes').replace(
        queryParameters: {'page': '$page', 'limit': '$limit'},
      ),
      headers: _buildHeaders(),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  /// Le détail d'une course confiée à cette entreprise.
  Future<Map<String, dynamic>> getFleetOrderDetail(String orderId) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/commandes/$orderId'),
      headers: _buildHeaders(),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  /// Le détail d'une course **libre**, avant de décider de la prendre.
  ///
  /// Route distincte de la précédente, et non un assouplissement de sa garde :
  /// `GET /flotte/commandes/:id` exige que la course soit déjà celle de
  /// l'entreprise. Celle-ci exige au contraire qu'elle ne soit à personne.
  Future<Map<String, dynamic>> getFleetOpportunityDetail(String orderId) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/opportunites/$orderId'),
      headers: _buildHeaders(),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  /// Les courses **libres**, réclamables par cette entreprise.
  ///
  /// Servies avec l'adresse complète, le prix et le montant à encaisser — ce
  /// sont eux qui permettent de décider. Seule l'identité du destinataire (nom,
  /// téléphone) attend l'engagement.
  Future<Map<String, dynamic>> getFleetOpportunities({int page = 1, int limit = AppRules.listPageSize}) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/opportunites').replace(
        queryParameters: {'page': '$page', 'limit': '$limit'},
      ),
      headers: _buildHeaders(),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  /// Prendre une course du pool.
  ///
  /// Le second arrivant reçoit `order.already_taken` : le serveur relit après
  /// écriture, Fleetbase n'offrant aucune écriture conditionnelle.
  Future<Map<String, dynamic>> claimFleetOrder(String orderId) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/flotte/opportunites/$orderId/prendre'),
      headers: _buildHeaders(),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  /// Chercher un conducteur **déjà dans le réseau**, pour le rattacher.
  ///
  /// Le téléphone n'est jamais renvoyé, et au-delà de dix correspondances le
  /// serveur refuse plutôt que de tronquer : une liste balayable serait
  /// l'annuaire qu'on refuse d'ouvrir (même règle que les favoris du
  /// commerçant, 29/07).
  Future<List<Map<String, dynamic>>> searchNetworkDrivers(String query) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/conducteurs/recherche').replace(
        queryParameters: {'q': query},
      ),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    final list = (data is Map ? data['data'] : data) as List<dynamic>? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Demander le rattachement d'un conducteur existant. Naît en attente de sa
  /// réponse — l'entreprise ne peut pas se l'attribuer seule.
  Future<Map<String, dynamic>> requestDriverMembership(String driverUuid) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/flotte/conducteurs/$driverUuid/adhesion'),
      headers: _buildHeaders(),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  /// Les rattachements de cette entreprise, tous états confondus.
  Future<List<Map<String, dynamic>>> getFleetMemberships() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/adhesions'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    final list = (data is Map ? data['data'] : data) as List<dynamic>? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Suspendre ou réactiver un rattachement.
  ///
  /// Il n'existe **aucune suppression**, côté serveur comme ici : la dette d'un
  /// conducteur envers une entreprise survit à leur séparation.
  Future<void> setFleetMembershipSuspended(String membershipId, bool suspended) async {
    final action = suspended ? 'suspendre' : 'reactiver';
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/flotte/adhesions/$membershipId/$action'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  // ── Côté conducteur : ses entreprises ───────────────────────────────────

  /// Les entreprises pour lesquelles ce conducteur roule, et celles qui le
  /// demandent. Un rattachement décide à qui il devra les espèces d'une course.
  Future<List<Map<String, dynamic>>> getMyFleets() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/transporteur/entreprises'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    final list = (data is Map ? data['data'] : data) as List<dynamic>? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Quitter une entreprise à laquelle on est rattaché.
  ///
  /// ⚠️ Ne solde rien : l'adhésion se ferme, la dette reste écrite.
  Future<void> leaveFleet(String membershipId) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/entreprises/$membershipId/quitter'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> respondToMembership(String membershipId, {required bool accept}) async {
    final action = accept ? 'accepter' : 'refuser';
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/entreprises/$membershipId/$action'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<List<Map<String, dynamic>>> getFleetDrivers() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/drivers'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    final list = (data is Map ? data['data'] : data) as List<dynamic>? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Où sont les conducteurs de cette entreprise, en ce moment.
  ///
  /// ⚠️ **La route existait depuis le 28/07 et n'était appelée nulle part.**
  /// C'est le fil rouge du projet — le serveur savait, l'app ignorait — et il
  /// portait ici la fonction même du persona : la vision produit décrit
  /// l'entreprise de transport comme « une vue dispatch minimaliste (commandes
  /// entrantes, assignation à un conducteur disponible, **position des
  /// conducteurs**) ».
  ///
  /// Le serveur ne renvoie **que** ceux qui ont une position exploitable, et il
  /// se charge lui-même de n'exposer que les conducteurs de cette entreprise —
  /// adhérents compris, sans quoi la carte montrerait la moitié de la flotte
  /// sans le dire.
  Future<List<FleetDriverPosition>> getFleetDriverPositions() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/flotte/drivers/positions'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    final list = (data is Map ? data['data'] : data) as List<dynamic>? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(FleetDriverPosition.tryFromJson)
        .whereType<FleetDriverPosition>()
        .toList();
  }

  /// Créer un conducteur et le rattacher à cette entreprise.
  ///
  /// Le BFF fait les deux d'un geste (`createDriver` puis
  /// `assignDriverToVendor`). Sans cette route côté app, une entreprise
  /// nouvellement inscrite pouvait prendre des courses et **n'en assigner
  /// aucune, définitivement** — l'impasse exacte corrigée le 29/07 sur
  /// « Mes transporteurs ».
  Future<Map<String, dynamic>> addFleetDriver({
    required String name,
    required String email,
    String? phone,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/flotte/drivers'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'name': name,
        'email': email,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      }),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  /// Désigner un conducteur sur une course de l'entreprise.
  Future<Map<String, dynamic>> assignFleetDriver(String orderId, String driverUuid) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/flotte/commandes/$orderId/assigner'),
      headers: _buildHeaders(),
      body: jsonEncode({'driverId': driverUuid}),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
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

  /// Publie un brouillon : déclenche le dispatch (favori ou pool commun) sur
  /// une commande créée sans lui.
  Future<Map<String, dynamic>> publishMerchantOrder(String id) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/commandes/$id/publier'),
      headers: _buildHeaders(),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  /// Champs à reprendre pour recommencer une livraison identique.
  ///
  /// Ne crée rien : le serveur renvoie de quoi pré-remplir le formulaire, que
  /// le commerçant valide ensuite. L'enlèvement programmé n'est pas repris —
  /// celui d'hier est dans le passé, et le recopier créerait une commande dont
  /// l'échéance est déjà dépassée.
  Future<Map<String, dynamic>> getMerchantOrderTemplate(String id) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/commandes/$id/modele'),
      headers: _buildHeaders(),
    );
    return (_parseResponse(response) ?? <String, dynamic>{}) as Map<String, dynamic>;
  }

  // ── Notifications (commerçant) ─────────────────────────────────────────
  //
  // Relevées par interrogation : l'envoi push vers un commerçant n'est pas
  // branché côté serveur (aucun credential Firebase serveur, et le commerçant
  // n'est volontairement pas un utilisateur Fleetbase). Le journal serveur
  // reste la source de vérité — une notification non vue n'est pas perdue.

  Future<MerchantNotifications> getNotifications({bool unreadOnly = false}) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/notifications')
          .replace(queryParameters: unreadOnly ? {'nonLues': 'true'} : null),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    return MerchantNotifications.fromJson(
      (data ?? <String, dynamic>{}) as Map<String, dynamic>,
    );
  }

  Future<void> markNotificationRead(String id) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/notifications/$id/lu'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> markAllNotificationsRead() async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/notifications/tout-lu'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  Future<void> cancelMerchantOrder(String id) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/commandes/$id/annuler'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  /// Devis d'une course, calculé **par le serveur**.
  ///
  /// L'app n'applique aucun barème : la tarification est centralisée dans le
  /// BFF, seul endroit où la formule vivra. Un calcul dupliqué côté client
  /// dériverait au premier changement de tarif, et il faudrait une mise à jour
  /// d'application pour corriger un prix.
  Future<OrderQuote> quoteOrder({
    required double pickupLatitude,
    required double pickupLongitude,
    required double dropoffLatitude,
    required double dropoffLongitude,
    String? scheduledAt,
    String? vehicleType,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/devis'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'pickupLatitude': pickupLatitude,
        'pickupLongitude': pickupLongitude,
        'dropoffLatitude': dropoffLatitude,
        'dropoffLongitude': dropoffLongitude,
        if (scheduledAt != null) 'scheduledAt': scheduledAt,
        if (vehicleType != null) 'vehicleType': vehicleType,
      }),
    );
    return OrderQuote.fromJson(_parseResponse(response) as Map<String, dynamic>);
  }

  // ── Transporteurs favoris (commerçant) ─────────────────────────────────

  /// Transporteurs ayant déjà livré pour ce commerçant.
  Future<List<KnownDriver>> getKnownDrivers() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/transporteurs'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'data', KnownDriver.fromJson);
  }

  /// Cherche un transporteur du réseau par nom ou téléphone.
  ///
  /// Une recherche, pas un annuaire : au-delà de dix correspondances le serveur
  /// renvoie `tooMany` et aucune donnée, plutôt qu'une liste tronquée qu'on
  /// pourrait balayer en changeant une lettre.
  Future<DriverSearchResult> searchDrivers(String query) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/transporteurs/recherche')
          .replace(queryParameters: {'q': query}),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    return DriverSearchResult(
      drivers: _listOf(data, 'data', KnownDriver.fromJson),
      tooMany: (data is Map) && data['too_many'] == true,
    );
  }

  Future<List<KnownDriver>> getFavouriteDrivers() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/transporteurs/favoris'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'data', KnownDriver.fromJson);
  }

  Future<void> addFavouriteDriver(String driverUuid, {String? name}) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/transporteurs/favoris'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'fleetbaseDriverUuid': driverUuid,
        if (name != null) 'driverName': name,
      }),
    );
    _parseResponse(response);
  }

  Future<void> removeFavouriteDriver(String favouriteId) async {
    final response = await _httpClient.delete(
      Uri.parse('$baseUrl/commercant/transporteurs/favoris/$favouriteId'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  /// Déclare la catégorie de véhicule du transporteur connecté.
  Future<void> setVehicleType(String? vehicleType) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/transporteur/vehicule'),
      headers: _buildHeaders(),
      body: jsonEncode({if (vehicleType != null) 'vehicleType': vehicleType}),
    );
    _parseResponse(response);
  }

  /// Recherche d'adresse, relayée par le BFF.
  ///
  /// L'app n'appelle jamais Nominatim directement : sa politique d'usage exige
  /// un User-Agent identifiant et plafonne le débit, deux choses intenables
  /// depuis des milliers d'appareils.
  Future<List<GeocodedPlace>> searchAddress(String query) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/geocodage?q=${Uri.encodeQueryComponent(query)}'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    return _listOf(data, 'data', GeocodedPlace.fromJson);
  }

  /// Adresse correspondant à un point choisi sur la carte.
  Future<GeocodedPlace> reverseGeocode(double latitude, double longitude) async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/geocodage/inverse?lat=$latitude&lon=$longitude'),
      headers: _buildHeaders(),
    );
    final data = _parseResponse(response);
    return GeocodedPlace.fromJson(data as Map<String, dynamic>);
  }

  Future<List<SavedAddress>> getMerchantAddresses() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/commercant/adresses'),
      headers: _buildHeaders(),
    );
    return _listOf(_parseResponse(response), 'places', SavedAddress.fromJson);
  }

  /// Modifie une adresse du carnet. [id] est l'identifiant du lieu.
  ///
  /// Seuls [name] et [contactPhone] sont obligatoires (décision produit,
  /// 30/07/2026) : [address] et la position se complètent souvent après coup.
  Future<void> updateMerchantAddress(
    String id, {
    required String label,
    required String name,
    String? address,
    String? neighborhood,
    String? city,
    String? district,
    String? province,
    String? postalCode,
    String? country,
    double? latitude,
    double? longitude,
    String? contactName,
    required String contactPhone,
    bool isDefault = false,
  }) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/commercant/adresses/$id'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'label': label,
        'name': name,
        // Envoyée même vide, contrairement aux autres : `PUT /places` ne
        // modifie que les clés présentes, donc l'omettre rendait le champ
        // **ineffaçable** — vider la ligne et enregistrer conservait l'ancienne
        // adresse, sans erreur ni indice à l'écran.
        if (address != null) 'address': address,
        // La commune, elle, reste omise quand elle est absente : elle ne vient
        // que du géocodage, et l'envoyer vide effacerait celle enregistrée lors
        // d'un passage précédent par la carte.
        if (neighborhood != null && neighborhood.isNotEmpty)
          'neighborhood': neighborhood,
        if (city != null && city.isNotEmpty) 'city': city,
        if (district != null && district.isNotEmpty) 'district': district,
        if (province != null && province.isNotEmpty) 'province': province,
        if (postalCode != null && postalCode.isNotEmpty) 'postalCode': postalCode,
        if (country != null && country.isNotEmpty) 'country': country,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (contactName != null && contactName.isNotEmpty) 'contactName': contactName,
        'contactPhone': contactPhone,
        'isDefault': isDefault,
      }),
    );
    _parseResponse(response);
  }

  Future<void> deleteMerchantAddress(String id) async {
    final response = await _httpClient.delete(
      Uri.parse('$baseUrl/commercant/adresses/$id'),
      headers: _buildHeaders(),
    );
    _parseResponse(response);
  }

  /// Seuls [name] et [contactPhone] sont obligatoires (décision produit,
  /// 30/07/2026) : [address] et la position se complètent souvent après coup.
  Future<void> saveMerchantAddress({
    required String label,
    required String name,
    String? address,
    String? neighborhood,
    String? city,
    String? district,
    String? province,
    String? postalCode,
    String? country,
    double? latitude,
    double? longitude,
    String? contactName,
    required String contactPhone,
    bool isDefault = false,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/commercant/adresses'),
      headers: _buildHeaders(),
      body: jsonEncode({
        'label': label,
        'name': name,
        // Envoyée même vide, contrairement aux autres : `PUT /places` ne
        // modifie que les clés présentes, donc l'omettre rendait le champ
        // **ineffaçable** — vider la ligne et enregistrer conservait l'ancienne
        // adresse, sans erreur ni indice à l'écran.
        if (address != null) 'address': address,
        // La commune, elle, reste omise quand elle est absente : elle ne vient
        // que du géocodage, et l'envoyer vide effacerait celle enregistrée lors
        // d'un passage précédent par la carte.
        if (neighborhood != null && neighborhood.isNotEmpty)
          'neighborhood': neighborhood,
        if (city != null && city.isNotEmpty) 'city': city,
        if (district != null && district.isNotEmpty) 'district': district,
        if (province != null && province.isNotEmpty) 'province': province,
        if (postalCode != null && postalCode.isNotEmpty) 'postalCode': postalCode,
        if (country != null && country.isNotEmpty) 'country': country,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (contactName != null && contactName.isNotEmpty) 'contactName': contactName,
        'contactPhone': contactPhone,
        'isDefault': isDefault,
      }),
    );
    _parseResponse(response);
  }
}
