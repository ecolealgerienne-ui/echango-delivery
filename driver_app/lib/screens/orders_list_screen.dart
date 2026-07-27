import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/order_provider.dart';
import 'order_detail_screen.dart';

class OrdersListScreen extends StatefulWidget {
  const OrdersListScreen({Key? key}) : super(key: key);

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
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Pending'),
            Tab(text: 'Active'),
            Tab(text: 'Completed'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOrdersList(
                context.watch<OrderProvider>().pendingOrders,
                onRefresh: () =>
                    context.read<OrderProvider>().loadOrders(status: 'pending'),
              ),
              _buildOrdersList(
                context.watch<OrderProvider>().activeOrders,
                onRefresh: () =>
                    context.read<OrderProvider>().loadOrders(status: 'active'),
              ),
              _buildOrdersList(
                context.watch<OrderProvider>().completedOrders,
                onRefresh: () =>
                    context.read<OrderProvider>().loadOrders(status: 'completed'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOrdersList(
    List<dynamic> orders, {
    required Future<void> Function() onRefresh,
  }) {
    if (orders.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: Center(
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
                      'No orders yet',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Colors.grey[600],
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
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
                context.read<OrderProvider>().selectOrder(order.id);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const OrderDetailScreen(),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'created':
      case 'accepted':
        return Colors.orange;
      case 'picked_up':
        return Colors.blue;
      case 'completed':
        return Colors.green;
      case 'failed':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}
