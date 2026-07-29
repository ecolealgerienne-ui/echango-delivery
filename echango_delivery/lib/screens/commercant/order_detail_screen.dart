import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../models/order.dart' show DeliveryFailure;
import '../../models/vehicle_type.dart';
import '../../services/navigation_launcher.dart';
import '../../state/merchant_order_state.dart';
import '../../widgets/proof_image.dart';

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
                    if (order.driverName != null) _driverCard(order),
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
                    // Signalements d'échec : le commerçant devra répondre à son
                    // client, et le justificatif n'allait jusqu'ici qu'à celui
                    // qui l'avait produit.
                    if (order.deliveryFailures.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _FailureHistory(failures: order.deliveryFailures),
                    ],
                    if (order.isCompleted) ...[
                      const SizedBox(height: 12),
                      _proofCard(),
                    ],
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

  /// Le transporteur affecté, joignable.
  ///
  /// Le téléphone était déjà dans la réponse du serveur et n'était lu par
  /// personne : un commerçant qui voulait savoir où en était sa livraison
  /// n'avait aucun moyen d'appeler le coursier.
  ///
  /// La carte n'apparaît qu'une fois quelqu'un affecté — avant, il n'y a rien
  /// à montrer, et un cadre vide se lit comme une panne.
  Widget _driverCard(MerchantOrder order) => Card(
        color: Colors.blue.shade50,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.local_shipping_outlined),
              title: Text('Pris en charge par ${order.driverName}'),
              subtitle: order.driverPhone == null
                  ? null
                  : Text(order.driverPhone!),
              trailing: order.driverPhone == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.phone),
                      tooltip: 'Appeler le transporteur',
                      onPressed: () => NavigationLauncher.call(order.driverPhone!),
                    ),
            ),
            // La carte n'a de sens que tant que la course est en cours : une
            // fois livrée, la position du transporteur ne dit plus rien de
            // cette commande — il est déjà ailleurs.
            if (!order.isFinished) _DriverMap(orderId: widget.orderId, order: order),
          ],
        ),
      );

  /// Preuve de livraison.
  ///
  /// Chargée sans condition sur une commande livrée : le serveur seul sait si
  /// une preuve existe, et il répond 404 sinon — ce que [ProofImage] affiche
  /// comme un chargement impossible. Interroger d'abord pour n'afficher
  /// qu'ensuite doublerait les allers-retours pour le même résultat.
  Widget _proofCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Preuve de livraison',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              ProofImage(url: '/commercant/commandes/${widget.orderId}/preuve'),
            ],
          ),
        ),
      );

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

/// Dernière position connue du transporteur, sur une carte.
///
/// ── Ce que cet écran montre, et ce qu'il ne montre pas ──────────────────────
///
/// Un **point**, pas un suivi en direct : la position que le transporteur a
/// remontée en dernier. Ni itinéraire, ni heure d'arrivée estimée — celle-ci
/// demande un moteur de routage qui n'est pas encore auto-hébergé. Attendre ce
/// moteur pour ne rien montrer laisserait le commerçant devant un statut
/// textuel alors que la donnée existe déjà côté serveur.
///
/// **La fraîcheur est affichée avec le point, toujours.** Une position vieille
/// d'une heure présentée comme actuelle est pire qu'aucune position : le
/// commerçant croirait son transporteur immobile alors qu'il a simplement
/// perdu le réseau, et appellerait pour rien. Au-delà de dix minutes, le point
/// est explicitement marqué comme ancien.
class _DriverMap extends StatefulWidget {
  final String orderId;
  final MerchantOrder order;

  const _DriverMap({required this.orderId, required this.order});

  @override
  State<_DriverMap> createState() => _DriverMapState();
}

