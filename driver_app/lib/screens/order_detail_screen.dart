import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/order_provider.dart';
import 'delivery_failure_screen.dart';

class OrderDetailScreen extends StatelessWidget {
  const OrderDetailScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        context.read<OrderProvider>().clearSelection();
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Order Details'),
          elevation: 0,
        ),
        body: Consumer<OrderProvider>(
          builder: (context, orderProvider, _) {
            final order = orderProvider.selectedOrder;

            if (orderProvider.isLoading) {
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
                                style:
                                    Theme.of(context).textTheme.headlineSmall,
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
                          _buildInfoRow(
                            'Created:',
                            order.createdAt.toString().split('.')[0],
                          ),
                          _buildInfoRow(
                            'Updated:',
                            order.updatedAt.toString().split('.')[0],
                          ),
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
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                Text(order.pickupPlace!.address),
                                if (order.pickupPlace!.contactName != null)
                                  Text(
                                    'Contact: ${order.pickupPlace!.contactName}',
                                  ),
                                if (order.pickupPlace!.contactPhone != null)
                                  Text(
                                    'Phone: ${order.pickupPlace!.contactPhone}',
                                  ),
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
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                Text(order.dropoffPlace!.address),
                                if (order.dropoffPlace!.contactName != null)
                                  Text(
                                    'Contact: ${order.dropoffPlace!.contactName}',
                                  ),
                                if (order.dropoffPlace!.contactPhone != null)
                                  Text(
                                    'Phone: ${order.dropoffPlace!.contactPhone}',
                                  ),
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
                                Icon(
                                  Icons.error_outline,
                                  color: Colors.red.shade700,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Delivery Failed',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        color: Colors.red.shade700,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _buildInfoRow(
                              'Reason:',
                              order.deliveryFailure!.reason,
                            ),
                            if (order.deliveryFailure!.notes != null)
                              _buildInfoRow(
                                'Notes:',
                                order.deliveryFailure!.notes!,
                              ),
                            if (order.deliveryFailure!.photoUrl != null) ...[
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  order.deliveryFailure!.photoUrl!,
                                  height: 200,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Action Buttons
                  _buildActionButtons(context, order, orderProvider),
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
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildActionButtons(
    BuildContext context,
    dynamic order,
    OrderProvider orderProvider,
  ) {
    final buttons = <Widget>[];

    if (order.isPending) {
      buttons.add(
        ElevatedButton(
          onPressed: orderProvider.isLoading
              ? null
              : () => _acceptOrder(context, order.id, orderProvider),
          child: const Text('Accept Order'),
        ),
      );
    }

    if (order.isPending || order.isInProgress) {
      buttons.add(
        const SizedBox(height: 12),
      );
      buttons.add(
        ElevatedButton(
          onPressed: orderProvider.isLoading
              ? null
              : () => _startOrder(context, order.id, orderProvider),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
          ),
          child: const Text('Start Delivery'),
        ),
      );
    }

    if (order.isInProgress) {
      buttons.add(
        const SizedBox(height: 12),
      );
      buttons.add(
        ElevatedButton(
          onPressed: orderProvider.isLoading
              ? null
              : () => _completeOrder(context, order.id, orderProvider),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
          ),
          child: const Text('Mark as Delivered'),
        ),
      );
    }

    if ((order.isPending || order.isInProgress) && order.isFailed == false) {
      buttons.add(
        const SizedBox(height: 12),
      );
      buttons.add(
        ElevatedButton(
          onPressed: orderProvider.isLoading
              ? null
              : () => _reportDeliveryFailure(context, order),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
          ),
          child: const Text('Report Failure'),
        ),
      );
    }

    if (buttons.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: buttons,
    );
  }

  Future<void> _acceptOrder(
    BuildContext context,
    String orderId,
    OrderProvider orderProvider,
  ) async {
    final success = await orderProvider.acceptOrder(orderId);
    if (success) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order accepted')),
      );
    } else {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(orderProvider.errorMessage ?? 'Error')),
      );
    }
  }

  Future<void> _startOrder(
    BuildContext context,
    String orderId,
    OrderProvider orderProvider,
  ) async {
    final success = await orderProvider.startOrder(orderId);
    if (success) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Delivery started')),
      );
    } else {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(orderProvider.errorMessage ?? 'Error')),
      );
    }
  }

  Future<void> _completeOrder(
    BuildContext context,
    String orderId,
    OrderProvider orderProvider,
  ) async {
    // For MVP, use a placeholder proof URL
    // In production, this would handle photo capture
    final success = await orderProvider.completeOrder(
      orderId: orderId,
      proofUrl: 'placeholder_proof_url',
    );

    if (success) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order completed')),
      );
      Navigator.pop(context);
    } else {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(orderProvider.errorMessage ?? 'Error')),
      );
    }
  }

  Future<void> _reportDeliveryFailure(
    BuildContext context,
    dynamic order,
  ) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeliveryFailureScreen(order: order),
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
