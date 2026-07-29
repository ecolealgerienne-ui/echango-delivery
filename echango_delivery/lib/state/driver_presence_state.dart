import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../errors/app_error.dart';
import '../errors/error_translator.dart';
import '../services/bff_api_client.dart';
import '../services/foreground_service.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import '../utils/logger.dart';
import 'locale_state.dart';
import 'order_state.dart';

/// Fréquence du repli par interrogation du BFF quand l'app est au premier plan.
///
/// Le push reste le canal principal (§11.1) ; ce repli existe parce qu'il
/// échoue silencieusement dans trop de cas réels pour qu'on parie dessus :
/// Firebase non configuré, permission notifications refusée, jeton non encore
/// renouvelé, message perdu. Sans lui, un driver ne voit une nouvelle course
/// que s'il tire l'écran vers le bas au bon moment.
const _pollInterval = Duration(seconds: 45);

/// Présence du transporteur : disponibilité, position, réception des courses.
///
/// Regroupé ici plutôt que dispersé dans les écrans parce que les trois vont
/// ensemble et n'ont de sens que combinés — être « en ligne » sans émettre de
/// position ne sert à rien (le dispatch est géographique), et recevoir un push
/// sans rafraîchir la liste ne montre rien à l'écran.
class DriverPresenceState extends ChangeNotifier {
  final BffApiClient _apiClient;
  final OrderState _orderState;
  final LocationService _location;
  final NotificationService _notifications;
  final LocaleState _localeState;
  final DriverForegroundService _foregroundService = DriverForegroundService();

  DriverPresenceState({
    required BffApiClient apiClient,
    required OrderState orderState,
    required LocaleState localeState,
    LocationService? location,
    NotificationService? notifications,
  })  : _apiClient = apiClient,
        _orderState = orderState,
        _localeState = localeState,
        _location = location ?? LocationService(),
        _notifications = notifications ?? NotificationService();

  /// Message d'erreur générique de la langue courante, pour les échecs qui ne
  /// portent aucun `code` serveur (erreur de parsing, exception inattendue).
  String get _genericError => translateErrorCode(AppError.unknown, _localeState.locale);

  /// `null` tant que la disponibilité réelle n'a pas été lue côté serveur.
  /// Afficher « hors ligne » par défaut mentirait dans le sens dangereux :
  /// le driver ne réagirait pas à une course qu'il reçoit pourtant.
  bool? _online;
  String? _vehicleType;
  bool _isBusy = false;
  bool _sessionActive = false;
  bool _foreground = true;
  String? _errorMessage;
  Timer? _pollTimer;

  bool? get online => _online;

  /// Catégorie de véhicule déclarée. `null` = non déclarée, le transporteur
  /// voit alors toutes les courses.
  String? get vehicleType => _vehicleType;
  bool get isBusy => _isBusy;
  bool get isTracking => _location.isTracking;
  String? get errorMessage => _errorMessage;

  /// Vraie seulement quand le canal push fonctionne. L'écran s'en sert pour
  /// prévenir le driver qu'il devra rafraîchir lui-même.
  bool get pushAvailable => _notifications.isAvailable;

  /// Démarre la présence après une connexion transporteur (ou une session
  /// restaurée au lancement). Idempotent.
  Future<void> start() async {
    if (_sessionActive) return;
    _sessionActive = true;

    _notifications.onOrderEvent = _onRemoteChange;
    _notifications.onTokenChanged = _registerToken;

    // Ici et pas dans `main()` : l'initialisation demande la permission de
    // notification, donc elle attend une réponse de l'utilisateur. La placer
    // avant `runApp` bloquait le démarrage sur un écran noir. Ici, l'interface
    // est déjà à l'écran et seul le persona concerné est sollicité — un
    // commerçant n'a rien à voir avec les notifications de course.
    await _notifications.initialize();

    await _syncDeviceToken();
    await refreshAvailability();

    // Le suivi ne démarre que si le serveur confirme que ce driver est en
    // ligne : allumer le GPS d'un driver hors service viderait sa batterie
    // pour rien.
    if (_online == true) {
      await _location.startTracking();
      await _foregroundService.start();
    }

    _restartPolling();
  }

  /// Coupe tout à la déconnexion.
  ///
  /// L'ordre compte : passer hors ligne d'abord, pendant que le jeton est
  /// encore valide. Un driver déconnecté qui resterait « en ligne » côté
  /// Fleetbase continuerait de se voir attribuer des courses que personne ne
  /// prendrait.
  Future<void> stop() async {
    if (!_sessionActive) return;

    if (_online == true) {
      try {
        await _apiClient.setOnline(false);
      } catch (e) {
        AppLogger.warn('DriverPresence', 'Passage hors ligne impossible : $e');
      }
    }

    _sessionActive = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _notifications.onOrderEvent = null;
    _notifications.onTokenChanged = null;
    await _location.stopTracking();
    // Sans ça, la notification « Vous êtes en ligne » survivrait à la
    // déconnexion, affirmant à l'écran verrouillé du transporteur exactement
    // le contraire de son état réel.
    await _foregroundService.stop();
    await _notifications.release();

    _online = null;
    // Sans cette remise à zéro, le transporteur suivant à se connecter sur le
    // même appareil héritait de la catégorie de véhicule du précédent, et
    // voyait donc une liste de courses filtrée sur un critère qui n'est pas le
    // sien.
    _vehicleType = null;
    _errorMessage = null;
    notifyListeners();
  }

