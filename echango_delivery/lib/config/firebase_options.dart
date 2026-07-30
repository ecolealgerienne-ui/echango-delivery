import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Configuration Firebase.
///
/// ⚠️ Ce fichier est un **gabarit** : les valeurs sont des marqueurs. Le
/// remplacer par celui que génère `flutterfire configure` pour activer les
/// notifications push.
class DefaultFirebaseOptions {
  /// Marqueur reconnaissable des valeurs non renseignées.
  static const _placeholder = 'YOUR_';

  /// Faux tant que le gabarit n'a pas été remplacé.
  ///
  /// Sans ce contrôle, `Firebase.initializeApp` **réussit** avec ces valeurs :
  /// elles sont structurellement valides, seule leur authenticité est fausse.
  /// L'application se retrouvait donc à moitié initialisée — un isolate
  /// d'arrière-plan créé, une permission demandée à l'utilisateur — pour un
  /// service qui échouait ensuite sur chaque appel réseau
  /// (« Please set a valid API key »). Mieux vaut ne pas démarrer Firebase du
  /// tout que faire semblant.
  static bool get isConfigured => !currentPlatform.apiKey.startsWith(_placeholder);

  /// Configuration de la plateforme courante.
  ///
  /// L'ancienne version renvoyait `web` inconditionnellement : sur Android,
  /// Firebase recevait donc un `appId` de type web, qu'il n'aurait pas accepté
  /// même avec de vraies valeurs.
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => android,
      TargetPlatform.iOS => ios,
      _ => web,
    };
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'YOUR_WEB_API_KEY',
    appId: '1:YOUR_PROJECT_NUMBER:web:YOUR_APP_ID',
    messagingSenderId: 'YOUR_MESSAGING_SENDER_ID',
    projectId: 'YOUR_PROJECT_ID',
    authDomain: 'YOUR_AUTH_DOMAIN',
    databaseURL: 'YOUR_DATABASE_URL',
    storageBucket: 'YOUR_STORAGE_BUCKET',
    measurementId: 'YOUR_MEASUREMENT_ID',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'YOUR_ANDROID_API_KEY',
    appId: '1:YOUR_PROJECT_NUMBER:android:YOUR_APP_ID',
    messagingSenderId: 'YOUR_MESSAGING_SENDER_ID',
    projectId: 'YOUR_PROJECT_ID',
    databaseURL: 'YOUR_DATABASE_URL',
    storageBucket: 'YOUR_STORAGE_BUCKET',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'YOUR_IOS_API_KEY',
    appId: '1:YOUR_PROJECT_NUMBER:ios:YOUR_APP_ID',
    messagingSenderId: 'YOUR_MESSAGING_SENDER_ID',
    projectId: 'YOUR_PROJECT_ID',
    databaseURL: 'YOUR_DATABASE_URL',
    storageBucket: 'YOUR_STORAGE_BUCKET',
    iosBundleId: 'com.echango.driver',
  );
}
