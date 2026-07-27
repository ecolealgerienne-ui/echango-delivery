/// Logging utilities pour le debugging pendant le développement.
class AppLogger {
  static void debug(String tag, String message) {
    print('[DEBUG] [$tag] $message');
  }

  static void info(String tag, String message) {
    print('[INFO] [$tag] $message');
  }

  static void warn(String tag, String message) {
    print('[WARN] [$tag] $message');
  }

  static void error(String tag, String message, [dynamic error, StackTrace? stackTrace]) {
    print('[ERROR] [$tag] $message');
    if (error != null) print('Error: $error');
    if (stackTrace != null) print('StackTrace: $stackTrace');
  }
}
