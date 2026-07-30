import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../config/api_config.dart';
import '../utils/logger.dart';
import 'bff_api_client.dart';

/// Suivi de position du transporteur, remonté au BFF puis à Fleetbase.
///
/// Le dispatch géospatial de Fleetbase choisit à qui diffuser une course à
/// partir de la dernière position connue (specs_echango_delivery.md §3.2) :
/// un driver qui n'émet pas n'est pas seulement invisible sur la carte, il ne
/// reçoit aucune course.
class LocationService {
  static final LocationService _instance = LocationService._internal();
  BffApiClient? _apiClient;
  StreamSubscription<Position>? _subscription;

  LocationService._internal();

  factory LocationService() {
    return _instance;
  }

  Future<void> initialize(BffApiClient apiClient) async {
    _apiClient = apiClient;
  }

  /// Demande la permission de localisation.
  ///
  /// Ne renvoie `true` que si la permission couvre réellement le suivi : un
  /// `denied` transformé en `whileInUse` par l'utilisateur suffit au premier
  /// plan, `deniedForever` ne se rattrape que dans les réglages système.
  Future<bool> requestPermission() async {
    try {
      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        AppLogger.error('LocationService', 'Permission refusée définitivement');
        return false;
      }

      final granted = permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;

      if (!granted) {
        AppLogger.warn('LocationService', 'Permission de localisation refusée');
      }

      return granted;
    } catch (e) {
      AppLogger.error('LocationService', 'Échec de la demande de permission', e);
      return false;
    }
  }

  Future<Position?> getCurrentPosition() async {
    try {
      if (!await requestPermission()) return null;

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (e) {
      AppLogger.error('LocationService', 'Position indisponible', e);
      return null;
    }
  }

  /// Démarre le suivi. Renvoie `false` si la permission manque — l'appelant
  /// doit alors le dire à l'utilisateur, pas se mettre « en ligne » en
  /// silence sans jamais émettre.
  Future<bool> startTracking() async {
    if (_subscription != null) return true;

    if (!await requestPermission()) return false;

    try {
      _subscription = Geolocator.getPositionStream(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: ApiConfig.locationDistanceThreshold.toInt(),
        ),
      ).listen(
        _pushPosition,
        onError: (Object e) {
          AppLogger.error('LocationService', 'Flux de position interrompu', e);
        },
      );

      AppLogger.info('LocationService', 'Suivi de position démarré');
      return true;
    } catch (e) {
      AppLogger.error('LocationService', 'Impossible de démarrer le suivi', e);
      return false;
    }
  }

  /// Arrête le suivi.
  ///
  /// L'abonnement est bien annulé, et pas seulement un booléen remis à faux :
  /// la version précédente laissait le flux Geolocator actif, donc le GPS
  /// allumé et des positions envoyées après la déconnexion — batterie vidée,
  /// et un driver qui se croit hors ligne continuait d'alimenter le dispatch.
  Future<void> stopTracking() async {
    final subscription = _subscription;
    _subscription = null;

    if (subscription == null) return;

    await subscription.cancel();
    AppLogger.info('LocationService', 'Suivi de position arrêté');
  }

  bool get isTracking => _subscription != null;

  /// Envoie une position au BFF, une fois, sans démarrer le suivi. Utilisé au
  /// passage en ligne pour que le dispatch dispose d'un point tout de suite,
  /// sans attendre le premier franchissement du seuil de distance.
  Future<void> pushCurrentPosition() async {
    final position = await getCurrentPosition();
    if (position != null) await _pushPosition(position);
  }

  Future<void> _pushPosition(Position position) async {
    final client = _apiClient;
    if (client == null) {
      AppLogger.error('LocationService', 'Service non initialisé — position perdue');
      return;
    }

    try {
      await client.updateDriverLocation(
        latitude: position.latitude,
        longitude: position.longitude,
        heading: position.heading,
        speed: position.speed,
      );
    } catch (e) {
      // Une position perdue n'est pas rattrapée : la suivante la remplace de
      // toute façon. Échouer bruyamment ici couperait le suivi sur une simple
      // coupure réseau.
      AppLogger.warn('LocationService', 'Position non remontée : $e');
    }
  }

  double distanceBetween({
    required double startLatitude,
    required double startLongitude,
    required double endLatitude,
    required double endLongitude,
  }) {
    return Geolocator.distanceBetween(
      startLatitude,
      startLongitude,
      endLatitude,
      endLongitude,
    );
  }
}
