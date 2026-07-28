/// Logging utilities pour le debugging pendant le développement.
class AppLogger {
  static void debug(String tag, String message) {
    // ignore: avoid_print
    print('[DEBUG] [$tag] $message');
  }

  static void info(String tag, String message) {
    // ignore: avoid_print
    print('[INFO] [$tag] $message');
  }

  static void warn(String tag, String message) {
    // ignore: avoid_print
    print('[WARN] [$tag] $message');
  }

  static void error(String tag, String message, [dynamic error, StackTrace? stackTrace]) {
    // ignore: avoid_print
    print('[ERROR] [$tag] $message');
    if (error != null) {
      // ignore: avoid_print
      print('Error: $error');
    }
    if (stackTrace != null) {
      // ignore: avoid_print
      print('StackTrace: $stackTrace');
    }
  }
}
