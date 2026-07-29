import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../models/vehicle_type.dart';
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

  /// Rouvre le formulaire de création, pré-rempli à partir de cette livraison.
  ///
  /// Le formulaire est ouvert, pas la commande créée : l'enlèvement programmé
  /// ne se reprend pas (celui d'origine est passé), et une livraison réelle
  /// facturée à quelqu'un ne doit pas pouvoir naître d'un tapotement.
  ///
  /// Un échec de reprise n'est pas une impasse : le formulaire s'ouvre vide,
  /// avec un mot pour dire pourquoi.
  Future<void> _duplicate(MerchantOrderState orderState) async {
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final template = await orderState.loadOrderTemplate(widget.orderId);
    if (!mounted) return;

    if (template == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            orderState.errorMessage ??
                'Reprise impossible — le formulaire s\'ouvre vide.',
          ),
        ),
      );
    }

    router.push('/commercant/nouvelle', extra: template);
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
                    const SizedBox(height: 12),
                    _orderOptionsCard(order),
                    if (order.isCompleted && order.driverName != null) ...[
                      const SizedBox(height: 12),
                      _favouriteCard(order),
                    ],
                    const SizedBox(height: 24),
                    // Reprendre passe avant annuler : c'est l'action courante
                    // (une boulangerie livre le même client chaque semaine),
                    // l'autre est exceptionnelle. Les ranger dans cet ordre
                    // évite aussi de placer un bouton destructeur sous le
                    // pouce, à l'endroit qu'on touche sans regarder.
                    FilledButton.tonalIcon(
                      onPressed:
                          orderState.isLoading ? null : () => _duplicate(orderState),
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Refaire cette livraison'),
                    ),
                    const SizedBox(height: 12),
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

  /// Ce qui a été demandé à la création.
  ///
  /// Le détail n'en montrait rien : le commerçant ne pouvait ni vérifier sa
  /// commande, ni la rappeler en cas de litige — alors que ces options
  /// changent le prix et le service rendu. Les lignes absentes ne sont pas
  /// affichées : une liste de « — » n'informe personne.
  Widget _orderOptionsCard(MerchantOrder order) {
    final rows = <(IconData, String, String)>[
      if (order.price != null)
        (
          Icons.payments_outlined,
          'Rémunération',
          '${order.price!.toStringAsFixed(0)} ${order.currency ?? ''}'.trim(),
        ),
      if (order.scheduledAt != null)
        (
          Icons.schedule_outlined,
          'Enlèvement',
          _formatDateTime(order.scheduledAt!),
        )
      else
        (Icons.schedule_outlined, 'Enlèvement', 'Dès que possible'),
      if (order.vehicleType != null)
        (
          vehicleIcon(order.vehicleType),
          'Véhicule',
          '${vehicleLabel(order.vehicleType)} minimum',
        ),
      if (order.podMethod != null)
        (
          Icons.verified_outlined,
          'Preuve',
          order.podMethod == 'photo' ? 'Photo à la livraison' : order.podMethod!,
        ),
      if (order.packageContents != null)
        (Icons.inventory_2_outlined, 'Colis', order.packageContents!),
      if (order.instructions != null)
        (Icons.notes_outlined, 'Instructions', order.instructions!),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Votre demande',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            for (final (icon, label, value) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 92,
                      child: Text(label,
                          style: const TextStyle(fontWeight: FontWeight.w500)),
                    ),
                    Expanded(child: Text(value)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Proposer la mise en favori au moment où elle a du sens : la livraison
  /// vient d'aboutir, le commerçant sait s'il veut retravailler avec ce
  /// transporteur. Sans ce point d'entrée, un nouveau commerçant n'avait aucun
  /// moyen de constituer sa liste — l'écran des favoris reste vide tant qu'on
  /// n'y ajoute rien, et rien n'y menait.
  Widget _favouriteCard(MerchantOrder order) => Card(
        child: ListTile(
          leading: const Icon(Icons.star_outline),
          title: Text('Ajouter ${order.driverName} à mes transporteurs'),
          subtitle: const Text(
            'Vos prochaines livraisons lui seront proposées en premier.',
          ),
          onTap: () => context.push('/commercant/transporteurs'),
        ),
      );

  static String _formatDateTime(DateTime date) {
    final local = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)} à ${two(local.hour)}h${two(local.minute)}';
  }

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
