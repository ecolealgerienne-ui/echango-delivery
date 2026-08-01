import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../i18n/common_strings.dart';
import '../../i18n/driver_strings.dart';
import '../../models/order.dart';
import '../../models/vehicle_type.dart';
import '../../state/auth_state.dart';
import '../../state/driver_presence_state.dart';
import '../../state/locale_state.dart';
import '../../state/order_state.dart';
import '../../widgets/language_selector.dart';
import '../../theme/app_buttons.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/error_banner.dart';
import 'status_colors.dart';
import '../../widgets/section_card.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _d(String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Charge les commandes au démarrage du dashboard
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<OrderState>().loadOrders();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Echango Delivery'),
        elevation: 0,
        actions: [
          // La caisse est accessible depuis l'accueil : un transporteur qui
          // détient des espèces doit pouvoir vérifier ce qu'il doit sans
          // chercher, notamment au moment d'un enlèvement chez le commerçant
          // concerné — c'est là que la remise se fait.
          IconButton(
            tooltip: _d('driver.home.cash'),
            icon: const Icon(Icons.account_balance_wallet_outlined),
            onPressed: () => context.push('/transporteur/caisse'),
          ),
          // Les entreprises pour lesquelles il roule — et surtout **les demandes
          // en attente**. Sans accès depuis l'accueil, une demande de
          // rattachement resterait invisible : le conducteur ne la découvrirait
          // qu'en cherchant un écran dont il ignore l'existence, et l'entreprise
          // conclurait à un refus.
          IconButton(
            tooltip: _d('driver.home.fleets'),
            icon: const Icon(Icons.business_outlined),
            onPressed: () => context.push('/transporteur/entreprises'),
          ),
          const LanguageSelector(),
          const _AvailabilitySwitch(),
        ],
      ),
      body: Column(
        children: [
          const _PresenceBanner(),
          Expanded(child: _buildBody()),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() => _selectedIndex = index);
        },
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.list),
            label: _d('driver.home.orders'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.map),
            label: _d('driver.home.map'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.person),
            label: _d('driver.home.profile'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_selectedIndex) {
      case 0:
        return const OrdersListScreen();
      case 1:
        return const MapScreen();
      case 2:
        return const ProfileScreen();
      default:
        return const OrdersListScreen();
    }
  }
}

