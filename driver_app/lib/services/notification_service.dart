import 'package:firebase_messaging/firebase_messaging.dart';

import '../utils/logger.dart';

/// Service pour gérer Firebase Cloud Messaging et les notifications push.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  late final FirebaseMessaging _firebaseMessaging;

  static Function(Map<String, dynamic>)? _onOrderNotification;

  NotificationService._internal() {
    _firebaseMessaging = FirebaseMessaging.instance;
  }

  factory NotificationService() {
    return _instance;
  }

  static Future<void> initialize() async {
    final instance = NotificationService();
    await instance._initializeFirebase();
  }

  Future<void> _initializeFirebase() async {
    try {
      // Demande les permissions de notification
      final settings = await _firebaseMessaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      AppLogger.info('NotificationService', 'Permission status: ${settings.authorizationStatus}');

      // Écoute les messages au premier plan
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        AppLogger.info('NotificationService', 'Foreground message: ${message.notification?.title}');
        _handleOrderNotification(message.data);
      });

      // Écoute l'ouverture de l'app via notification
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        AppLogger.info('NotificationService', 'Message opened: ${message.notification?.title}');
        _handleOrderNotification(message.data);
      });

      // Vérifie si l'app a été lancée via une notification
      final initialMessage = await _firebaseMessaging.getInitialMessage();
      if (initialMessage != null) {
        _handleOrderNotification(initialMessage.data);
      }

      AppLogger.info('NotificationService', 'Initialization complete');
    } catch (e) {
      AppLogger.error('NotificationService', 'Initialization failed', e);
    }
  }

  Future<void> subscribeToDriverNotifications(String driverId) async {
    try {
      final topic = 'echango_driver_$driverId';
      await _firebaseMessaging.subscribeToTopic(topic);
      AppLogger.info('NotificationService', 'Subscribed to topic: $topic');
    } catch (e) {
      AppLogger.error('NotificationService', 'Subscription failed', e);
    }
  }

  Future<void> unsubscribeFromDriverNotifications(String driverId) async {
    try {
      final topic = 'echango_driver_$driverId';
      await _firebaseMessaging.unsubscribeFromTopic(topic);
      AppLogger.info('NotificationService', 'Unsubscribed from topic: $topic');
    } catch (e) {
      AppLogger.error('NotificationService', 'Unsubscription failed', e);
    }
  }

  Future<String?> getDeviceToken() async {
    try {
      final token = await _firebaseMessaging.getToken();
      AppLogger.info('NotificationService', 'Device token: $token');
      return token;
    } catch (e) {
      AppLogger.error('NotificationService', 'Failed to get device token', e);
      return null;
    }
  }

  void setOnOrderNotification(Function(Map<String, dynamic>) callback) {
    _onOrderNotification = callback;
  }

  void _handleOrderNotification(Map<String, dynamic> data) {
    AppLogger.info('NotificationService', 'Handling order notification: $data');
    if (_onOrderNotification != null) {
      _onOrderNotification!(data);
    }
  }

  /// Handle background messages (called at app startup).
  static Future<void> handleBackgroundMessage(RemoteMessage message) async {
    AppLogger.info('NotificationService', 'Background message: ${message.notification?.title}');
  }
}
