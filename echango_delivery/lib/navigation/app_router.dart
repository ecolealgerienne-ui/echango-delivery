import 'package:go_router/go_router.dart';

import '../screens/auth/login_screen.dart';
import '../screens/auth/register_screen.dart';
import '../screens/cash/cash_screen.dart';
import '../screens/commercant/addresses_screen.dart';
import '../screens/commercant/create_order_screen.dart';
import '../screens/commercant/order_detail_screen.dart' as commercant;
import '../screens/commercant/favourite_drivers_screen.dart';
import '../screens/commercant/notifications_screen.dart';
import '../screens/commercant/orders_screen.dart';
import '../screens/flotte/driver_map_screen.dart';
import '../screens/flotte/flotte_home_screen.dart';
import '../screens/flotte/flotte_order_detail_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/transporteur/dashboard_screen.dart';
import '../screens/transporteur/delivery_failure_screen.dart';
import '../screens/transporteur/my_fleets_screen.dart';
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

      // `/splash` n'est qu'une attente : une fois la session connue, il n'a
      // plus rien à montrer. Sans cette ligne il se comportait comme une route
      // protégée ordinaire — renvoyé vers `/login` quand on n'est pas connecté,
      // mais laissé en place quand on l'est, donc affiché indéfiniment. Le
      // défaut ne se voyait qu'au démarrage avec une session restaurée : après
      // une connexion, la redirection depuis `/login` masquait le problème.
      if (location == '/splash' || isPublic) return authState.homePath;

      // Espace d'un autre profil : renvoyer chez soi plutôt que d'afficher un
      // écran qui appellera des endpoints refusés par le BFF.
      final home = authState.homePath;
      if (location.startsWith('/transporteur') && home != '/transporteur') return home;
      if (location.startsWith('/commercant') && home != '/commercant') return home;
      if (location.startsWith('/flotte') && home != '/flotte') return home;

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
          // Registre de caisse, vu du transporteur : ce qu'il détient et doit
          // remettre, commerçant par commerçant.
          GoRoute(
            path: 'caisse',
            builder: (_, __) => const CashScreen(persona: 'driver'),
          ),
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
          // Les entreprises du conducteur. Ce n'est pas un écran administratif :
          // un rattachement décide à qui il devra les espèces d'une course.
          GoRoute(
            path: 'entreprises',
            builder: (_, __) => const MyFleetsScreen(),
          ),
        ],
      ),

      // ── Commerçant ──────────────────────────────────────────────────────
      GoRoute(
        path: '/commercant',
        builder: (_, __) => const OrdersScreen(),
        routes: [
          // `extra` porte le modèle d'une commande reprise, quand il y en a un.
          // Passé par l'objet et non par l'URL : ce sont des données de
          // formulaire, parfois nominatives, qui n'ont rien à faire dans une
          // adresse — laquelle est journalisée, partagée et remise en cache.
          GoRoute(
            path: 'nouvelle',
            builder: (_, s) => CreateOrderScreen(
              template: s.extra is Map<String, dynamic>
                  ? s.extra as Map<String, dynamic>
                  : null,
            ),
          ),
          GoRoute(
            path: 'adresses',
            builder: (_, __) => const AddressesScreen(),
          ),
          GoRoute(
            path: 'transporteurs',
            builder: (_, __) => const FavouriteDriversScreen(),
          ),
          GoRoute(
            path: 'notifications',
            builder: (_, __) => const NotificationsScreen(),
          ),
          // Même écran, autre bout du registre : ce que les transporteurs ont
          // encaissé pour ce commerçant et ne lui ont pas encore remis.
          GoRoute(
            path: 'encaissements',
            builder: (_, __) => const CashScreen(persona: 'merchant'),
          ),
          GoRoute(
            path: 'commandes/:id',
            builder: (_, s) =>
                commercant.OrderDetailScreen(orderId: s.pathParameters['id']!),
          ),
        ],
      ),

      // L'espace entreprise de transport. `FlottePlaceholderScreen` disait
      // « Espace non disponible » alors que six routes BFF l'attendaient depuis
      // le 28/07 — le serveur savait, l'app ignorait (défaut D20).
      GoRoute(
        path: '/flotte',
        builder: (_, __) => const FlotteHomeScreen(),
        routes: [
          // Le registre vu de l'entreprise : ce que ses conducteurs lui doivent,
          // ce qu'elle doit aux commerçants. Même écran que les deux autres
          // personas — c'est le même registre, vu d'un troisième bout.
          GoRoute(
            path: 'caisse',
            builder: (_, __) => const CashScreen(persona: 'fleet'),
          ),
          // Une route et non un cinquième onglet : les positions se chargent à
          // la demande. Un onglet les chargerait — flotte entière et tuiles de
          // carte comprises — à chaque ouverture de l'espace entreprise, y
          // compris pour venir consulter une course.
          GoRoute(
            path: 'carte',
            builder: (_, __) => const FlotteDriverMapScreen(),
          ),
          // Deux chemins pour un écran, et non un drapeau dans l'URL : ils
          // n'interrogent pas la même route serveur et n'obéissent pas à la
          // même garde (appartenance d'un côté, disponibilité de l'autre).
          // Un `?unclaimed=true` laisserait croire à un affichage qui se
          // paramètre, alors que ce sont deux lectures distinctes.
          GoRoute(
            path: 'commandes/:id',
            builder: (_, s) => FlotteOrderDetailScreen(
              orderId: s.pathParameters['id']!,
              unclaimed: false,
            ),
          ),
          GoRoute(
            path: 'opportunites/:id',
            builder: (_, s) => FlotteOrderDetailScreen(
              orderId: s.pathParameters['id']!,
              unclaimed: true,
            ),
          ),
        ],
      ),
    ],
  );
}
