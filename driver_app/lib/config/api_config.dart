class ApiConfig {
  // API Configuration
  //
  // Le BFF écoute sur 3001 (backend/bff/src/main.ts) et n'a AUCUN préfixe
  // global : les routes sont à la racine (/auth/..., /commercant/...).
  //
  // ⚠️ Sur un appareil physique, `localhost` désigne le téléphone lui-même.
  // Utiliser l'IP de la machine hôte (ex. http://192.168.1.20:3001), ou
  // http://10.0.2.2:3001 sur un émulateur Android.
  static const String bffBaseUrl = 'http://localhost:3001';

  // L'app n'appelle JAMAIS Fleetbase directement — tout passe par le BFF
  // (decision specs_app_transporteur.md §2.1 : aucun credential Fleetbase
  // dans un client final). Conservé pour information/debug uniquement.
  static const String fleetbaseApiUrl = 'http://localhost:8000';

  // Timeouts (in seconds)
  static const int apiTimeout = 30;
  static const int locationUpdateInterval = 10;

  // Location Services
  static const double locationDistanceThreshold = 10.0; // meters
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
