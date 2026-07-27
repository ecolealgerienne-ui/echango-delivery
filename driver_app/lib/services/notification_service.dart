import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:logger/logger.dart';
import '../config/app_config.dart';
import 'auth_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  late final FirebaseMessaging _firebaseMessaging;
  final Logger _logger = Logger();

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
    // Request notification permission
    final settings = await _firebaseMessaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    _logger.i('Notification permission status: ${settings.authorizationStatus}');

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      _logger.i('Foreground message: ${message.notification?.title}');
      _handleOrderNotification(message.data);
    });

    // Handle background message tap
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _logger.i('Message opened: ${message.notification?.title}');
      _handleOrderNotification(message.data);
    });

    // Handle terminated app launch
    final initialMessage = await _firebaseMessaging.getInitialMessage();
    if (initialMessage != null) {
      _handleOrderNotification(initialMessage.data);
    }

    _logger.i('Notification service initialized');
  }

  Future<void> subscribeToDriverNotifications() async {
    try {
      final authService = AuthService();
      final driverId = authService.getDriverId();

      if (driverId == null) {
        _logger.w('Driver ID not found for notification subscription');
        return;
      }

      final topic = AppConfig.getDriverTopic(driverId);
      await _firebaseMessaging.subscribeToTopic(topic);
      _logger.i('Subscribed to topic: $topic');
    } catch (e) {
      _logger.e('Failed to subscribe to notifications: $e');
    }
  }

  Future<void> unsubscribeFromDriverNotifications() async {
    try {
      final authService = AuthService();
      final driverId = authService.getDriverId();

      if (driverId == null) {
        _logger.w('Driver ID not found for notification unsubscription');
        return;
      }

      final topic = AppConfig.getDriverTopic(driverId);
      await _firebaseMessaging.unsubscribeFromTopic(topic);
      _logger.i('Unsubscribed from topic: $topic');
    } catch (e) {
      _logger.e('Failed to unsubscribe from notifications: $e');
    }
  }

  Future<String?> getDeviceToken() async {
    try {
      final token = await _firebaseMessaging.getToken();
      _logger.i('Device token: $token');
      return token;
    } catch (e) {
      _logger.e('Failed to get device token: $e');
      return null;
    }
  }

  void setOnOrderNotification(Function(Map<String, dynamic>) callback) {
    _onOrderNotification = callback;
  }

  void _handleOrderNotification(Map<String, dynamic> data) {
    _logger.i('Handling order notification: $data');
    if (_onOrderNotification != null) {
      _onOrderNotification!(data);
    }
  }

  /// Handle background messages (called at app startup for background message)
  static Future<void> handleBackgroundMessage(RemoteMessage message) async {
    final logger = Logger();
    logger.i('Background message: ${message.notification?.title}');
  }
}
