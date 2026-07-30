import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../utils/logger.dart';

/// Service au premier plan qui maintient le suivi de position quand l'app
/// n'est plus à l'écran.
///
/// Sans lui, Android suspend le processus dès que le transporteur passe à une
/// autre application ou éteint son écran : l'abonnement Geolocator cesse
/// d'émettre, et le dispatch géospatial travaille sur une position figée.
/// C'est le mode d'échec le plus insidieux du profil transporteur — tout a
/// l'air de fonctionner tant qu'on regarde l'écran, ce qui est précisément le
/// moment où le problème n'existe pas.
///
/// Volontairement **sans `TaskHandler`** : on n'a pas besoin d'exécuter du
/// code dans un isolate séparé, seulement d'empêcher le système de tuer le
/// processus. L'abonnement GPS de `LocationService` continue alors de tourner
/// dans l'isolate principal, avec la session et le client HTTP déjà en place.
/// Un isolate séparé imposerait de re-créer les deux et de faire transiter les
/// positions par des messages, pour aucun gain.
class DriverForegroundService {
  static final DriverForegroundService _instance =
      DriverForegroundService._internal();
  factory DriverForegroundService() => _instance;
  DriverForegroundService._internal();

  bool _initialized = false;

  void _ensureInitialized() {
    if (_initialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'echango_presence',
        channelName: 'Disponibilité transporteur',
        channelDescription:
            'Maintient le partage de position pendant que vous êtes en ligne.',
        // Discret volontairement : cette notification est permanente pendant
        // tout un service. La faire sonner ou vibrer la rendrait odieuse et
        // pousserait le transporteur à la couper — donc à se rendre invisible.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: const ForegroundTaskOptions(
        // Aucun événement périodique : le service ne sert qu'à garder le
        // processus vivant, le rythme des positions est celui du filtre de
        // distance de Geolocator.
        interval: 60000,
        isOnceEvent: false,
        // Ne pas repartir au démarrage du téléphone : être « en ligne » est
        // une décision du transporteur, pas un état qu'on lui rétablit à son
        // insu — il se retrouverait éligible à des courses sans le savoir.
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );

    _initialized = true;
  }

  /// Demande les autorisations nécessaires.
  ///
  /// Renvoie `false` si la notification est refusée : sans elle, Android ne
  /// laisse pas tourner de service au premier plan.
  Future<bool> requestPermissions() async {
    _ensureInitialized();

    try {
      final status = await FlutterForegroundTask.checkNotificationPermission();
      if (status != NotificationPermission.granted) {
        final granted = await FlutterForegroundTask.requestNotificationPermission();
        if (granted != NotificationPermission.granted) {
          AppLogger.warn('ForegroundService', 'Notification refusée');
          return false;
        }
      }

      // Facultatif mais déterminant en pratique : sans exemption, les
      // optimisations constructeur (Xiaomi, Huawei, Samsung) coupent le
      // service après quelques minutes d'écran éteint. On demande, on
      // n'échoue pas si c'est refusé.
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }

      return true;
    } catch (e) {
      AppLogger.error('ForegroundService', 'Demande d\'autorisation échouée', e);
      return false;
    }
  }

  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  /// Démarre le service. Idempotent.
  Future<void> start() async {
    _ensureInitialized();

    try {
      if (await FlutterForegroundTask.isRunningService) return;

      await FlutterForegroundTask.startService(
        notificationTitle: 'Vous êtes en ligne',
        notificationText: 'Votre position est partagée pour recevoir des courses.',
      );
      AppLogger.info('ForegroundService', 'Service au premier plan démarré');
    } catch (e) {
      // Le suivi reste fonctionnel au premier plan : on dégrade plutôt que
      // d'empêcher le transporteur de se mettre en service.
      AppLogger.error('ForegroundService', 'Démarrage impossible', e);
    }
  }

  Future<void> stop() async {
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.stopService();
      AppLogger.info('ForegroundService', 'Service au premier plan arrêté');
    } catch (e) {
      AppLogger.error('ForegroundService', 'Arrêt impossible', e);
    }
  }
}
