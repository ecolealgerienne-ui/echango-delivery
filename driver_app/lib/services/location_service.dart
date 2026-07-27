import 'package:geolocator/geolocator.dart';
import 'package:logger/logger.dart';
import 'bff_client.dart';

class LocationService {
  static final LocationService _instance = LocationService._internal();
  final Logger _logger = Logger();
  late final BFFClient _bffClient;

  bool _isTracking = false;
  Stream<Position>? _positionStream;

  LocationService._internal() {
    _bffClient = BFFClient();
  }

  factory LocationService() {
    return _instance;
  }

  Future<void> initialize() async {
    await _requestLocationPermission();
  }

  Future<bool> _requestLocationPermission() async {
    final permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      final request = await Geolocator.requestPermission();
      if (request != LocationPermission.whileInUse &&
          request != LocationPermission.always) {
        _logger.w('Location permission denied');
        return false;
      }
    } else if (permission == LocationPermission.deniedForever) {
      _logger.e('Location permission permanently denied');
      await Geolocator.openLocationSettings();
      return false;
    }

    return true;
  }

  Future<Position?> getCurrentPosition() async {
    try {
      final hasPermission = await _requestLocationPermission();
      if (!hasPermission) return null;

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 10),
      );

      _logger.i('Current position: ${position.latitude}, ${position.longitude}');
      return position;
    } catch (e) {
      _logger.e('Failed to get current position: $e');
      return null;
    }
  }

  Future<void> startBackgroundTracking() async {
    if (_isTracking) {
      _logger.w('Background tracking already active');
      return;
    }

    try {
      final hasPermission = await _requestLocationPermission();
      if (!hasPermission) return;

      _isTracking = true;
      _logger.i('Starting background location tracking');

      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 10, // Update every 10 meters
        ),
      );

      _positionStream?.listen((Position position) {
        _logger.d(
          'Location update: ${position.latitude}, ${position.longitude}',
        );
        _updateDriverLocation(position);
      });
    } catch (e) {
      _logger.e('Failed to start background tracking: $e');
      _isTracking = false;
    }
  }

  Future<void> stopBackgroundTracking() async {
    if (!_isTracking) {
      _logger.w('Background tracking not active');
      return;
    }

    try {
      _isTracking = false;
      _logger.i('Stopping background location tracking');
    } catch (e) {
      _logger.e('Failed to stop background tracking: $e');
    }
  }

  bool get isTracking => _isTracking;

  Future<void> _updateDriverLocation(Position position) async {
    try {
      await _bffClient.updateDriverLocation(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } catch (e) {
      _logger.e('Failed to update driver location: $e');
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
      _logger.e('Failed to calculate distance: $e');
      return 0;
    }
  }
}
