import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/vehicle_type.dart';
import '../../state/auth_state.dart';
import '../../state/driver_presence_state.dart';
import '../../state/order_state.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
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
            tooltip: 'Ma caisse',
            icon: const Icon(Icons.account_balance_wallet_outlined),
            onPressed: () => context.push('/transporteur/caisse'),
          ),
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
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.list),
            label: 'Commandes',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: 'Carte',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profil',
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
                      ? 'En ligne'
                      : 'Hors ligne',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (presence.isBusy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
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
            'Vous êtes hors ligne : aucune course ne vous sera proposée.',
            theme.colorScheme.secondaryContainer,
            theme.colorScheme.onSecondaryContainer,
          );
        }

        if (presence.online == true && !presence.pushAvailable) {
          return _banner(
            'Notifications indisponibles sur cet appareil — la liste se '
            'rafraîchit automatiquement, avec un léger délai.',
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
        if (errorMessage != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.all(12),
            child: Text(
              errorMessage,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        TabBar(
          controller: _tabController,
          // Les trois catégories de la spec §4.1. « Opportunités » remplace
          // « Pending » : ce sont les commandes adhoc diffusées à proximité,
          // que le driver peut réclamer — elles ne lui sont pas encore
          // assignées, donc invisibles dans une vue « mes commandes ».
          tabs: const [
            Tab(text: 'Opportunités'),
            Tab(text: 'En cours'),
            Tab(text: 'Historique'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOrdersList(
                context.watch<OrderState>().adhocOrders,
                emptyLabel: 'Aucune opportunité à proximité',
                emptyHint: 'Vérifier que vous êtes en ligne : le dispatch '
                    'est géographique.',
              ),
              _buildOrdersList(
                context.watch<OrderState>().activeOrders,
                emptyLabel: 'Aucune commande en cours',
              ),
              _buildOrdersList(
                context.watch<OrderState>().historyOrders,
                emptyLabel: 'Aucune commande terminée',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOrdersList(
    List<dynamic> orders, {
    String emptyLabel = 'Aucune commande',
    String? emptyHint,
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

  Widget _emptyState(String emptyLabel, String? emptyHint) {
    return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              emptyLabel,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            if (emptyHint != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  emptyHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[500],
                      ),
                ),
              ),
            ],
          ],
      ),
    );
  }

  Widget _ordersListView(List<dynamic> orders) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      itemCount: orders.length,
      itemBuilder: (context, index) {
        final order = orders[index];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
          child: ListTile(
            title: Row(
              children: [
                Expanded(child: Text('Commande #${order.publicId}')),
                // Le prix en tête de carte : c'est sur lui que le transporteur
                // décide de prendre la course ou non. L'enterrer dans le détail
                // obligerait à ouvrir chaque opportunité pour le savoir.
                if (order.formattedPrice != null)
                  Text(
                    order.formattedPrice!,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Colors.green.shade800,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  '${order.pickupPlace?.name} → ${order.dropoffPlace?.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  'Statut : ${order.status}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _getStatusColor(order.status),
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

/// Écran de la carte.
class MapScreen extends StatelessWidget {
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
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            'Carte non disponible',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'La carte des courses n\'est pas encore implémentée.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }
}

/// Écran de profil avec logout.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(
                    Icons.account_circle_outlined,
                    size: 80,
                    color: Theme.of(context).primaryColor,
                  ),
                  const SizedBox(height: 16),
                  Consumer<AuthState>(
                    builder: (context, authState, _) {
                      return Column(
                        children: [
                          Text(
                            authState.email ?? 'Transporteur',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Profil : ${authState.role?.label ?? '—'}',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _VehicleTypeCard(),
          const SizedBox(height: 32),
          Consumer<AuthState>(
            builder: (context, authState, _) {
              return ElevatedButton(
                onPressed: authState.isLoading
                    ? null
                    : () => _handleLogout(context, authState),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: authState.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        'Se déconnecter',
                        style: TextStyle(
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Se déconnecter'),
        content: const Text(
          'Vous serez basculé hors ligne et ne recevrez plus de courses.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Se déconnecter'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
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
  const _VehicleTypeCard();

  /// Libellés courts, tenus dans la largeur du menu.
  ///
  /// « Non déclaré — je vois toutes les courses » débordait de 9 px sur un
  /// téléphone ordinaire. L'information qu'il portait n'est pas perdue : elle
  /// passe dans le texte d'aide ci-dessous, qui a la place de la dire en entier
  /// et peut l'adapter au choix courant.
  static const _options = {
    null: 'Non déclaré',
    'moto': 'Moto',
    'voiture': 'Voiture',
    'utilitaire': 'Utilitaire',
  };

  @override
  Widget build(BuildContext context) {
    return Consumer<DriverPresenceState>(
      builder: (context, presence, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Mon véhicule', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: presence.vehicleType,
                // Le bouton prend toute la largeur disponible et contraint son
                // enfant, au lieu de le laisser prendre sa taille naturelle et
                // déborder. Avec l'ellipse ci-dessous, un libellé long sur un
                // écran étroit se tronque au lieu de casser la mise en page.
                isExpanded: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
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
              const SizedBox(height: 8),
              // Le texte d'aide suit le choix : sans véhicule déclaré, la phrase
              // sur les courses trop grandes ne s'applique pas, et celle qui
              // compte est l'inverse — rien n'est filtré. Une aide qui décrit
              // une règle inactive est pire qu'une absence d'aide.
              Text(
                presence.vehicleType == null
                    ? 'Sans véhicule déclaré, toutes les courses vous sont proposées.'
                    : 'Une course exigeant un véhicule plus grand ne vous sera pas '
                        'proposée.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
