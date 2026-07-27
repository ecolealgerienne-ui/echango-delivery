import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/auth/login_screen.dart';
import '../screens/auth/otp_screen.dart';
import '../screens/dashboard/dashboard_screen.dart';
import '../screens/dashboard/orders_list_screen.dart';
import '../screens/dashboard/order_detail_screen.dart';
import '../screens/dashboard/delivery_failure_screen.dart';
import '../screens/dashboard/map_screen.dart';
import '../screens/dashboard/profile_screen.dart';
import '../screens/splash_screen.dart';
import '../state/auth_state.dart';

/// Routes publiques (accessibles sans authentification).
const _publicPaths = [
  '/login',
  '/login/otp',
];

/// Construit le routeur GoRouter avec redirection basée sur l'état d'authentification.
GoRouter buildAppRouter(AuthState authState) {
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: authState,
    redirect: (context, state) {
      final isPublic = _publicPaths.contains(state.matchedLocation);

      // Redirection : session expirée
      if (authState.isSessionExpired) {
        return '/login';
      }

      // Redirection : pas authentifié
      if (!authState.isAuthenticated && !isPublic) {
        return '/login';
      }

      // Redirection : authentifié mais sur une page publique
      if (authState.isAuthenticated && isPublic) {
        return '/dashboard';
      }

      return null; // Pas de redirection nécessaire
    },
    routes: [
      // Splash screen
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),

      // Authentication routes
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/login/otp',
        builder: (context, state) {
          final phone = state.uri.queryParameters['phone'] ?? '';
          return OtpScreen(phone: phone);
        },
      ),

      // Main app routes (protected)
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => const DashboardScreen(),
        routes: [
          GoRoute(
            path: 'orders',
            builder: (context, state) => const OrdersListScreen(),
          ),
          GoRoute(
            path: 'orders/:id',
            builder: (context, state) {
              final orderId = state.pathParameters['id'] ?? '';
              return OrderDetailScreen(orderId: orderId);
            },
            routes: [
              GoRoute(
                path: 'failure',
                builder: (context, state) {
                  final orderId = state.pathParameters['id'] ?? '';
                  return DeliveryFailureScreen(orderId: orderId);
                },
              ),
            ],
          ),
          GoRoute(
            path: 'map',
            builder: (context, state) => const MapScreen(),
          ),
          GoRoute(
            path: 'profile',
            builder: (context, state) => const ProfileScreen(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Route not found: ${state.uri}'),
      ),
    ),
  );
}
