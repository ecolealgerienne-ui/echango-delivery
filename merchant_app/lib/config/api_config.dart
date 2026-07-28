class ApiConfig {
  // ⚠️ `localhost` désigne l'APPAREIL qui exécute l'app, pas la machine de
  // développement. Sur émulateur il ne pointe sur rien — cause n°1 des
  // « Network error » au premier lancement (voir driver_app, même piège).
  //
  //   Émulateur Android  : http://10.0.2.2:3001  (alias du loopback hôte)
  //   Téléphone physique : http://<IP-LAN-du-PC>:3001
  //
  // Surchargeable au lancement :
  //   flutter run --dart-define=BFF_BASE_URL=http://10.0.2.2:3001
  static const String bffBaseUrl = String.fromEnvironment(
    'BFF_BASE_URL',
    defaultValue: 'http://10.0.2.2:3001',
  );

  static const int apiTimeout = 30;
  static const String appName = 'Echango Commerçant';
}
