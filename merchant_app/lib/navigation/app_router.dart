import 'package:go_router/go_router.dart';

import '../screens/auth/login_screen.dart';
import '../screens/auth/register_screen.dart';
import '../screens/orders/orders_screen.dart';
import '../screens/orders/order_detail_screen.dart';
import '../screens/orders/create_order_screen.dart';
import '../screens/addresses/addresses_screen.dart';
import '../screens/splash_screen.dart';
import '../state/auth_state.dart';

const _publicPaths = ['/login', '/register'];

GoRouter buildAppRouter(AuthState authState) {
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: authState,
    redirect: (context, state) {
      final isPublic = _publicPaths.contains(state.matchedLocation);
      if (!authState.isAuthenticated && !isPublic) return '/login';
      if (authState.isAuthenticated && isPublic) return '/commandes';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(path: '/commandes', builder: (_, __) => const OrdersScreen()),
      GoRoute(
        path: '/commandes/nouvelle',
        builder: (_, __) => const CreateOrderScreen(),
      ),
      GoRoute(
        path: '/commandes/:id',
        builder: (_, state) =>
            OrderDetailScreen(orderId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/adresses', builder: (_, __) => const AddressesScreen()),
    ],
  );
}
