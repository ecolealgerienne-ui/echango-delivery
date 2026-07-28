import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../state/auth_state.dart';
import '../../state/order_state.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Charge les commandes au démarrage du dashboard
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<OrderState>().loadOrders();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Echango Delivery'),
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(
              child: Consumer<AuthState>(
                builder: (context, authState, _) {
                  return Text(
                    authState.email ?? 'Transporteur',
                    style: Theme.of(context).textTheme.bodyMedium,
                  );
                },
              ),
            ),
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() => _selectedIndex = index);
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.list),
            label: 'Orders',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_selectedIndex) {
      case 0:
        return const OrdersListScreen();
      case 1:
        return const MapScreen();
      case 2:
        return const ProfileScreen();
      default:
        return const OrdersListScreen();
    }
  }
}

/// Écran liste des commandes avec filtrage par statut.
class OrdersListScreen extends StatefulWidget {
  const OrdersListScreen({super.key});

  @override
  State<OrdersListScreen> createState() => _OrdersListScreenState();
}

class _OrdersListScreenState extends State<OrdersListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final errorMessage = context.watch<OrderState>().errorMessage;

    return Column(
      children: [
        // Sans ça, un échec de chargement est indiscernable d'une liste
        // réellement vide — c'est exactement ce qui rend un premier lancement
        // impossible à diagnostiquer.
        if (errorMessage != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.all(12),
            child: Text(
              errorMessage,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        TabBar(
          controller: _tabController,
          // Les trois catégories de la spec §4.1. « Opportunités » remplace
          // « Pending » : ce sont les commandes adhoc diffusées à proximité,
          // que le driver peut réclamer — elles ne lui sont pas encore
          // assignées, donc invisibles dans une vue « mes commandes ».
          tabs: const [
            Tab(text: 'Opportunités'),
            Tab(text: 'En cours'),
            Tab(text: 'Historique'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOrdersList(
                context.watch<OrderState>().adhocOrders,
                emptyLabel: 'Aucune opportunité à proximité',
                emptyHint: 'Vérifier que vous êtes en ligne : le dispatch '
                    'est géographique.',
              ),
              _buildOrdersList(
                context.watch<OrderState>().activeOrders,
                emptyLabel: 'Aucune commande en cours',
              ),
              _buildOrdersList(
                context.watch<OrderState>().historyOrders,
                emptyLabel: 'Aucune commande terminée',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOrdersList(
    List<dynamic> orders, {
    String emptyLabel = 'Aucune commande',
    String? emptyHint,
  }) {
    // RefreshIndicator exige un enfant défilable pour capter le geste : sans
    // AlwaysScrollableScrollPhysics sur une liste vide, tirer vers le bas ne
    // déclenche rien — précisément le cas où l'on veut recharger.
    if (orders.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => context.read<OrderState>().loadOrders(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: _emptyState(emptyLabel, emptyHint),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => context.read<OrderState>().loadOrders(),
      child: _ordersListView(orders),
    );
  }

  Widget _emptyState(String emptyLabel, String? emptyHint) {
    return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              emptyLabel,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            if (emptyHint != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  emptyHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[500],
                      ),
                ),
              ),
            ],
          ],
      ),
    );
  }

  Widget _ordersListView(List<dynamic> orders) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      itemCount: orders.length,
      itemBuilder: (context, index) {
        final order = orders[index];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
          child: ListTile(
            title: Text('Order #${order.publicId}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  '${order.pickupPlace?.name} → ${order.dropoffPlace?.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  'Status: ${order.status}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _getStatusColor(order.status),
                      ),
                ),
              ],
            ),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              context.read<OrderState>().selectOrder(order.id);
              context.push('/transporteur/commandes/${order.id}');
            },
          ),
        );
      },
    );
  }

  /// Couleurs alignées sur les statuts Fleetbase réels. L'ancienne version
  /// testait 'accepted' et 'picked_up', qui n'existent pas : tout tombait
  /// dans le gris par défaut.
  Color _getStatusColor(String status) {
    switch (status) {
      case 'created':
      case 'dispatched':
        return Colors.orange;
      case 'started':
      case 'enroute':
        return Colors.blue;
      case 'completed':
        return Colors.green;
      case 'canceled':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}

/// Écran de la carte.
class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.map_outlined,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            'Map Integration',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Google Maps will be integrated here',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }
}

/// Écran de profil avec logout.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(
                    Icons.account_circle_outlined,
                    size: 80,
                    color: Theme.of(context).primaryColor,
                  ),
                  const SizedBox(height: 16),
                  Consumer<AuthState>(
                    builder: (context, authState, _) {
                      return Column(
                        children: [
                          Text(
                            authState.email ?? 'Transporteur',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Profil : ${authState.role?.label ?? '—'}',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
          Consumer<AuthState>(
            builder: (context, authState, _) {
              return ElevatedButton(
                onPressed: authState.isLoading
                    ? null
                    : () => _handleLogout(context, authState),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: authState.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        'Logout',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _handleLogout(
    BuildContext context,
    AuthState authState,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await authState.logout();
      if (context.mounted) {
        context.go('/login');
      }
    }
  }
}
