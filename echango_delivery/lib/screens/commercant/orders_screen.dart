import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../state/auth_state.dart';
import '../../state/locale_state.dart';
import '../../state/merchant_order_state.dart';
import '../../widgets/language_selector.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/load_more_footer.dart';

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
          const LanguageSelector(),
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
            tooltip: 'Encaissements',
            icon: const Icon(Icons.account_balance_wallet_outlined),
            onPressed: () => context.push('/commercant/encaissements'),
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
              AppErrorBanner(
                message: orderState.errorMessage!,
                onRetry: () => context.read<MerchantOrderState>().loadOrders(),
              ),
            // Recherche sur les commandes chargées. Le libellé dit la limite :
            // laisser croire à une recherche exhaustive ferait conclure « je
            // n'ai jamais livré ce client » sur une liste partielle.
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
              child: TextField(
                onChanged: orderState.setSearch,
                decoration: InputDecoration(
                  hintText: 'Rechercher un destinataire, une adresse…',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  suffixIcon: orderState.search.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => orderState.setSearch(''),
                        ),
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
                    // Consigne écrite parce que le composant l'exige — cet
                    // onglet n'en avait aucune, et « Aucune livraison
                    // terminée » sur un compte neuf se lit comme une panne
                    // plutôt que comme un début.
                    emptyHint: 'Vos livraisons achevées ou annulées se '
                        'rangeront ici, avec leur preuve de remise.',
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

  /// Non nullable, contrairement à avant : `AppEmptyState` exige sa consigne,
  /// et l'onglet « terminées » n'en avait aucune — une liste vide sans mot
  /// d'explication se lit comme une panne.
  final String emptyHint;

  const _OrderList({
    required this.orders,
    required this.emptyLabel,
    required this.emptyHint,
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
      // justement là qu'on en a besoin. `AppEmptyState` rend sa propre liste
      // défilable, avec la physique qu'il faut pour capter le geste.
      return RefreshIndicator(
        onRefresh: refresh,
        child: AppEmptyState(
          title: emptyLabel,
          hint: emptyHint,
          icon: Icons.local_shipping_outlined,
        ),
      );
    }

    final state = context.watch<MerchantOrderState>();
    // Le bouton n'apparaît que s'il reste vraiment quelque chose : le total
    // vient du serveur, pas d'une supposition sur la taille de page.
    final showMore = state.hasMoreOrders && state.search.isEmpty;

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.sm),
        itemCount: orders.length + (showMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == orders.length) {
            return AppLoadMore(
              isLoading: state.isLoadingMore,
              label: 'Charger les livraisons précédentes',
              onPressed: state.loadMoreOrders,
            );
          }

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
                  const SizedBox(width: AppSpacing.sm),
                  _StatusChip(order: order),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: AppSpacing.xs),
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
    // Le libellé vient de `MerchantOrder.statusLabel`, jamais d'une table
    // recopiée ici : la fiche et la liste affichaient deux textes différents
    // pour la même commande, faute d'une source commune. Seule la couleur
    // reste locale — c'est de la présentation, pas du vocabulaire métier.
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semantic;

    // Fond ET texte sont décidés ensemble : la version précédente posait un
    // `Colors.white` unique sur cinq fonds différents, donc le contraste
    // dépendait du hasard de la teinte choisie.
    final neutral = (scheme.secondaryContainer, scheme.onSecondaryContainer);

    if (order.degraded) {
      return Chip(
        label: Text('État indisponible',
            style: TextStyle(fontSize: 11, color: neutral.$2)),
        backgroundColor: neutral.$1,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
    }

    final (Color background, Color foreground) = switch (order.status) {
      'completed' => (semantic.success, semantic.onSuccess),
      'canceled' || 'cancelled' => (scheme.outlineVariant, scheme.onSurface),
      // Neutre comme « indisponible » : un brouillon n'est pas une livraison
      // en cours, l'avertissement l'aurait fait passer pour une attente active
      // alors que rien n'a démarré.
      'created' => neutral,
      'dispatched' => (semantic.warning, semantic.onWarning),
      'started' || 'enroute' => (scheme.primary, scheme.onPrimary),
      _ => neutral,
    };

    return Chip(
      label: Text(order.statusLabel(context.watch<LocaleState>().locale),
          style: TextStyle(fontSize: 11, color: foreground)),
      backgroundColor: background,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
