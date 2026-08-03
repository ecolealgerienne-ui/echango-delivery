import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../errors/app_error.dart';
import '../errors/error_message.dart';
import '../errors/error_translator.dart';
import '../i18n/common_strings.dart';
import '../services/bff_api_client.dart';
import 'locale_state.dart';
import 'write_envelope.dart';

/// Profil de l'utilisateur connecté.
///
/// Une seule app sert les trois publics (décision 28/07/2026) : c'est le même
/// produit vu de trois côtés. Le BFF utilise un émetteur JWT unique dont le
/// jeton porte un `type` — c'est lui qui fait autorité, pas ce que
/// l'utilisateur a coché à l'écran.
enum UserRole { transporteur, commercant, flotte }

extension UserRoleX on UserRole {
  /// Valeur du champ `type` dans le JWT du BFF.
  String get jwtType => switch (this) {
        UserRole.transporteur => 'transporteur',
        UserRole.commercant => 'merchant',
        UserRole.flotte => 'fleet',
      };

  /// Le nom du profil, dans la langue courante.
  ///
  /// Servi en français en dur jusqu'au 01/08/2026, et injecté tel quel dans une
  /// phrase traduite du tableau de bord transporteur.
  String label(Locale locale) => commonLabel(
        switch (this) {
          UserRole.transporteur => 'common.role.transporteur',
          UserRole.commercant => 'common.role.commercant',
          UserRole.flotte => 'common.role.flotte',
        },
        locale,
      );

  /// Écran d'accueil du profil.
  String get homePath => switch (this) {
        UserRole.transporteur => '/transporteur',
        UserRole.commercant => '/commercant',
        UserRole.flotte => '/flotte',
      };

  static UserRole? fromJwtType(String? type) => switch (type) {
        'transporteur' => UserRole.transporteur,
        'merchant' => UserRole.commercant,
        'fleet' => UserRole.flotte,
        _ => null,
      };
}

enum SessionStatus { unauthenticated, authenticated, sessionExpired }

const _statusKey = 'echango_session_status';
const _roleKey = 'echango_session_role';
const _userIdKey = 'echango_user_id';
const _emailKey = 'echango_user_email';
const _displayNameKey = 'echango_user_display_name';
const _lastActivityKey = 'echango_last_activity';

/// Session expirée après 24 h d'inactivité, vérifiée au retour au premier
/// plan, en complément de l'expiration du jeton côté serveur.
const sessionInactivityLimit = Duration(hours: 24);

class AuthState extends ChangeNotifier with WriteEnvelope {

  // Les trois lignes que `WriteEnvelope` demande : le mixin sait écrire les
  // champs sans les posséder, donc les autres références à `_isLoading` et
  // `_errorMessage` de cette classe ne bougent pas.
  @override
  set busy(bool value) => _isLoading = value;
  @override
  set failure(String? value) => _errorMessage = value;
  @override
  Locale get writeLocale => _localeState.locale;
  final SharedPreferences _prefs;
  final BffApiClient _apiClient;
  final LocaleState _localeState;

  SessionStatus _status = SessionStatus.unauthenticated;
  UserRole? _role;
  String? _userId;
  String? _email;
  String? _displayName;
  String? _errorMessage;
  bool _isLoading = false;

  AuthState({
    required SharedPreferences prefs,
    required BffApiClient apiClient,
    required LocaleState localeState,
  })  : _prefs = prefs,
        _apiClient = apiClient,
        _localeState = localeState;

  SessionStatus get status => _status;
  bool get isAuthenticated => _status == SessionStatus.authenticated;
  bool get isSessionExpired => _status == SessionStatus.sessionExpired;
  UserRole? get role => _role;
  String? get userId => _userId;
  String? get email => _email;

  /// Nom d'affichage : raison sociale pour un commerçant, prénom/nom sinon.
  String? get displayName => _displayName;
  String? get errorMessage => _errorMessage;
  bool get isLoading => _isLoading;

  /// Chemin d'accueil du profil connecté, ou l'écran de connexion.
  String get homePath => _role?.homePath ?? '/login';

  Future<void> restoreSession() async {
    await _apiClient.restoreSession();
    _role = UserRoleX.fromJwtType(_prefs.getString(_roleKey));
    _userId = _prefs.getString(_userIdKey);
    _email = _prefs.getString(_emailKey);
    _displayName = _prefs.getString(_displayNameKey);

    // Un jeton sans rôle connu est inexploitable : on ne saurait pas quel
    // écran ouvrir. Repartir de la connexion plutôt que de deviner.
    if (_apiClient.isAuthenticated() && _role != null) {
      _status = SessionStatus.authenticated;
      checkInactivity();
    }
    notifyListeners();
  }

