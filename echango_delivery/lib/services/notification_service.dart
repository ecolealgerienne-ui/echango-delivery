import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../utils/logger.dart';

/// Point d'entrée FCM en tâche de fond.
///
/// Doit rester une fonction de premier niveau annotée `vm:entry-point` :
/// Flutter démarre un isolate neuf pour la traiter, sans l'état de l'app.
/// On se contente donc de tracer — le rafraîchissement réel a lieu au retour
/// au premier plan, où l'app dispose de sa session.
@pragma('vm:entry-point')
Future<void> handleBackgroundMessage(RemoteMessage message) async {
  AppLogger.info('NotificationService', 'Message en tâche de fond : ${message.data}');
}

/// Notifications push Fleetbase (`OrderPing`).
///
/// Rôle exact, décidé en §11.1 de specs_app_transporteur.md : le push est un
/// **déclencheur de rafraîchissement**, jamais une source de données. Le
/// contenu du message n'est pas affiché tel quel ni inséré dans la liste —
/// il dit seulement « quelque chose a changé, redemande au BFF ». Ça évite
/// d'avoir à faire confiance à un payload pour l'anti-IDOR, et l'app reste
/// correcte quand un push se perd.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() => _instance;

  NotificationService._internal();

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  bool _available = false;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// Faux quand Firebase n'a pas pu être initialisé (configuration absente en
  /// développement). Tout le reste de l'app doit continuer de fonctionner.
  bool get isAvailable => _available;

  /// Appelé quand un message signale un changement de commande.
  void Function()? onOrderEvent;

  /// Appelé quand Firebase émet un nouveau jeton, y compris à la première
  /// obtention. C'est ce qui doit déclencher l'enregistrement côté BFF.
  void Function(String token)? onTokenChanged;

  Future<void> initialize() async {
    // Firebase pas démarré (configuration absente) : ne rien tenter. Sans ce
    // contrôle, chaque connexion transporteur produit une exception bruyante
    // pour une fonctionnalité qu'on sait indisponible.
    if (Firebase.apps.isEmpty) {
      _available = false;
      AppLogger.info('NotificationService', 'Firebase absent — push désactivé');
      return;
    }

    try {
      FirebaseMessaging.onBackgroundMessage(handleBackgroundMessage);

      final settings = await _messaging.requestPermission();
      AppLogger.info(
        'NotificationService',
        'Permission notifications : ${settings.authorizationStatus}',
      );

      _subscriptions.add(FirebaseMessaging.onMessage.listen(_handle));
      _subscriptions.add(FirebaseMessaging.onMessageOpenedApp.listen(_handle));
      _subscriptions.add(_messaging.onTokenRefresh.listen((token) {
        AppLogger.info('NotificationService', 'Jeton FCM renouvelé');
        onTokenChanged?.call(token);
      }));

      final initial = await _messaging.getInitialMessage();
      if (initial != null) _handle(initial);

      _available = true;
    } catch (e) {
      // Pas de push : l'app reste utilisable, le driver rafraîchit à la main
      // et le repli par polling prend le relais.
      _available = false;
      AppLogger.warn('NotificationService', 'Notifications indisponibles : $e');
    }
  }

  /// Jeton de cet appareil, ou `null` si Firebase n'est pas configuré.
  Future<String?> currentToken() async {
    if (!_available) return null;
    try {
      return await _messaging.getToken();
    } catch (e) {
      AppLogger.warn('NotificationService', 'Jeton FCM indisponible : $e');
      return null;
    }
  }

  /// Coupe la réception à la déconnexion : le jeton est supprimé côté Firebase
  /// pour que l'appareil cesse d'être adressable, en complément de la purge du
  /// jeton côté BFF.
  Future<void> release() async {
    if (!_available) return;
    try {
      await _messaging.deleteToken();
    } catch (e) {
      AppLogger.warn('NotificationService', 'Suppression du jeton FCM impossible : $e');
    }
  }

  void _handle(RemoteMessage message) {
    AppLogger.info('NotificationService', 'Message reçu : ${message.data}');
    onOrderEvent?.call();
  }

  @visibleForTesting
  Future<void> dispose() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
  }
}
