import 'package:go_router/go_router.dart';

import '../screens/auth/login_screen.dart';
import '../screens/auth/register_screen.dart';
import '../screens/commercant/addresses_screen.dart';
import '../screens/commercant/create_order_screen.dart';
import '../screens/commercant/order_detail_screen.dart' as commercant;
import '../screens/commercant/orders_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/transporteur/dashboard_screen.dart';
import '../screens/transporteur/delivery_failure_screen.dart';
import '../screens/transporteur/order_detail_screen.dart' as transporteur;
import '../state/auth_state.dart';

const _publicPaths = ['/login', '/register'];

/// Routeur unique pour les trois profils.
///
/// Les arborescences sont séparées par préfixe (`/transporteur`,
/// `/commercant`) et la redirection s'appuie sur le rôle porté par le jeton :
/// un utilisateur ne peut pas atterrir dans l'espace d'un autre profil, même
/// en tapant l'URL — utile dès qu'on ciblera le web.
GoRouter buildAppRouter(AuthState authState) {
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: authState,
    redirect: (context, state) {
      final location = state.matchedLocation;
      final isPublic = _publicPaths.contains(location);

      if (authState.isSessionExpired) return '/login';
      if (!authState.isAuthenticated) return isPublic ? null : '/login';
      if (isPublic) return authState.homePath;

      // Espace d'un autre profil : renvoyer chez soi plutôt que d'afficher un
      // écran qui appellera des endpoints refusés par le BFF.
      final home = authState.homePath;
      if (location.startsWith('/transporteur') && home != '/transporteur') return home;
      if (location.startsWith('/commercant') && home != '/commercant') return home;

      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),

      // ── Transporteur ────────────────────────────────────────────────────
      GoRoute(
        path: '/transporteur',
        builder: (_, __) => const DashboardScreen(),
        routes: [
          GoRoute(
            path: 'commandes/:id',
            builder: (_, s) =>
                transporteur.OrderDetailScreen(orderId: s.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'echec',
                builder: (_, s) =>
                    DeliveryFailureScreen(orderId: s.pathParameters['id']!),
              ),
            ],
          ),
        ],
      ),

      // ── Commerçant ──────────────────────────────────────────────────────
      GoRoute(
        path: '/commercant',
        builder: (_, __) => const OrdersScreen(),
        routes: [
          GoRoute(
            path: 'nouvelle',
            builder: (_, __) => const CreateOrderScreen(),
          ),
          GoRoute(
            path: 'adresses',
            builder: (_, __) => const AddressesScreen(),
          ),
          GoRoute(
            path: 'commandes/:id',
            builder: (_, s) =>
                commercant.OrderDetailScreen(orderId: s.pathParameters['id']!),
          ),
        ],
      ),
    ],
  );
}
