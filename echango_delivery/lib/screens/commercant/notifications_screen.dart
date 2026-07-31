import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../state/merchant_order_state.dart';
import '../../theme/app_spacing.dart';

/// Journal des évènements de livraison du commerçant.
///
/// ── Pourquoi un écran, et pas seulement des notifications système ───────────
///
/// Une notification système se rate : téléphone en silencieux, balayée d'un
/// geste, jamais reçue parce que le jeton avait tourné. Ce qu'un commerçant
/// vient chercher en rouvrant l'application — « est-ce que quelqu'un a pris ma
/// course ? » — doit donc exister quelque part de consultable. Le serveur en
/// garde la mémoire, cet écran la montre.
///
/// L'envoi push n'est d'ailleurs pas branché à ce jour : le commerçant n'est
/// volontairement pas un utilisateur Fleetbase, donc le push natif ne peut pas
/// l'atteindre, et aucun credential serveur Firebase n'est configuré. Cet écran
/// est aujourd'hui le seul canal — raison de plus pour qu'il soit atteignable
/// en un tapotement depuis la liste des livraisons.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<MerchantOrderState>().loadNotifications();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MerchantOrderState>();
    final items = state.notifications;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (state.unreadNotifications > 0)
            TextButton(
              onPressed: () => state.markAllNotificationsRead(),
              child: const Text('Tout marquer lu'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => state.loadNotifications(),
        child: items.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.5,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.notifications_none,
                              size: 64, color: Colors.grey[400]),
                          const SizedBox(height: AppSpacing.lg),
                          Text('Aucune notification',
                              style: TextStyle(color: Colors.grey[600])),
                          const SizedBox(height: AppSpacing.sm),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
                            child: Text(
                              'Vous serez prévenu ici quand un transporteur '
                              'prend une de vos livraisons, et quand elle '
                              'arrive à destination.',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: Colors.grey[500], fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) => _NotificationTile(
                  notification: items[index],
                  onTap: () => _open(state, items[index]),
                ),
              ),
      ),
    );
  }

  /// Ouvrir une notification la marque lue et mène à la livraison concernée.
  ///
  /// Le marquage vient d'abord, et sans attendre le serveur : c'est le seul
  /// retour visible du geste. L'écart local/serveur, s'il y en a un, se
  /// résorbe au relevé suivant.
  Future<void> _open(MerchantOrderState state, MerchantNotification n) async {
    final router = GoRouter.of(context);
    await state.markNotificationRead(n.id);
    if (!mounted || n.orderId == null) return;
    router.push('/commercant/commandes/${n.orderId}');
  }
}

class _NotificationTile extends StatelessWidget {
  final MerchantNotification notification;
  final VoidCallback onTap;

  const _NotificationTile({required this.notification, required this.onTap});

  /// Icône et couleur par type d'évènement.
  ///
  /// Trois natures se distinguent au premier coup d'œil : ce qui progresse
  /// (bleu), ce qui aboutit (vert), ce qui demande une action (rouge). Un
  /// commerçant qui parcourt son journal doit repérer l'échec sans le lire.
  (IconData, Color) get _visual => switch (notification.type) {
        'order.assigned' => (Icons.local_shipping_outlined, Colors.blue),
        'order.completed' => (Icons.check_circle_outline, Colors.green),
        'order.failed' => (Icons.error_outline, Colors.red),
        'order.released' => (Icons.replay_outlined, Colors.orange),
        'order.canceled' => (Icons.cancel_outlined, Colors.grey),
        _ => (Icons.notifications_none, Colors.blueGrey),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _visual;

    return ListTile(
      onTap: onTap,
      // Icône nue plutôt que pastille teintée : `Color.withValues` n'existe
      // qu'à partir de Flutter 3.27 alors que le pubspec déclare 3.20, et la
      // couleur de l'icône porte déjà la distinction à elle seule.
      leading: Icon(icon, color: color),
      title: Text(
        notification.title,
        style: TextStyle(
          // Le gras porte l'information « pas encore vu », pas une pastille
          // supplémentaire : sur une liste, le contraste se lit plus vite
          // qu'un point à repérer.
          fontWeight: notification.read ? FontWeight.normal : FontWeight.bold,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(notification.body),
          const SizedBox(height: 2),
          Text(
            _relative(notification.createdAt),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: notification.orderId == null
          ? null
          : const Icon(Icons.chevron_right),
    );
  }

  /// Ancienneté en clair. « il y a 3 min » se situe sans effort, une date
  /// complète demande une soustraction mentale.
  static String _relative(DateTime date) {
    final delta = DateTime.now().difference(date);
    if (delta.inMinutes < 1) return 'à l\'instant';
    if (delta.inMinutes < 60) return 'il y a ${delta.inMinutes} min';
    if (delta.inHours < 24) return 'il y a ${delta.inHours} h';
    if (delta.inDays < 7) return 'il y a ${delta.inDays} j';

    final local = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}';
  }
}
