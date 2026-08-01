import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
import 'state/cash_state.dart';
import 'state/fleet_state.dart';
import 'state/locale_state.dart';
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

  // La locale système ne sert qu'une fois, à défaut de choix déjà enregistré
  // (voir LocaleState) — WidgetsBinding expose la locale du système avant que
  // le premier widget ne soit construit. Créée avant AuthState : les messages
  // d'erreur de connexion sont traduits dès le premier écran.
  final localeState = LocaleState(
    prefs: prefs,
    systemLocale: WidgetsBinding.instance.platformDispatcher.locale,
  );

  final authState =
      AuthState(prefs: prefs, apiClient: apiClient, localeState: localeState);
  await authState.restoreSession();

  runApp(
    EchangoDeliveryApp(
      authState: authState,
      apiClient: apiClient,
      localeState: localeState,
    ),
  );
}

class EchangoDeliveryApp extends StatefulWidget {
  final AuthState authState;
  final BffApiClient apiClient;
  final LocaleState localeState;

  const EchangoDeliveryApp({
    super.key,
    required this.authState,
    required this.apiClient,
    required this.localeState,
  });

  @override
  State<EchangoDeliveryApp> createState() => _EchangoDeliveryAppState();
}

class _EchangoDeliveryAppState extends State<EchangoDeliveryApp>
    with WidgetsBindingObserver {
  late final OrderState _orderState;
  late final MerchantOrderState _merchantOrderState;
  late final CashState _cashState;
  late final FleetState _fleetState;
  late final DriverPresenceState _presence;

  bool _presenceStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _orderState =
        OrderState(apiClient: widget.apiClient, localeState: widget.localeState);
    _merchantOrderState = MerchantOrderState(
      apiClient: widget.apiClient,
      localeState: widget.localeState,
    );
    _cashState =
        CashState(apiClient: widget.apiClient, localeState: widget.localeState);
    _fleetState =
        FleetState(apiClient: widget.apiClient, localeState: widget.localeState);
    _presence = DriverPresenceState(
      apiClient: widget.apiClient,
      orderState: _orderState,
      localeState: widget.localeState,
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
    widget.localeState.dispose();
    _presence.dispose();
    _orderState.dispose();
    _merchantOrderState.dispose();
    _cashState.dispose();
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
        // Un seul registre pour les deux profils : ce que le transporteur doit
        // est ce que le commerçant attend. Deux états auraient divergé sur la
        // seule chose qui doit rester commune.
        ChangeNotifierProvider<CashState>.value(value: _cashState),
        ChangeNotifierProvider<FleetState>.value(value: _fleetState),
        ChangeNotifierProvider<DriverPresenceState>.value(value: _presence),
        ChangeNotifierProvider<LocaleState>.value(value: widget.localeState),
      ],
      child: Consumer<LocaleState>(
        builder: (context, localeState, _) => MaterialApp.router(
          title: ApiConfig.appName,
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          darkTheme: buildAppDarkTheme(),
          themeMode: ThemeMode.system,
          locale: localeState.locale,
          supportedLocales: supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          routerConfig: buildAppRouter(widget.authState),
        ),
      ),
    );
  }
}
