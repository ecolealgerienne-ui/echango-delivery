import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/api_config.dart';
import 'navigation/app_router.dart';
import 'services/bff_api_client.dart';
import 'state/auth_state.dart';
import 'state/order_state.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final apiClient = BffApiClient(baseUrl: ApiConfig.bffBaseUrl);

  final authState = AuthState(prefs: prefs, apiClient: apiClient);
  await authState.restoreSession();

  runApp(EchangoMerchantApp(authState: authState, apiClient: apiClient));
}

class EchangoMerchantApp extends StatefulWidget {
  final AuthState authState;
  final BffApiClient apiClient;

  const EchangoMerchantApp({
    super.key,
    required this.authState,
    required this.apiClient,
  });

  @override
  State<EchangoMerchantApp> createState() => _EchangoMerchantAppState();
}

class _EchangoMerchantAppState extends State<EchangoMerchantApp> {
  late final OrderState _orderState;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _orderState = OrderState(apiClient: widget.apiClient);
    // Construit une seule fois : recréer le routeur à chaque build ferait
    // perdre la pile de navigation.
    _router = buildAppRouter(widget.authState);
  }

  @override
  void dispose() {
    _orderState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthState>.value(value: widget.authState),
        Provider<BffApiClient>.value(value: widget.apiClient),
        ChangeNotifierProvider<OrderState>.value(value: _orderState),
      ],
      child: MaterialApp.router(
        title: ApiConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildAppDarkTheme(),
        themeMode: ThemeMode.system,
        routerConfig: _router,
      ),
    );
  }
}