/// Interrupteur de disponibilité.
///
/// C'est la commande la plus conséquente de l'app côté transporteur : hors
/// ligne, Fleetbase ne diffuse aucune course à ce driver. Elle est donc à
/// portée permanente dans la barre, et pas enterrée dans le profil.
class _AvailabilitySwitch extends StatelessWidget {
  String _d(String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  const _AvailabilitySwitch();

  @override
  Widget build(BuildContext context) {
    return Consumer<DriverPresenceState>(
      builder: (context, presence, _) {
        final online = presence.online;

        return Row(
          children: [
            Text(
              online == null
                  ? '—'
                  : online
                      ? _d('driver.presence.online')
                      : _d('driver.presence.offline'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (presence.isBusy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              Switch(
                // `null` signifie « disponibilité inconnue » (Fleetbase
                // injoignable). L'interrupteur reste manipulable : le driver
                // doit pouvoir forcer son état, c'est le libellé « — » qui
                // porte l'incertitude.
                value: online ?? false,
                onChanged: (value) => presence.setOnline(value),
              ),
          ],
        );
      },
    );
  }
}

/// Ce qui empêche le driver de recevoir des courses, dit explicitement.
///
/// Sans ça, une permission refusée ou un push non configuré se traduit par un
/// écran vide indiscernable d'une absence réelle de course — le mode d'échec
/// le plus coûteux à diagnostiquer sur le terrain.
class _PresenceBanner extends StatelessWidget {
  String _d(String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  const _PresenceBanner();

  @override
  Widget build(BuildContext context) {
    return Consumer<DriverPresenceState>(
      builder: (context, presence, _) {
        final theme = Theme.of(context);
        final error = presence.errorMessage;

        if (error != null) {
          return _banner(
            error,
            theme.colorScheme.errorContainer,
            theme.colorScheme.onErrorContainer,
          );
        }

        if (presence.online == false) {
          return _banner(
            _d('driver.presence.offline.warning'),
            theme.colorScheme.secondaryContainer,
            theme.colorScheme.onSecondaryContainer,
          );
        }

        if (presence.online == true && !presence.pushAvailable) {
          return _banner(
            _d('driver.presence.push.unavailable'),
            theme.colorScheme.surfaceContainerHighest,
            theme.colorScheme.onSurfaceVariant,
          );
        }

        return const SizedBox.shrink();
      },
    );
  }

  Widget _banner(String text, Color bg, Color fg) {
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 10),
      child: Text(text, style: TextStyle(color: fg)),
    );
  }
}

/// Écran liste des commandes avec filtrage par statut.
class OrdersListScreen extends StatefulWidget {
  const OrdersListScreen({super.key});

  @override
  State<OrdersListScreen> createState() => _OrdersListScreenState();
}

class _OrdersListScreenState extends State<OrdersListScreen>
    with SingleTickerProviderStateMixin {
  String _d(String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

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
    final errorMessage = context.watch<OrderState>().errorMessage;

    return Column(
      children: [
        // Sans ça, un échec de chargement est indiscernable d'une liste
        // réellement vide — c'est exactement ce qui rend un premier lancement
        // impossible à diagnostiquer.
        if (errorMessage != null) AppErrorBanner(message: errorMessage),
        TabBar(
          controller: _tabController,
          // Les trois catégories de la spec §4.1. « Opportunités » remplace
          // « Pending » : ce sont les commandes adhoc diffusées à proximité,
          // que le driver peut réclamer — elles ne lui sont pas encore
          // assignées, donc invisibles dans une vue « mes commandes ».
          tabs: [
            Tab(text: _d('driver.tab.opportunities')),
            Tab(text: _d('driver.tab.active')),
            Tab(text: _d('driver.tab.history')),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOrdersList(
                context.watch<OrderState>().adhocOrders,
                emptyLabel: _d('driver.empty.opportunities'),
                emptyHint: _d('driver.empty.opportunities.hint'),
              ),
              _buildOrdersList(
                context.watch<OrderState>().activeOrders,
                emptyLabel: _d('driver.empty.active'),
                // Consignes écrites parce que le composant les exige : ces
                // deux onglets n'en avaient aucune, et un écran vide sans un
                // mot se lit comme une panne plutôt que comme un début.
                emptyHint: _d('driver.empty.active.hint'),
              ),
              _buildOrdersList(
                context.watch<OrderState>().historyOrders,
                emptyLabel: _d('driver.empty.history'),
                emptyHint: _d('driver.empty.history.hint'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOrdersList(
    List<dynamic> orders, {
    String emptyLabel = _d('driver.empty.default'),
    // Non nullable : `AppEmptyState` exige sa consigne, et une liste vide sans
    // explication se lit comme une panne.
    required String emptyHint,
  }) {
    // RefreshIndicator exige un enfant défilable pour capter le geste : sans
    // AlwaysScrollableScrollPhysics sur une liste vide, tirer vers le bas ne
    // déclenche rien — précisément le cas où l'on veut recharger.
    if (orders.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => context.read<OrderState>().loadOrders(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: _emptyState(emptyLabel, emptyHint),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => context.read<OrderState>().loadOrders(),
      child: _ordersListView(orders),
    );
  }

  Widget _emptyState(String emptyLabel, String emptyHint) {
    return AppEmptyState(
      title: emptyLabel,
      hint: emptyHint,
      // Déjà placé dans le `ListView` qui capte le tirer-pour-rafraîchir.
      scrollable: false,
    );
  }

  Widget _ordersListView(List<dynamic> orders) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.sm),
      itemCount: orders.length,
      itemBuilder: (context, index) {
        final order = orders[index];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: 0),
          child: ListTile(
            title: Row(
              children: [
                Expanded(
                    child:
                        Text(_d('driver.order.card.number', {'id': order.publicId}))),
                // Le prix en tête de carte : c'est sur lui que le transporteur
                // décide de prendre la course ou non. L'enterrer dans le détail
                // obligerait à ouvrir chaque opportunité pour le savoir.
                if (order.formattedPrice != null)
                  Text(
                    order.formattedPrice!,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: context.semantic.success,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppSpacing.xs),
                // ⚠️ Pas `name` seul : il est **absent** sur une course non
                // réclamée (c'est celui du destinataire), et la ligne se
                // lisait « MAGASIN1 →  » sur chaque opportunité.
                Text(
                  '${_placeLabel(order.pickupPlace)} → ${_placeLabel(order.dropoffPlace)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _d('driver.order.card.status', {'status': order.status}),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: driverStatusColor(context, order.status),
                      ),
                ),
              ],
            ),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              context.read<OrderState>().selectOrder(order.id);
              context.push('/transporteur/commandes/${order.id}');
            },
          ),
        );
      },
    );
  }

}

/// Écran de la carte.
class MapScreen extends StatelessWidget {
  String _d(String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.map_outlined,
            size: 80,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            _d('driver.map.unavailable'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _d('driver.map.unavailable.hint'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Écran de profil avec logout.
class ProfileScreen extends StatelessWidget {
  String _d(String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  String _c(String key) =>
      commonLabel(key, context.read<LocaleState>().locale);

  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpacing.lg),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                children: [
                  Icon(
                    Icons.account_circle_outlined,
                    size: 80,
                    color: Theme.of(context).primaryColor,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Consumer<AuthState>(
                    builder: (context, authState, _) {
                      return Column(
                        children: [
                          Text(
                            authState.email ?? _d('driver.profile.fallback'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            _d('driver.profile.role',
                                {'role': authState.role?.label ?? '—'}),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const _VehicleTypeCard(),
          const SizedBox(height: AppSpacing.xxl),
          Consumer<AuthState>(
            builder: (context, authState, _) {
              return FilledButton(
                onPressed: authState.isLoading
                    ? null
                    : () => _handleLogout(context, authState),
                style: AppButtonStyles.destructiveFilled(
                  context,
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                ),
                child: authState.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        // La couleur suit le `foregroundColor` du bouton :
                        // la poser en dur la désaccordait du thème.
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _d('driver.logout'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _handleLogout(
    BuildContext context,
    AuthState authState,
  ) async {
    final confirmed = await AppConfirmDialog.destructive(
      context,
      title: _d('driver.logout'),
      message: _d('driver.logout.body'),
      cancelLabel: _c('common.cancel'),
      confirmLabel: _d('driver.logout'),
    );

    if (confirmed) {
      await authState.logout();
      if (context.mounted) {
        context.go('/login');
      }
    }
  }
}


/// Déclaration de la catégorie de véhicule.
///
/// Ne rien déclarer est le comportement le plus ouvert : le transporteur voit
/// toutes les courses. Le dire explicitement à l'écran évite qu'il croie devoir
/// remplir le champ pour recevoir du travail — l'inverse serait vrai.
class _VehicleTypeCard extends StatelessWidget {
  String _d(String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  const _VehicleTypeCard();

  /// Libellés courts, tenus dans la largeur du menu.
  ///
  /// « Non déclaré — je vois toutes les courses » débordait de 9 px sur un
  /// téléphone ordinaire. L'information qu'il portait n'est pas perdue : elle
  /// passe dans le texte d'aide ci-dessous, qui a la place de la dire en entier
  /// et peut l'adapter au choix courant.
  static final _options = {
    null: _d('driver.vehicle.none'),
    'moto': _d('driver.vehicle.moto'),
    'voiture': _d('driver.vehicle.voiture'),
    'utilitaire': _d('driver.vehicle.utilitaire'),
  };

  @override
  Widget build(BuildContext context) {
    return Consumer<DriverPresenceState>(
      builder: (context, presence, _) => AppSectionCard(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_d('driver.vehicle.title'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String?>(
                initialValue: presence.vehicleType,
                // Le bouton prend toute la largeur disponible et contraint son
                // enfant, au lieu de le laisser prendre sa taille naturelle et
                // déborder. Avec l'ellipse ci-dessous, un libellé long sur un
                // écran étroit se tronque au lieu de casser la mise en page.
                isExpanded: true,
                decoration: InputDecoration(
                  prefixIcon: Icon(vehicleIcon(presence.vehicleType)),
                  isDense: true,
                ),
                items: _options.entries
                    .map((e) => DropdownMenuItem<String?>(
                          value: e.key,
                          child: Text(e.value, overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: presence.isBusy
                    ? null
                    : (v) => presence.setVehicleType(v),
              ),
              const SizedBox(height: AppSpacing.sm),
              // Le texte d'aide suit le choix : sans véhicule déclaré, la phrase
              // sur les courses trop grandes ne s'applique pas, et celle qui
              // compte est l'inverse — rien n'est filtré. Une aide qui décrit
              // une règle inactive est pire qu'une absence d'aide.
              Text(
                presence.vehicleType == null
                    ? _d('driver.vehicle.hint.none')
                    : _d('driver.vehicle.hint.set'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
      ),
    );
  }
}

/// Comment nommer un lieu quand son nom a été retiré.
///
/// Sur une course non réclamée, le serveur ne sert plus le nom du destinataire —
/// il ne le remplace pas non plus par un libellé, il l'omet (31/07/2026). Sans
/// repli, la ligne affichait « MAGASIN1 →  », un tiret vers rien.
///
/// L'ordre suit l'utilité : le nom quand il existe, sinon l'adresse recomposée
/// à partir des seules composantes structurées, sinon rien plutôt qu'un
/// point d'interrogation.
String _placeLabel(Place? place) {
  if (place == null) return '—';
  if (place.name.trim().isNotEmpty) return place.name.trim();
  if (place.address.trim().isNotEmpty) return place.address.trim();
  return '—';
}
