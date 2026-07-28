class ApiConfig {
  // API Configuration
  //
  // Le BFF écoute sur 3001 (backend/bff/src/main.ts) et n'a AUCUN préfixe
  // global : les routes sont à la racine (/auth/..., /commercant/...).
  //
  // ⚠️ `localhost` désigne l'APPAREIL qui exécute l'app, pas la machine de
  // développement. Sur téléphone ou émulateur, il ne pointe donc sur rien —
  // c'est la cause n°1 des « Network error » au premier lancement.
  //
  //   Émulateur Android  : http://10.0.2.2:3001  (alias du loopback hôte)
  //   Téléphone physique : http://<IP-LAN-du-PC>:3001
  //   Desktop / web      : http://localhost:3001
  //
  // Surchargeable au lancement, pour ne pas éditer ce fichier à chaque
  // changement de support :
  //   flutter run --dart-define=BFF_BASE_URL=http://10.0.2.2:3001
  //
  // La valeur par défaut vise l'émulateur Android : c'est le support de test
  // le plus courant, et sur desktop l'oubli se voit tout de suite.
  static const String bffBaseUrl = String.fromEnvironment(
    'BFF_BASE_URL',
    defaultValue: 'http://10.0.2.2:3001',
  );

  /// Délai maximal d'une requête au BFF, en secondes. Appliqué globalement
  /// par le client HTTP (voir BffApiClient).
  static const int apiTimeout = 30;

  /// Distance minimale, en mètres, entre deux remontées de position. Filtre
  /// appliqué par Geolocator lui-même : en dessous, aucun appel réseau n'est
  /// fait. Trop bas, la batterie et le forfait y passent ; trop haut, le
  /// dispatch géospatial travaille sur une position périmée.
  static const double locationDistanceThreshold = 10.0;

  static const String appVersion = '0.1.0';
  static const String appName = 'Echango Delivery';
}
