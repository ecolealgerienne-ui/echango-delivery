import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../i18n/common_strings.dart';
import '../../i18n/driver_strings.dart';
import '../../models/order.dart';
import '../../models/vehicle_type.dart';
import '../../state/auth_state.dart';
import '../../state/driver_presence_state.dart';
import '../../state/locale_state.dart';
import '../../state/order_state.dart';
import '../../widgets/consultation_map.dart';
import '../../widgets/trip_metrics.dart';
import '../../widgets/language_selector.dart';
import '../../theme/app_buttons.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/error_banner.dart';
import 'status_colors.dart';
import 'zone_card.dart';
import '../../widgets/section_card.dart';
import '../../utils/place_label.dart';

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
          // ⚠️ L'accès à la caisse a été retiré le 03/08/2026 avec le
          // registre : le transporteur déclare ce qu'il a perçu en clôturant
          // chaque livraison, et il n'y a plus de solde à consulter
          // (`docs/registre_caisse_precis.md`).
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
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _d(BuildContext context, String key,
          [Map<String, String>? vars]) =>
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
                      ? _d(context, 'driver.presence.online')
                      : _d(context, 'driver.presence.offline'),
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
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _d(BuildContext context, String key,
          [Map<String, String>? vars]) =>
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
            _d(context, 'driver.presence.offline.warning'),
            theme.colorScheme.secondaryContainer,
            theme.colorScheme.onSecondaryContainer,
          );
        }

        if (presence.online == true && !presence.pushAvailable) {
          return _banner(
            _d(context, 'driver.presence.push.unavailable'),
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
    // ⚠️ Nullable et non « = _d(…) » : un défaut de paramètre doit être une
    // constante de compilation, et un appel de traduction n'en est pas une.
    String? emptyLabel,
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
              child: _emptyState(
                  emptyLabel ?? _d('driver.empty.default'), emptyHint),
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
                  '${placeLabel(order.pickupPlace)} → ${placeLabel(order.dropoffPlace)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                // Longueur du trajet et distance à vide jusqu'à l'enlèvement :
                // ce qu'un transporteur regarde après le prix pour décider.
                TripMetricsRow(order: order, dense: true),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _d('driver.order.card.status', {'status': orderStateLabelForDriver(order, _d)}),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        // Le fond seul : ici le statut est du texte sur la carte,
                        // pas une puce — c'est la teinte de statut qui sert
                        // d'encre.
                        color: driverStatusColors(context, order.status).background,
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

/// La carte des courses EN COURS du conducteur.
///
/// ── Ce qu'elle montre, et ce qu'elle ne montre pas ────────────────────────
///
/// Les courses acceptées et non closes (`OrderState.activeOrders`), chacune
/// par ses deux points — enlèvement et livraison —, tapables pour ouvrir la
/// fiche. **Pas les opportunités du pool** : celles-là se choisissent dans
/// l'onglet « Courses libres », pas sur une carte d'ensemble.
///
/// ── Trois absences, trois messages (règle 10) ────────────────────────────
///
/// « aucune course en cours », « des courses mais aucune géolocalisée » (leurs
/// adresses ont été saisies sans la carte, `Place.latitude` nul) et « le
/// chargement a échoué » ne disent pas la même chose. Un seul « carte vide »
/// pour les trois se lirait comme une panne dans les deux cas où c'en est une,
/// et comme une panne à tort dans le troisième.
///
/// ── Pas de rechargement propre ───────────────────────────────────────────
///
/// L'état est celui que le tableau de bord tient déjà à jour (montage,
/// tirer-pour-rafraîchir de l'onglet liste, minuteur de présence). Le bouton
/// flottant relit à la demande ; il n'y a pas de second chemin de chargement.
class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  String _d(BuildContext context, String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OrderState>();
    final courses = state.activeOrders;

    // Deux points par course quand ils sont connus. Un lieu saisi sans la
    // carte a `latitude`/`longitude` nuls — il n'entre pas ici plutôt que
    // d'atterrir au large du golfe de Guinée.
    final points = <_CoursePoint>[];
    for (final o in courses) {
      final p = o.pickupPlace;
      if (p?.latitude != null && p?.longitude != null) {
        points.add(_CoursePoint(o, LatLng(p!.latitude!, p.longitude!), pickup: true));
      }
      final d = o.dropoffPlace;
      if (d?.latitude != null && d?.longitude != null) {
        points.add(_CoursePoint(o, LatLng(d!.latitude!, d.longitude!), pickup: false));
      }
    }

    if (courses.isEmpty) {
      if (state.isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (state.errorMessage != null) {
        return AppEmptyState.unavailable(
          title: _d(context, 'driver.map.unavailable'),
          hint: _d(context, 'driver.map.unavailable.hint'),
          onRetry: () => context.read<OrderState>().loadOrders(),
        );
      }
      return AppEmptyState(
        icon: Icons.map_outlined,
        title: _d(context, 'driver.map.empty'),
        hint: _d(context, 'driver.map.empty.hint'),
      );
    }

    if (points.isEmpty) {
      return AppEmptyState(
        icon: Icons.wrong_location_outlined,
        title: _d(context, 'driver.map.no_positions'),
        hint: _d(context, 'driver.map.no_positions.hint'),
      );
    }

    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        AppConsultationMap(
          // Toutes les courses tiennent dans la vue — sinon, dès qu'une course
          // est loin des autres, l'écran ne montre que du désert entre elles.
          fitPoints: [for (final cp in points) cp.at],
          markers: [
            for (final cp in points)
              consultationMarker(
                context,
                at: cp.at,
                kind: cp.pickup ? MapMarkerKind.pickup : MapMarkerKind.dropoff,
                tooltip: cp.pickup
                    ? _d(context, 'driver.map.pickup')
                    : _d(context, 'driver.map.dropoff'),
                onTap: () {
                  context.read<OrderState>().selectOrder(cp.order.id);
                  context.push('/transporteur/commandes/${cp.order.id}');
                },
              ),
          ],
        ),
        Positioned(
          left: AppSpacing.md,
          top: AppSpacing.md,
          child: Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppSpacing.sm),
            child: const Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              child: MapLegend(),
            ),
          ),
        ),
        Positioned(
          right: AppSpacing.md,
          bottom: AppSpacing.md,
          child: FloatingActionButton.small(
            heroTag: 'driver-map-refresh',
            tooltip: _d(context, 'driver.map.refresh'),
            onPressed: () => context.read<OrderState>().loadOrders(),
            child: const Icon(Icons.refresh),
          ),
        ),
      ],
    );
  }

}

