import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../state/auth_state.dart';
import '../../state/merchant_order_state.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<MerchantOrderState>();
      state.loadOrders();
      state.loadNotifications();
    });
  }

  @override
  Widget build(BuildContext context) {
    final orderState = context.watch<MerchantOrderState>();
    final authState = context.watch<AuthState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(authState.displayName ?? 'Mes livraisons'),
        actions: [
          // La pastille est le seul signal d'un évènement, l'envoi push
          // n'étant pas branché : elle doit donc être visible depuis l'écran
          // d'accueil, et non enfouie dans un menu.
          IconButton(
            tooltip: 'Notifications',
            icon: Badge(
              isLabelVisible: orderState.unreadNotifications > 0,
              label: Text('${orderState.unreadNotifications}'),
              child: const Icon(Icons.notifications_none),
            ),
            onPressed: () => context.push('/commercant/notifications'),
          ),
          IconButton(
            tooltip: 'Carnet d\'adresses',
            icon: const Icon(Icons.bookmark_border),
            onPressed: () => context.push('/commercant/adresses'),
          ),
          IconButton(
            tooltip: 'Mes transporteurs',
            icon: const Icon(Icons.star_border),
            onPressed: () => context.push('/commercant/transporteurs'),
          ),
          IconButton(
            tooltip: 'Déconnexion',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final router = GoRouter.of(context);
              await authState.logout();
              router.go('/login');
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/commercant/nouvelle'),
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle livraison'),
      ),
      body: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            // Une erreur de chargement doit être visible : sans ça, elle est
            // indiscernable d'une liste réellement vide.
            if (orderState.errorMessage != null)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.all(12),
                child: Text(
                  orderState.errorMessage!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            const TabBar(
              tabs: [
                Tab(text: 'En cours'),
                Tab(text: 'Terminées'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _OrderList(
                    orders: orderState.activeOrders,
                    emptyLabel: 'Aucune livraison en cours',
                    emptyHint: 'Appuyez sur « Nouvelle livraison » pour '
                        'demander un transporteur.',
                  ),
                  _OrderList(
                    orders: orderState.pastOrders,
                    emptyLabel: 'Aucune livraison terminée',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderList extends StatelessWidget {
  final List<MerchantOrder> orders;
  final String emptyLabel;
  final String? emptyHint;

  const _OrderList({
    required this.orders,
    required this.emptyLabel,
    this.emptyHint,
  });

  @override
  Widget build(BuildContext context) {
    // Le tirer-pour-rafraîchir relève aussi les notifications : sans envoi
    // push, c'est le geste par lequel un commerçant vient chercher les
    // nouvelles, et ne rafraîchir que la liste laisserait la pastille périmée
    // à côté de commandes fraîches.
    Future<void> refresh() async {
      final state = context.read<MerchantOrderState>();
      await state.loadOrders();
      await state.loadNotifications();
    }

    if (orders.isEmpty) {
      // Le tirer-pour-rafraîchir doit marcher sur liste vide — c'est
      // justement là qu'on en a besoin : d'où le ListView + physics.
      return RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.local_shipping_outlined,
                        size: 64, color: Colors.grey[400]),
                    const SizedBox(height: 16),
                    Text(emptyLabel,
                        style: TextStyle(color: Colors.grey[600], fontSize: 16)),
                    if (emptyHint != null) ...[
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          emptyHint!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[500], fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(8),
        itemCount: orders.length,
        itemBuilder: (context, index) {
          final order = orders[index];
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: ListTile(
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      order.dropoff?.name ?? 'Livraison',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusChip(order: order),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    order.dropoff?.address ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (order.driverName != null)
                    Text('Transporteur : ${order.driverName}',
                        style: const TextStyle(fontSize: 12)),
                ],
              ),
              trailing: const Icon(Icons.chevron_right),
              // `order.id` = uuid Fleetbase : c'est ce que le détail sait
              // résoudre (avec l'id local du cache). Le public_id, lui, n'est
              // stocké nulle part côté BFF et ne matcherait rien.
              onTap: () => context.push('/commercant/commandes/${order.id}'),
            ),
          );
        },
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final MerchantOrder order;

  const _StatusChip({required this.order});

  @override
  Widget build(BuildContext context) {
    // Libellés métier plutôt que les codes Fleetbase bruts : un commerçant
    // n'a pas à savoir ce que signifie « enroute ».
    if (order.degraded) {
      return const Chip(
        label: Text('État indisponible',
            style: TextStyle(fontSize: 11, color: Colors.white)),
        backgroundColor: Colors.blueGrey,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
    }

    final (label, color) = switch (order.status) {
      'completed' => ('Livrée', Colors.green),
      'canceled' => ('Annulée', Colors.grey),
      'created' => ('En attente', Colors.orange),
      'dispatched' => ('Recherche transporteur', Colors.blue),
      'started' || 'enroute' => ('En cours', Colors.blue),
      _ => (order.status, Colors.blueGrey),
    };

    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 11, color: Colors.white)),
      backgroundColor: color,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