  void checkInactivity() {
    final raw = _prefs.getString(_lastActivityKey);
    if (raw == null) return;
    final last = DateTime.tryParse(raw);
    if (last == null) return;
    if (DateTime.now().difference(last) > sessionInactivityLimit) {
      _status = SessionStatus.sessionExpired;
      notifyListeners();
    }
  }

  void touchActivity() {
    _prefs.setString(_lastActivityKey, DateTime.now().toIso8601String());
  }

  Future<void> _persist({
    required UserRole role,
    required Map<String, dynamic> response,
    required String email,
  }) async {
    // Réponse du BFF : {token, user:{...}} à plat, sans enveloppe `data`.
    final user = response['user'];
    _role = role;
    _userId = user is Map ? user['id'] as String? : null;
    _email = (user is Map ? user['email'] as String? : null) ?? email;
    // ⚠️ **Le repli sur `firstName`/`lastName` a été retiré le 03/08/2026** : la
    // connexion ne les sert plus, aucun des trois personas. Un repli sur des
    // clés qui n'arrivent jamais n'est pas prudent, il est **mort** — et il
    // laisse croire, à qui le lit, que le serveur les envoie encore.
    //
    // ⚠️ `businessName` peut valoir `null` : il vient du `Vendor` Fleetbase, et
    // `getVendorIdentity` rend `null` plutôt que de faire échouer la connexion
    // quand la lecture échoue. Le seul lecteur — le titre de l'écran commerçant
    // — a déjà son repli traduit.
    final nom = user is Map ? user['businessName'] as String? : null;
    _displayName = (nom != null && nom.trim().isNotEmpty) ? nom : null;

    await _prefs.setString(_roleKey, role.jwtType);
    await _prefs.setString(_emailKey, _email!);
    if (_userId != null) await _prefs.setString(_userIdKey, _userId!);
    if (_displayName != null) {
      await _prefs.setString(_displayNameKey, _displayName!);
    } else {
      await _prefs.remove(_displayNameKey);
    }
    await _prefs.setString(_statusKey, 'authenticated');

    _status = SessionStatus.authenticated;
    touchActivity();
  }

  Future<bool> _run(Future<void> Function() action) => runWrite(action);

  /// Profils possibles quand un même couple email/mot de passe existe pour
  /// plusieurs personas. Vide dans le cas normal.
  List<UserRole> _ambiguousRoles = [];
  List<UserRole> get ambiguousRoles => _ambiguousRoles;

  /// Connexion. **Le profil n'est pas demandé à l'utilisateur** : le serveur
  /// le détermine depuis l'email, seul à savoir dans quelle table le compte
  /// existe.
  ///
  /// [role] ne sert qu'à lever une ambiguïté déjà signalée par le serveur —
  /// cas rare d'un même identifiant valable pour deux profils.
  Future<bool> login({
    required String email,
    required String password,
    UserRole? role,
  }) =>
      _run(() async {
        _ambiguousRoles = [];

        final response = role == null
            ? await _apiClient.loginUnified(email: email, password: password)
            : switch (role) {
                UserRole.transporteur =>
                  await _apiClient.login(email: email, password: password),
                UserRole.commercant =>
                  await _apiClient.loginMerchant(email: email, password: password),
                UserRole.flotte =>
                  throw AppException(code: AppError.fleetProfileUnavailable),
              };

        // Le serveur ne tranche pas à la place de l'utilisateur quand
        // plusieurs profils correspondent : il renvoie la liste.
        if (response['requiresRoleSelection'] == true) {
          _ambiguousRoles = (response['roles'] as List? ?? const [])
              .map((r) => UserRoleX.fromJwtType(r as String?))
              .whereType<UserRole>()
              .toList();
          throw AppException(code: AppError.multipleProfilesMatch);
        }

        // Le rôle vient de la réponse serveur, jamais d'une supposition.
        final user = response['user'];
        final resolved =
            UserRoleX.fromJwtType(user is Map ? user['type'] as String? : null) ??
                UserRoleX.fromJwtType(response['type'] as String?) ??
                role;

        if (resolved == null) {
          throw AppException(code: AppError.serverInvalidProfileType);
        }

        await _persist(role: resolved, response: response, email: email);
      });

  /// Inscription — réservée au commerçant.
  ///
  /// Un transporteur ne s'inscrit pas seul : son `Driver` Fleetbase est
  /// provisionné par un opérateur, et le compte Echango s'y rattache
  /// (docs/specs_app_transporteur.md §2.1).
  /// Message d'une demande **enregistrée mais pas encore validée**.
  ///
  /// ⚠️ Distinct d'`errorMessage`, et c'est tout l'intérêt : côté serveur,
  /// l'inscription d'un commerçant comme d'une entreprise se termine par un
  /// `forbidden('merchant_pending' | 'fleet_pending')` — un refus d'ENTRER, pas
  /// un échec d'inscription. Le compte existe.
  ///
  /// Sans cette distinction, une inscription réussie s'affichait en **bandeau
  /// rouge**, exactement comme un mot de passe trop court. Même famille que les
  /// dix refus qui s'affichaient comme des confirmations, corrigés le 31/07 —
  /// pris par l'autre bout.
  String? get pendingMessage => _pendingMessage;
  String? _pendingMessage;