  /// Lit la disponibilité côté serveur. `online` reste `null` si Fleetbase est
  /// injoignable — voir TransporteurService.getProfile.
  Future<void> refreshAvailability() async {
    try {
      final profile = await _apiClient.getDriver();
      final value = profile['online'];
      _online = value is bool ? value : null;
      _vehicleType = profile['vehicleType'] as String?;
      // Sans ça, une erreur passagère resterait affichée en bandeau bien après
      // que la lecture a recommencé à fonctionner.
      _errorMessage = null;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
    } catch (e) {
      AppLogger.warn('DriverPresence', 'Profil illisible : $e');
    }
    notifyListeners();
  }

  /// Bascule la disponibilité.
  ///
  /// L'état local ne bouge qu'après confirmation du serveur : un interrupteur
  /// qui bascule visuellement sur un appel échoué ferait croire au driver
  /// qu'il est en service alors que le dispatch l'ignore.
  Future<bool> setOnline(bool value) async {
    if (_isBusy) return false;

    // Se déclarer en ligne sans pouvoir émettre de position revient à être
    // invisible du dispatch géospatial : autant le dire tout de suite.
    if (value && !await _location.requestPermission()) {
      _errorMessage =
          translateErrorCode(AppError.locationPermissionDenied, _localeState.locale);
      notifyListeners();
      return false;
    }

    // La notification permanente n'est pas un confort : Android n'autorise pas
    // de service au premier plan sans elle, donc son refus signifie que le
    // suivi s'arrêtera à chaque extinction d'écran. On prévient plutôt que de
    // laisser croire à un service continu.
    //
    // Non bloquant : le suivi fonctionne au premier plan, et refuser de passer
    // en ligne pour ça priverait le transporteur de courses. L'avertissement
    // est gardé de côté puis réappliqué après la remise à zéro ci-dessous, qui
    // l'effacerait sinon.
    String? warning;
    if (value && !await _foregroundService.requestPermissions()) {
      warning =
          translateErrorCode(AppError.foregroundServiceDenied, _localeState.locale);
    }

    _isBusy = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _apiClient.setOnline(value);
      _online = value;

      if (value) {
        await _location.startTracking();
        // Le service au premier plan et le suivi GPS vont ensemble : sans lui,
        // Android suspend le processus dès que l'écran s'éteint et le suivi
        // s'arrête sans rien signaler.
        await _foregroundService.start();
        // Un premier point tout de suite : sans ça le driver reste invisible
        // jusqu'à ce qu'il se déplace du seuil de distance configuré.
        await _location.pushCurrentPosition();
      } else {
        await _location.stopTracking();
        await _foregroundService.stop();
      }

      _restartPolling();
      await _orderState.loadOrders();
      _errorMessage = warning;
      return true;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
      return false;
    } catch (e) {
      _errorMessage = _genericError;
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Déclare la catégorie de véhicule. Filtre les courses proposées : une
  /// livraison exigeant un utilitaire n'est pas montrée à une moto.
  Future<bool> setVehicleType(String? value) async {
    try {
      await _apiClient.setVehicleType(value);
      _vehicleType = value;
      notifyListeners();
      // Les opportunités visibles changent avec la déclaration : recharger,
      // sinon l'écran garde une liste qui ne correspond plus au filtre.
      await _orderState.loadOrders();
      return true;
    } catch (e) {
      _errorMessage = _genericError;
      notifyListeners();
      return false;
    }
  }

  /// À appeler sur les transitions de cycle de vie de l'app.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _restartPolling();

    // Au retour au premier plan, l'app peut avoir manqué des push : on
    // rattrape immédiatement au lieu d'attendre le prochain tour de polling.
    if (foreground && _sessionActive) {
      _onRemoteChange();
    }
  }

  Future<void> _syncDeviceToken() async {
    final token = await _notifications.currentToken();
    if (token != null) await _registerToken(token);
  }

  Future<void> _registerToken(String token) async {
    try {
      await _apiClient.registerDeviceToken(
        token: token,
        platform: Platform.isIOS ? 'ios' : 'android',
      );
      AppLogger.info('DriverPresence', 'Jeton push enregistré côté BFF');
    } catch (e) {
      // Sans jeton enregistré il n'y a pas de push, mais le polling couvre le
      // besoin : ce n'est pas une raison de bloquer la connexion.
      AppLogger.warn('DriverPresence', 'Enregistrement du jeton push échoué : $e');
    }
  }

  void _onRemoteChange() {
    if (!_sessionActive) return;
    _orderState.loadOrders();
  }

  /// Le polling ne tourne qu'au premier plan et pour un driver en ligne — un
  /// driver hors service n'a rien à rafraîchir, et en arrière-plan c'est le
  /// push qui prend le relais.
  void _restartPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;

    if (!_sessionActive || !_foreground || _online != true) return;

    _pollTimer = Timer.periodic(_pollInterval, (_) => _orderState.loadOrders());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _notifications.onOrderEvent = null;
    _notifications.onTokenChanged = null;
    super.dispose();
  }
}
