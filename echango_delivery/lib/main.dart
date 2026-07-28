import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';

import 'config/api_config.dart';
import 'config/firebase_options.dart';
import 'navigation/app_router.dart';
import 'services/bff_api_client.dart';
import 'services/notification_service.dart' show NotificationService;
import 'state/auth_state.dart';
import 'state/merchant_order_state.dart';
import 'state/order_state.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase est OPTIONNEL au démarrage.
  //
  // `firebase_options.dart` est encore un gabarit ('YOUR_PROJECT_ID'…) : sans
  // ce garde-fou, `initializeApp` lève et l'app ne démarre pas du tout, ce qui
  // empêche de tester connexion et commandes — qui n'ont pourtant aucun besoin
  // de Firebase. Les notifications push sont un confort (le déclencheur d'un
  // rafraîchissement REST, specs_app_transporteur.md §11.1), pas une
  // dépendance de fonctionnement.
  //
  // Conséquence quand la config manque : pas de notification à l'arrivée d'une
  // commande. Le reste fonctionne, le driver doit rafraîchir manuellement.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await NotificationService.initialize();
  } catch (e) {
    debugPrint(
      'Firebase non initialisé — notifications push désactivées. '
      'Renseigner lib/config/firebase_options.dart pour les activer. Détail : $e',
    );
  }

  // Get shared preferences and API client
  final prefs = await SharedPreferences.getInstance();
  final apiClient = BffApiClient(baseUrl: ApiConfig.bffBaseUrl);
  await apiClient.restoreSession();

  // Create auth state
  final authState = AuthState(prefs: prefs, apiClient: apiClient);
  await authState.restoreSession();

  runApp(
    EchangoDriverApp(
      authState: authState,
      apiClient: apiClient,
    ),
  );
}

class EchangoDriverApp extends StatefulWidget {
  final AuthState authState;
  final BffApiClient apiClient;

  const EchangoDriverApp({
    super.key,
    required this.authState,
    required this.apiClient,
  });

  @override
  State<EchangoDriverApp> createState() => _EchangoDriverAppState();
}

class _EchangoDriverAppState extends State<EchangoDriverApp>
    with WidgetsBindingObserver {
  late final OrderState _orderState;
  late final MerchantOrderState _merchantOrderState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _orderState = OrderState(apiClient: widget.apiClient);
    _merchantOrderState = MerchantOrderState(apiClient: widget.apiClient);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Vérifie l'inactivité quand l'app reprend au premier plan
    // (session expirée après 24h, CLAUDE.md)
    if (state == AppLifecycleState.resumed) {
      widget.authState.checkInactivity();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.authState.dispose();
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
