import 'package:geolocator/geolocator.dart';

import '../config/api_config.dart';
import '../utils/logger.dart';
import 'bff_api_client.dart';

/// Service pour gérer la géolocalisation et le suivi en tâche de fond.
class LocationService {
  static final LocationService _instance = LocationService._internal();
  late final BffApiClient _apiClient;
  bool _isTracking = false;
  Stream<Position>? _positionStream;

  LocationService._internal();

  factory LocationService() {
    return _instance;
  }

  Future<void> initialize(BffApiClient apiClient) async {
    _apiClient = apiClient;
    await _requestLocationPermission();
  }

  Future<bool> _requestLocationPermission() async {
    try {
      final permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        final request = await Geolocator.requestPermission();
        if (request != LocationPermission.whileInUse && request != LocationPermission.always) {
          AppLogger.warn('LocationService', 'Location permission denied');
          return false;
        }
      } else if (permission == LocationPermission.deniedForever) {
        AppLogger.error('LocationService', 'Location permission permanently denied');
        await Geolocator.openLocationSettings();
        return false;
      }

      return true;
    } catch (e) {
      AppLogger.error('LocationService', 'Permission request failed', e);
      return false;
    }
  }

  Future<Position?> getCurrentPosition() async {
    try {
      final hasPermission = await _requestLocationPermission();
      if (!hasPermission) return null;

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 10),
      );

      AppLogger.info('LocationService', 'Current position: ${position.latitude}, ${position.longitude}');
      return position;
    } catch (e) {
      AppLogger.error('LocationService', 'Failed to get position', e);
      return null;
    }
  }

  Future<void> startBackgroundTracking() async {
    if (_isTracking) {
      AppLogger.warn('LocationService', 'Background tracking already active');
      return;
    }

    try {
      final hasPermission = await _requestLocationPermission();
      if (!hasPermission) return;

      _isTracking = true;
      AppLogger.info('LocationService', 'Starting background location tracking');

      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: ApiConfig.locationDistanceThreshold,
        ),
      );

      _positionStream?.listen((Position position) {
        AppLogger.info(
          'LocationService',
          'Location update: ${position.latitude}, ${position.longitude}',
        );
        _updateDriverLocation(position);
      });
    } catch (e) {
      AppLogger.error('LocationService', 'Failed to start tracking', e);
      _isTracking = false;
    }
  }

  Future<void> stopBackgroundTracking() async {
    if (!_isTracking) {
      AppLogger.warn('LocationService', 'Background tracking not active');
      return;
    }

    try {
      _isTracking = false;
      AppLogger.info('LocationService', 'Stopping background location tracking');
    } catch (e) {
      AppLogger.error('LocationService', 'Failed to stop tracking', e);
    }
  }

  bool get isTracking => _isTracking;

  Future<void> _updateDriverLocation(Position position) async {
    try {
      await _apiClient.updateDriverLocation(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } catch (e) {
      AppLogger.error('LocationService', 'Failed to update location', e);
    }
  }

  Future<double> calculateDistance({
    required double startLatitude,
    required double startLongitude,
    required double endLatitude,
    required double endLongitude,
  }) async {
    try {
      final distance = await Geolocator.distanceBetween(
        startLatitude,
        startLongitude,
        endLatitude,
        endLongitude,
      );
      return distance;
    } catch (e) {
      AppLogger.error('LocationService', 'Failed to calculate distance', e);
      return 0;
    }
  }
}
