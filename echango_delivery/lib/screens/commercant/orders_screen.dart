import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../state/auth_state.dart';
import '../../state/locale_state.dart';
import '../../i18n/order_strings.dart';
import '../../state/merchant_order_state.dart';
import '../../widgets/language_selector.dart';
import '../../widgets/persona_scaffold.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/load_more_footer.dart';
import '../../utils/reorder.dart';
import 'addresses_screen.dart';
import 'favourite_drivers_screen.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  String _t(String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

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
    final unread = orderState.unreadNotifications;

    return PersonaScaffold(
      title: authState.displayName ?? _t('order.list.title'),
      appBarActions: const [LanguageSelector()],
      floatingActionButtonFor: (index) => index != 0
          ? null
          : FloatingActionButton.extended(
              onPressed: _showNewCourseSheet,
              icon: const Icon(Icons.add),
              label: Text(_t('order.new.fab')),
            ),
      destinations: [
        PersonaDestination(
          icon: Icons.receipt_long_outlined,
          selectedIcon: Icons.receipt_long,
          label: _t('order.nav.orders'),
          // Pastille sur l'onglet : sans envoi push, c'est le seul signal
          // qu'un évènement est arrivé. L'ouverture des notifications, elle,
          // vit dans le panneau « Plus ».
          badge: unread > 0 ? Text('$unread') : null,
          body: const _MerchantOrdersBody(),
        ),
        PersonaDestination(
          // ⚠️ **Pas `bookmark_*`** : le formulaire de création affiche deux
          // boutons « carnet » avec cette icône, et un parcours d'intégration
          // en attend exactement deux (`pickFromBook`). Une troisième dans la
          // barre du bas casserait le compte.
          icon: Icons.import_contacts_outlined,
          selectedIcon: Icons.import_contacts,
          label: _t('order.nav.addresses'),
          body: const AddressesScreen(embedded: true),
        ),
        PersonaDestination(
          icon: Icons.star_border,
          selectedIcon: Icons.star,
          label: _t('order.nav.favourites'),
          body: const FavouriteDriversScreen(embedded: true),
        ),
        PersonaDestination(
          icon: Icons.more_horiz,
          label: _t('order.nav.more'),
          body: const _MerchantMorePanel(),
        ),
      ],
    );
  }

  /// Le point d'entrée unique de la création : une livraison simple, ou une
  /// tournée à plusieurs arrêts. Les deux menaient chacun à un endroit
  /// différent — le « + » pour la première, le panneau « Plus » pour la
  /// seconde —, si bien qu'un commerçant qui cherchait « comment livrer à
  /// plusieurs adresses » ne trouvait pas (retour utilisateur du 09/2026).
  void _showNewCourseSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md,
                  AppSpacing.lg, AppSpacing.xs),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(_t('order.new.sheet'),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.local_shipping_outlined),
              title: Text(_t('order.new.delivery')),
              subtitle: Text(_t('order.new.delivery.hint')),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push('/commercant/nouvelle');
              },
            ),
            ListTile(
              leading: const Icon(Icons.alt_route),
              title: Text(_t('order.new.tournee')),
              subtitle: Text(_t('order.new.tournee.hint')),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push('/commercant/tournees');
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// L'onglet « Commandes » : recherche + « En cours » / « Terminées ».
class _MerchantOrdersBody extends StatelessWidget {
  const _MerchantOrdersBody();

  String _t(BuildContext context, String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

  @override
  Widget build(BuildContext context) {
    final orderState = context.watch<MerchantOrderState>();

    return DefaultTabController(
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
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
            child: TextField(
              onChanged: orderState.setSearch,
              decoration: InputDecoration(
                hintText: _t(context, 'order.list.search'),
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
          TabBar(
            tabs: [
              Tab(text: _t(context, 'order.list.tab.active')),
              Tab(text: _t(context, 'order.list.tab.done')),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _OrderList(
                  orders: orderState.activeOrders,
                  emptyLabel: _t(context, 'order.list.empty.active'),
                  emptyHint: _t(context, 'order.list.empty.active.hint'),
                ),
                _OrderList(
                  orders: orderState.pastOrders,
                  emptyLabel: _t(context, 'order.list.empty.done'),
                  emptyHint: _t(context, 'order.list.empty.done.hint'),
                  showReorder: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Le panneau « Plus » : ce qui n'est pas une destination de premier rang —
/// encaissements, notifications, tournée multi-arrêt, déconnexion.
class _MerchantMorePanel extends StatelessWidget {
  const _MerchantMorePanel();

  String _t(BuildContext context, String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

  @override
  Widget build(BuildContext context) {
    final unread = context.watch<MerchantOrderState>().unreadNotifications;

    return ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.notifications_none),
          title: Text(_t(context, 'order.list.notifications')),
          trailing: unread > 0
              ? Badge(label: Text('$unread'))
              : const Icon(Icons.chevron_right),
          onTap: () => context.push('/commercant/notifications'),
        ),
        ListTile(
          leading: const Icon(Icons.account_balance_wallet_outlined),
          title: Text(_t(context, 'order.list.cash')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/commercant/encaissements'),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.logout),
          title: Text(_t(context, 'order.list.logout')),
          onTap: () async {
            final router = GoRouter.of(context);
            await context.read<AuthState>().logout();
            router.go('/login');
          },
        ),
      ],
    );
  }
}

class _OrderList extends StatelessWidget {
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _t(BuildContext context, String key,
          [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

  final List<MerchantOrder> orders;
  final String emptyLabel;

  /// Non nullable, contrairement à avant : `AppEmptyState` exige sa consigne,
  /// et l'onglet « terminées » n'en avait aucune — une liste vide sans mot
  /// d'explication se lit comme une panne.
  final String emptyHint;

  /// Affiche « Refaire » sur chaque carte (onglet « Terminées » uniquement) :
  /// une livraison passée est le point de départ le plus fréquent d'une
  /// nouvelle (« la même que la dernière fois »). Ailleurs c'est du bruit — une
  /// course en cours ne se « refait » pas.
  final bool showReorder;

  const _OrderList({
    required this.orders,
    required this.emptyLabel,
    required this.emptyHint,
    this.showReorder = false,
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
              label: _t(context, 'order.list.more'),
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
                      order.dropoff?.name ?? _t(context, 'order.list.fallback'),
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
                    Text(_t(context, 'order.list.driver', {'name': order.driverName!}),
                        style: const TextStyle(fontSize: 12)),
                ],
              ),
              trailing: showReorder
                  ? TextButton.icon(
                      onPressed: () => reorderOrder(context, order.id),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(_t(context, 'order.list.reorder')),
                    )
                  : const Icon(Icons.chevron_right),
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
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _t(BuildContext context, String key,
          [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

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
        label: Text(_t(context, 'order.list.status.unavailable'),
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
