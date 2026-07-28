import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../state/merchant_order_state.dart';

class OrderDetailScreen extends StatefulWidget {
  final String orderId;

  const OrderDetailScreen({super.key, required this.orderId});

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<MerchantOrderState>().selectOrder(widget.orderId);
    });
  }

  Future<void> _cancel(MerchantOrderState orderState) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Annuler cette livraison ?'),
        content: const Text(
          'La demande sera retirée. Cette action est définitive.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Retour'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Annuler la livraison'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final success = await orderState.cancelOrder(widget.orderId);
    if (!mounted) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text(success
            ? 'Livraison annulée'
            : orderState.errorMessage ?? 'Annulation impossible'),
        backgroundColor: success ? null : Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) context.read<MerchantOrderState>().clearSelection();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Suivi de la livraison')),
        body: Consumer<MerchantOrderState>(
          builder: (context, orderState, _) {
            if (orderState.isLoading && orderState.selected == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final order = orderState.selected;
            if (order == null) {
              return Center(
                child: Text(orderState.errorMessage ?? 'Livraison introuvable'),
              );
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    order.publicId,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(order.status),
                              ],
                            ),
                            if (order.trackingNumber != null) ...[
                              const SizedBox(height: 8),
                              Text('Numéro de suivi : ${order.trackingNumber}'),
                            ],
                            const SizedBox(height: 8),
                            Text(
                              'Créée le ${order.createdAt.toLocal().toString().split('.')[0]}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Le commerçant a surtout besoin de savoir « où ça en
                    // est » : l'exprimer en clair plutôt qu'en code de statut.
                    if (order.isWaitingDispatch)
                      _banner(
                        Colors.orange.shade50,
                        Icons.hourglass_empty,
                        'En attente d\'attribution. Echango recherche un '
                        'transporteur disponible.',
                      ),
                    if (order.driverName != null)
                      _banner(
                        Colors.blue.shade50,
                        Icons.local_shipping_outlined,
                        'Pris en charge par ${order.driverName}.',
                      ),
                    if (order.isCompleted)
                      _banner(Colors.green.shade50, Icons.check_circle_outline,
                          'Livraison effectuée.'),
                    if (order.isCancelled)
                      _banner(Colors.grey.shade200, Icons.cancel_outlined,
                          'Livraison annulée.'),
                    const SizedBox(height: 12),
                    _placeCard('Retrait', order.pickup?.name, order.pickup?.address),
                    const SizedBox(height: 12),
                    _placeCard('Livraison', order.dropoff?.name, order.dropoff?.address),
                    const SizedBox(height: 24),
                    if (order.canCancel)
                      OutlinedButton.icon(
                        onPressed:
                            orderState.isLoading ? null : () => _cancel(orderState),
                        icon: const Icon(Icons.close),
                        label: const Text('Annuler la livraison'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                      ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _banner(Color color, IconData icon, String text) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );

  Widget _placeCard(String title, String? name, String? address) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Text(name ?? '—',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (address != null && address.isNotEmpty) Text(address),
            ],
          ),
        ),
      );
}