/// Un point porté par une course en cours — enlèvement ou livraison.
class _CoursePoint {
  const _CoursePoint(this.order, this.at, {required this.pickup});

  final Order order;
  final LatLng at;
  final bool pickup;
}

/// Écran de profil avec logout.
class ProfileScreen extends StatelessWidget {
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _d(BuildContext context, String key,
          [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _c(BuildContext context, String key) =>
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
                            authState.email ?? _d(context, 'driver.profile.fallback'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            _d(context, 'driver.profile.role',
                                {
                                  'role': authState.role
                                          ?.label(context.read<LocaleState>().locale) ??
                                      '—'
                                }),
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
          const SizedBox(height: AppSpacing.lg),
          // Juste sous le véhicule : les deux répondent à la même question —
          // « quelles courses me sont proposées » — et les séparer obligerait
          // à chercher dans deux endroits pourquoi la liste est courte.
          const ZoneCard(),
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
                        _d(context, 'driver.logout'),
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
      title: _d(context, 'driver.logout'),
      message: _d(context, 'driver.logout.body'),
      cancelLabel: _c(context, 'common.cancel'),
      confirmLabel: _d(context, 'driver.logout'),
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
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _d(BuildContext context, String key,
          [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  const _VehicleTypeCard();

  /// Libellés courts, tenus dans la largeur du menu.
  ///
  /// « Non déclaré — je vois toutes les courses » débordait de 9 px sur un
  /// téléphone ordinaire. L'information qu'il portait n'est pas perdue : elle
  /// passe dans le texte d'aide ci-dessous, qui a la place de la dire en entier
  /// et peut l'adapter au choix courant.
  ///
  /// ⚠️ Construite dans le `build` et non en champ `static final` : un
  /// initialiseur de champ ne peut pas appeler un membre d'instance, et la
  /// table dépend de toute façon de la langue courante.
  Map<String?, String> _options(BuildContext context) => {
        null: _d(context, 'driver.vehicle.none'),
        'moto': _d(context, 'driver.vehicle.moto'),
        'voiture': _d(context, 'driver.vehicle.voiture'),
        'utilitaire': _d(context, 'driver.vehicle.utilitaire'),
      };

  @override
  Widget build(BuildContext context) {
    return Consumer<DriverPresenceState>(
      builder: (context, presence, _) => AppSectionCard(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_d(context, 'driver.vehicle.title'), style: Theme.of(context).textTheme.titleMedium),
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
                items: _options(context).entries
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
                    ? _d(context, 'driver.vehicle.hint.none')
                    : _d(context, 'driver.vehicle.hint.set'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
      ),
    );
  }
}
