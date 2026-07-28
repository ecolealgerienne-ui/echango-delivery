import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';

import 'config/api_config.dart';
import 'config/firebase_options.dart';
import 'navigation/app_router.dart';
import 'services/bff_api_client.dart';
import 'services/location_service.dart';
import 'state/auth_state.dart';
import 'state/driver_presence_state.dart';
import 'state/merchant_order_state.dart';
import 'state/order_state.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase est OPTIONNEL au démarrage.
  //
  // Les notifications push sont un déclencheur de rafraîchissement
  // (specs_app_transporteur.md §11.1), pas une dépendance de fonctionnement :
  // quand elles manquent, le repli par interrogation périodique prend le relais
  // (voir DriverPresenceState).
  //
  // ⚠️ Rien ici ne doit demander d'autorisation ni attendre l'utilisateur.
  // `NotificationService.initialize()` était appelé à cet endroit et sollicite
  // la permission de notification : `runApp` attendait donc que l'utilisateur
  // réponde au dialogue système, et l'application restait sur un écran noir
  // sans jamais rendre la main. L'initialisation a désormais lieu à l'ouverture
  // d'une session transporteur, c'est-à-dire au seul moment où elle sert.
  if (DefaultFirebaseOptions.isConfigured) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e) {
      debugPrint('Firebase non initialisé, notifications désactivées : $e');
    }
  } else {
    debugPrint(
      'Firebase non configuré (lib/config/firebase_options.dart est un '
      'gabarit) — notifications push désactivées, rafraîchissement par '
      'interrogation périodique du BFF.',
    );
  }

  final prefs = await SharedPreferences.getInstance();
  final apiClient = BffApiClient(baseUrl: ApiConfig.bffBaseUrl);
  await apiClient.restoreSession();
  await LocationService().initialize(apiClient);

  final authState = AuthState(prefs: prefs, apiClient: apiClient);
  await authState.restoreSession();

  runApp(
    EchangoDeliveryApp(
      authState: authState,
      apiClient: apiClient,
    ),
  );
}

class EchangoDeliveryApp extends StatefulWidget {
  final AuthState authState;
  final BffApiClient apiClient;

  const EchangoDeliveryApp({
    super.key,
    required this.authState,
    required this.apiClient,
  });

  @override
  State<EchangoDeliveryApp> createState() => _EchangoDeliveryAppState();
}

class _EchangoDeliveryAppState extends State<EchangoDeliveryApp>
    with WidgetsBindingObserver {
  late final OrderState _orderState;
  late final MerchantOrderState _merchantOrderState;
  late final DriverPresenceState _presence;

  bool _presenceStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _orderState = OrderState(apiClient: widget.apiClient);
    _merchantOrderState = MerchantOrderState(apiClient: widget.apiClient);
    _presence = DriverPresenceState(
      apiClient: widget.apiClient,
      orderState: _orderState,
    );

    // La présence suit la session, pas un écran : elle doit démarrer aussi
    // bien après une connexion qu'après une session restaurée au lancement, et
    // s'arrêter à la déconnexion même si le driver n'a jamais ouvert l'écran
    // qui porte l'interrupteur.
    widget.authState.addListener(_syncPresenceWithSession);

    // Passer hors ligne exige un jeton valide : ça doit donc se faire AVANT
    // que la déconnexion l'invalide, pas en réaction au changement d'état.
    widget.authState.onBeforeLogout = _presence.stop;

    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPresenceWithSession());
  }

  void _syncPresenceWithSession() {
    final isDriver = widget.authState.isAuthenticated &&
        widget.authState.role == UserRole.transporteur;

    if (isDriver && !_presenceStarted) {
      _presenceStarted = true;
      _presence.start();
    } else if (!isDriver && _presenceStarted) {
      _presenceStarted = false;
      _presence.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Vérifie l'inactivité quand l'app reprend au premier plan
    // (session expirée après 24h, CLAUDE.md)
    if (state == AppLifecycleState.resumed) {
      widget.authState.checkInactivity();
    }
    _presence.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.authState.removeListener(_syncPresenceWithSession);
    widget.authState.onBeforeLogout = null;
    widget.authState.dispose();
    _presence.dispose();
    _orderState.dispose();
    _merchantOrderState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthState>.value(value: widget.authState),
        Provider<BffApiClient>.value(value: widget.apiClient),
        ChangeNotifierProvider<OrderState>.value(value: _orderState),
        ChangeNotifierProvider<MerchantOrderState>.value(value: _merchantOrderState),
        ChangeNotifierProvider<DriverPresenceState>.value(value: _presence),
      ],
      child: MaterialApp.router(
        title: ApiConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildAppDarkTheme(),
        themeMode: ThemeMode.system,
        routerConfig: buildAppRouter(widget.authState),
      ),
    );
  }
}
