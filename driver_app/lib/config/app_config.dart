class AppConfig {
  // API Configuration
  static const String bffBaseUrl = 'http://localhost:3000/api/v1';
  static const String fleetbaseApiUrl = 'http://localhost:8000/api/v1';

  // Timeouts (in seconds)
  static const int apiTimeout = 30;
  static const int locationUpdateInterval = 10;

  // Location Services
  static const double minLocationAccuracy = 10.0; // meters
  static const int maxLocationAge = 60000; // milliseconds

  // Notification Configuration
  static const String fcmTopicPrefix = 'echango_driver';

  // App Info
  static const String appVersion = '0.1.0';
  static const String appName = 'Echango Delivery';

  // Feature Flags
  static const bool enableDebugLogging = true;
  static const bool enableOfflineMode = true;

  /// Get Firebase topic name for driver
  static String getDriverTopic(String driverId) {
    return '${fcmTopicPrefix}_$driverId';
  }
}
