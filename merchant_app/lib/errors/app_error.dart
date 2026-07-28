/// Constantes d'erreurs centralisées pour l'app Echango Delivery Driver.
/// Utilisées pour mapper les erreurs serveur vers les codes locaux et
/// permettre une gestion d'erreurs cohérente dans toute l'app.
class AppError {
  AppError._();

  // Authentication errors
  static const String authInvalidCredentials = 'auth.invalid_credentials';
  static const String authSessionExpired = 'auth.session_expired';
  static const String authPhoneAlreadyUsed = 'auth.phone_already_registered';
  static const String authInvalidOtp = 'auth.invalid_otp';
  static const String authOtpExpired = 'auth.otp_expired';

  // Validation errors
  static const String validationRequired = 'validation.required';
  static const String validationInvalidEmail = 'validation.invalid_email';
  static const String validationInvalidPhone = 'validation.invalid_phone';

  // Order errors
  static const String orderNotFound = 'order.not_found';
  static const String orderAlreadyAccepted = 'order.already_accepted';
  static const String orderAlreadyCompleted = 'order.already_completed';
  static const String orderStatusInvalid = 'order.status_invalid';

  // Location errors
  static const String locationPermissionDenied = 'location.permission_denied';
  static const String locationUnavailable = 'location.unavailable';

  // Notification errors
  static const String notificationSubscriptionFailed = 'notification.subscription_failed';

  // Network errors
  static const String networkError = 'network.error';
  static const String serverError = 'server.error';
  static const String timeoutError = 'timeout.error';
  static const String notFound = 'not_found';

  // Generic
  static const String unknown = 'error.unknown';
}

/// Exception wrapper pour les erreurs d'app avec mappage d'erreurs.
class AppException implements Exception {
  final String code;
  final String? message;
  final dynamic originalError;

  AppException({
    required this.code,
    this.message,
    this.originalError,
  });

  @override
  String toString() => message ?? code;
}
