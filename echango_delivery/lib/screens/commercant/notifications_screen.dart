import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../i18n/order_strings.dart';
import '../../models/merchant_order.dart';
import '../../state/locale_state.dart';
import '../../state/merchant_order_state.dart';
import '../../theme/app_semantic_colors.dart';
import '../../utils/dates.dart';
import '../../widgets/empty_state.dart';

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
  String _t(String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

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
        title: Text(_t('order.notifications.title')),
        actions: [
          if (state.unreadNotifications > 0)
            TextButton(
              onPressed: () => state.markAllNotificationsRead(),
              child: Text(_t('order.notifications.mark_all')),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => state.loadNotifications(),
        child: items.isEmpty
            ? AppEmptyState(
                title: _t('order.notifications.empty'),
                hint: _t('order.notifications.empty.hint'),
                icon: Icons.notifications_none,
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
  /// Devenue une méthode : les couleurs viennent du thème, donc du contexte.
  (IconData, Color) _visual(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semantic;
    return switch (notification.type) {
      'order.assigned' => (Icons.local_shipping_outlined, scheme.primary),
      'order.completed' => (Icons.check_circle_outline, semantic.success),
      'order.failed' => (Icons.error_outline, scheme.error),
      'order.released' => (Icons.replay_outlined, semantic.warning),
      'order.canceled' => (Icons.cancel_outlined, scheme.onSurfaceVariant),
      _ => (Icons.notifications_none, scheme.onSurfaceVariant),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _visual(context);

    return ListTile(
      onTap: onTap,
      // Icône nue plutôt que pastille teintée : `Color.withValues` n'existe
      // qu'à partir de Flutter 3.27 alors que le pubspec déclare `>=3.24.0`, et
      // la couleur de l'icône porte déjà la distinction à elle seule.
      // (Le chiffre lu ici était `3.20` jusqu'au 01/08/2026 ; la borne était
      // fausse, mais ce refus-ci ne bouge pas — 3.27 reste au-dessus de 3.24.)
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
            // La locale est exigée depuis que cette fonction produit des mots :
            // « il y a 12 min » ne se lit pas dans un écran arabe. Le reste de
            // cet écran est encore en français en dur (dette assumée), mais on
            // n'ajoute pas un site qui *ne pourrait pas* suivre.
            formatRelative(
              notification.createdAt,
              context.watch<LocaleState>().locale,
            ),
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
}