  /// Inscription d'une **entreprise de transport**.
  ///
  /// Rend `true` quand la demande est enregistrée — y compris, et surtout,
  /// quand le serveur répond `fleet_pending` : c'est le chemin nominal.
  Future<bool> registerFleet({
    required String email,
    required String password,
    required String businessName,
    String? firstName,
    String? lastName,
    String? phone,
  }) =>
      _runPending(() => _apiClient.registerFleet(
            email: email,
            password: password,
            businessName: businessName,
            firstName: firstName,
            lastName: lastName,
            phone: phone,
          ));

  /// Inscription d'un **transporteur**, sur invitation.
  ///
  /// Elle délivre un jeton, contrairement aux deux autres : le transporteur est
  /// déjà connu du réseau — son `Driver` Fleetbase a été provisionné par un
  /// opérateur, et l'invitation prouve qu'il est bien la personne visée. Il n'y
  /// a rien de plus à valider.
  ///
  /// ⚠️ `registerDriverWithInvitation` était écrite côté client depuis le
  /// 28/07 et **n'avait aucun appelant** : un opérateur remettait un jeton
  /// d'invitation à un transporteur qui n'avait aucun écran pour s'en servir
  /// (revue du 01/08/2026, A1).
  Future<bool> registerDriver({
    required String invitationToken,
    required String email,
    required String password,
    String? firstName,
    String? lastName,
    String? phone,
  }) =>
      _run(() async {
        final response = await _apiClient.registerDriverWithInvitation(
          invitationToken: invitationToken,
          email: email,
          password: password,
          firstName: firstName,
          lastName: lastName,
          phone: phone,
        );
        await _persist(
            role: UserRole.transporteur, response: response, email: email);
      });

  /// Enveloppe des inscriptions **à validation** : le refus `*_pending` est un
  /// succès, tout autre refus est une erreur.
  Future<bool> _runPending(Future<void> Function() body) async {
    _isLoading = true;
    _errorMessage = null;
    _pendingMessage = null;
    notifyListeners();
    try {
      await body();
      return true;
    } on AppException catch (e) {
      // Le code fait autorité, jamais le statut HTTP : les deux refus sortent
      // en 403 comme n'importe quel autre.
      if (e.code == AppError.authMerchantPending ||
          e.code == AppError.authFleetPending) {
        _pendingMessage = translateErrorCode(e.code, _localeState.locale);
        return true;
      }
      _errorMessage = messageForError(e, _localeState.locale);
      return false;
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> registerMerchant({
    required String email,
    required String password,
    required String businessName,
    String? firstName,
    String? lastName,
    String? phone,
  }) =>
      // ⚠️ `_runPending` et non `_run` : le serveur termine cette inscription
      // par `merchant_pending`, donc `_run` la classait en ERREUR et l'écran
      // affichait une demande réussie en bandeau rouge.
      _runPending(() async {
        final response = await _apiClient.registerMerchant(
          email: email,
          password: password,
          businessName: businessName,
          firstName: firstName,
          lastName: lastName,
          phone: phone,
        );
        await _persist(
            role: UserRole.commercant, response: response, email: email);
        _displayName ??= businessName;
      });

  /// Travail à faire pendant que le jeton est encore valide, avant d'invalider
  /// la session.
  ///
  /// Sans ce point d'accroche, tout nettoyage déclenché par le changement
  /// d'état arrive trop tard : la session est déjà effacée et l'appel part
  /// sans jeton. C'est ce qui laisserait un transporteur déconnecté marqué
  /// « en ligne » côté Fleetbase, donc éligible à des courses que personne ne
  /// prendrait.
  Future<void> Function()? onBeforeLogout;

  Future<void> logout() async {
    try {
      await onBeforeLogout?.call();
    } catch (e) {
      // La déconnexion doit aboutir quoi qu'il arrive : un nettoyage qui échoue
      // ne doit pas retenir l'utilisateur dans une session dont il veut sortir.
      debugPrint('Nettoyage avant déconnexion incomplet : $e');
    }

    await _apiClient.clearSession();
    _status = SessionStatus.unauthenticated;
    _role = null;
    _userId = null;
    _displayName = null;
    _errorMessage = null;
    await _prefs.remove(_roleKey);
    await _prefs.remove(_userIdKey);
    await _prefs.remove(_displayNameKey);
    await _prefs.remove(_statusKey);
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
