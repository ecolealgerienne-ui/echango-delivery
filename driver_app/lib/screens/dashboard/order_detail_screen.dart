import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../state/order_state.dart';

class OrderDetailScreen extends StatelessWidget {
  final String orderId;

  const OrderDetailScreen({super.key, required this.orderId});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          context.read<OrderState>().clearSelection();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Order Details'),
          elevation: 0,
        ),
        body: Consumer<OrderState>(
          builder: (context, orderState, _) {
            final order = orderState.selectedOrder;

            if (orderState.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            if (order == null) {
              return const Center(child: Text('Order not found'));
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Order Header
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Order #${order.publicId}',
                                style: Theme.of(context).textTheme.headlineSmall,
                              ),
                              Chip(
                                label: Text(order.status),
                                backgroundColor: _getStatusColor(order.status),
                                labelStyle: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildInfoRow('Created:', order.createdAt.toString().split('.')[0]),
                          _buildInfoRow('Updated:', order.updatedAt.toString().split('.')[0]),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Locations
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pickup',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          if (order.pickupPlace != null)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  order.pickupPlace!.name,
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(order.pickupPlace!.address),
                                if (order.pickupPlace!.contactName != null)
                                  Text('Contact: ${order.pickupPlace!.contactName}'),
                                if (order.pickupPlace!.contactPhone != null)
                                  Text('Phone: ${order.pickupPlace!.contactPhone}'),
                              ],
                            ),
                          const SizedBox(height: 16),
                          Text(
                            'Dropoff',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          if (order.dropoffPlace != null)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  order.dropoffPlace!.name,
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(order.dropoffPlace!.address),
                                if (order.dropoffPlace!.contactName != null)
                                  Text('Contact: ${order.dropoffPlace!.contactName}'),
                                if (order.dropoffPlace!.contactPhone != null)
                                  Text('Phone: ${order.dropoffPlace!.contactPhone}'),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Delivery Failure (if exists)
                  if (order.deliveryFailure != null) ...[
                    Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.error_outline, color: Colors.red.shade700),
                                const SizedBox(width: 8),
                                Text(
                                  'Delivery Failed',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: Colors.red.shade700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _buildInfoRow('Reason:', order.deliveryFailure!.reason),
                            if (order.deliveryFailure!.notes != null)
                              _buildInfoRow('Notes:', order.deliveryFailure!.notes!),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Action Buttons
                  _buildActionButtons(context, order, orderState),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildActionButtons(
    BuildContext context,
    dynamic order,
    OrderState orderState,
  ) {
    final buttons = <Widget>[];

    if (order.isPending) {
      buttons.add(
        ElevatedButton(
          onPressed: orderState.isLoading ? null : () => _acceptOrder(context, order.id, orderState),
          child: const Text('Accept Order'),
        ),
      );
    }

    if (order.isPending || order.isInProgress) {
      buttons.add(const SizedBox(height: 12));
      buttons.add(
        ElevatedButton(
          onPressed: orderState.isLoading ? null : () => _startOrder(context, order.id, orderState),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
          child: const Text('Start Delivery'),
        ),
      );
    }

    if (order.isInProgress) {
      buttons.add(const SizedBox(height: 12));
      buttons.add(
        ElevatedButton(
          onPressed: orderState.isLoading ? null : () => _completeOrder(context, order.id, orderState),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
          child: const Text('Mark as Delivered'),
        ),
      );
    }

    if ((order.isPending || order.isInProgress) && !order.isFailed) {
      buttons.add(const SizedBox(height: 12));
      buttons.add(
        ElevatedButton(
          onPressed: orderState.isLoading ? null : () => context.push('/dashboard/orders/${order.id}/failure'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Report Failure'),
        ),
      );
    }

    if (buttons.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: buttons);
  }

  Future<void> _acceptOrder(
    BuildContext context,
    String orderId,
    OrderState orderState,
  ) async {
    final success = await orderState.acceptOrder(orderId);
    if (success) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order accepted')),
      );
    }
  }

  Future<void> _startOrder(
    BuildContext context,
    String orderId,
    OrderState orderState,
  ) async {
    final success = await orderState.startOrder(orderId);
    if (success) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Delivery started')),
      );
    }
  }

  Future<void> _completeOrder(
    BuildContext context,
    String orderId,
    OrderState orderState,
  ) async {
    final success = await orderState.completeOrder(
      orderId: orderId,
      proofUrl: 'placeholder_proof_url',
    );

    if (success) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order completed')),
      );
      context.pop();
    }
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
