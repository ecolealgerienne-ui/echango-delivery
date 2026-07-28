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

  /// Construit les actions à partir de ce que le SERVEUR propose, jamais
  /// d'une machine à états codée ici.
  ///
  /// L'ancienne version affichait « Accept / Start / Mark as Delivered » selon
  /// des prédicats locaux. Résultat : accepter une commande adhoc l'assigne ET
  /// la démarre côté Fleetbase (§4.2), mais le bouton « Start Delivery »
  /// restait affiché et rejouait une transition déjà faite — « Failed to start
  /// this order ». Les transitions réelles varient selon l'OrderConfig ; seul
  /// `activites-suivantes` les connaît (journal §6.9).
  Widget _buildActionButtons(
    BuildContext context,
    dynamic order,
    OrderState orderState,
  ) {
    final buttons = <Widget>[];
    final busy = orderState.isLoading;

    // Opportunité adhoc : elle n'a pas encore de transition, il faut d'abord
    // la réclamer. Un seul appel serveur assigne et démarre.
    final claimable = order.adhoc == true && order.driverId == null;
    if (claimable) {
      buttons.add(
        ElevatedButton(
          onPressed: busy ? null : () => _acceptOrder(context, order.id, orderState),
          child: const Text('Accepter cette course'),
        ),
      );
    }

    for (final activity in orderState.nextActivities) {
      final code = (activity['code'] ?? '') as String;
      // `_resolved_status` est le libellé déjà interpolé par le serveur ;
      // `status` peut contenir des gabarits non résolus.
      final label = (activity['_resolved_status'] ??
          activity['status'] ??
          code) as String;
      final requiresPod = activity['require_pod'] == true;

      buttons.add(const SizedBox(height: 12));
      buttons.add(
        ElevatedButton(
          onPressed: busy
              ? null
              : () => _applyActivity(context, order.id, activity, orderState),
          style: ElevatedButton.styleFrom(
            backgroundColor: code == 'completed' ? Colors.green : Colors.orange,
          ),
          child: Text(requiresPod ? '$label (preuve requise)' : label),
        ),
      );
    }

    // Signalement d'échec : pertinent tant que la commande n'est pas close.
    if (!order.isFinished && !claimable) {
      buttons.add(const SizedBox(height: 12));
      buttons.add(
        ElevatedButton(
          onPressed: busy
              ? null
              : () => context.push('/dashboard/orders/${order.id}/failure'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Signaler un échec de livraison'),
        ),
      );
    }

    if (buttons.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: buttons);
  }

  /// Applique une transition serveur.
  ///
  /// ⚠️ `require_pod` n'est pas encore honoré : la capture photo (§5) n'est pas
  /// branchée, donc l'étape est envoyée sans preuve. Le serveur l'accepte,
  /// mais la preuve manquera au dossier — à traiter avec l'écran POD.
  Future<void> _applyActivity(
    BuildContext context,
    String orderId,
    Map<String, dynamic> activity,
    OrderState orderState,
  ) async {
    final success = await orderState.applyActivity(orderId, activity);
    if (!context.mounted) return;

    if (success) {
      final label = (activity['_resolved_status'] ?? activity['code'] ?? '') as String;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Étape appliquée : $label')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(orderState.errorMessage ?? 'Échec de la mise à jour'),
          backgroundColor: Colors.red,
        ),
      );
    }
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