class _DriverMapState extends State<_DriverMap> {
  DriverPosition? _position;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<MerchantOrderState>();
    final position = await state.loadDriverPosition(widget.orderId);
    if (!mounted) return;
    setState(() {
      _position = position;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 60,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final position = _position;
    if (position == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Text(
          'Position du transporteur non disponible pour le moment.',
          style: TextStyle(fontSize: 12),
        ),
      );
    }

    final driver = LatLng(position.latitude, position.longitude);
    final dropoff = _pointOf(widget.order.dropoff);

    return Column(
      children: [
        SizedBox(
          height: 200,
          child: FlutterMap(
            options: MapOptions(
              initialCenter: driver,
              initialZoom: 14,
              // Carte de consultation : ni sélection ni rotation, seulement
              // déplacement et zoom. Une rotation accidentelle sur une carte
              // qu'on ne fait que regarder désoriente sans rien apporter.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                // Exigé par la politique d'usage des tuiles OSM.
                userAgentPackageName: 'com.echango.echango_delivery',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: driver,
                    width: 40,
                    height: 40,
                    child: Icon(
                      Icons.local_shipping,
                      // Le gris dit « ce point n'est plus frais » sans texte à
                      // lire : c'est la première chose qu'on voit sur une
                      // carte, avant la légende.
                      color: position.isStale ? Colors.grey : Colors.blue.shade800,
                      size: 32,
                    ),
                  ),
                  if (dropoff != null)
                    Marker(
                      point: dropoff,
                      width: 40,
                      height: 40,
                      child: Icon(Icons.flag, color: Colors.red.shade700, size: 28),
                    ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Icon(
                position.isStale ? Icons.history : Icons.my_location,
                size: 14,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  position.freshness == null
                      ? 'Dernière position connue, date inconnue'
                      : 'Position relevée ${position.freshness}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: _load,
                child: const Text('Actualiser'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Coordonnées d'un lieu, quand il en porte.
  ///
  /// `Place.latitude`/`longitude` sont nullables depuis la fusion des
  /// désérialiseurs : une valeur manquante valait auparavant `0`, soit un point
  /// au large du golfe de Guinée. Mieux vaut ne pas poser de repère que d'en
  /// poser un faux.
  static LatLng? _pointOf(dynamic place) {
    final lat = place?.latitude;
    final lon = place?.longitude;
    if (lat is! double || lon is! double) return null;
    return LatLng(lat, lon);
  }
}

/// Historique des signalements d'échec, vu du commerçant.
///
/// Toute la série, du plus récent au plus ancien : une livraison tentée trois
/// fois n'est pas celle tentée une fois, et chaque tentative porte sa propre
/// photo. N'en montrer qu'une effacerait les précédentes.
class _FailureHistory extends StatelessWidget {
  final List<DeliveryFailure> failures;

  const _FailureHistory({required this.failures});

  /// Libellés lisibles. Les codes du serveur (`client_absent`) ne se lisent
  /// pas : ils sont faits pour être comptés, pas affichés.
  static const _labels = {
    'client_absent': 'Client absent',
    'adresse_introuvable': 'Adresse introuvable',
    'colis_refuse': 'Colis refusé par le client',
    'colis_endommage': 'Colis endommagé ou manquant',
    'acces_impossible': 'Accès impossible',
    'autre': 'Autre motif',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final multiple = failures.length > 1;

    return Card(
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
                Expanded(
                  child: Text(
                    multiple
                        ? '${failures.length} tentatives de livraison ont échoué'
                        : 'La livraison n\'a pas pu être effectuée',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: Colors.red.shade700),
                  ),
                ),
              ],
            ),
            for (var i = 0; i < failures.length; i++) ...[
              const SizedBox(height: 12),
              if (multiple)
                Text(
                  'Tentative ${failures.length - i}',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: Colors.red.shade700),
                ),
              Text(_labels[failures[i].reason] ?? failures[i].reason,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (failures[i].notes != null) Text(failures[i].notes!),
              if (failures[i].photoUrl != null) ...[
                const SizedBox(height: 8),
                ProofImage(url: failures[i].photoUrl!),
              ],
            ],
            const SizedBox(height: 12),
            Text(
              'Contactez Echango pour convenir d\'une nouvelle tentative.',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.red.shade700),
            ),
          ],
        ),
      ),
    );
  }
}
