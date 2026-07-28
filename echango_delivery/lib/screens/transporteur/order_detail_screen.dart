import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/order.dart';
import '../../services/bff_api_client.dart';
import '../../services/navigation_launcher.dart';
import '../../services/photo_service.dart';
import '../../state/order_state.dart';
import '../../widgets/photo_field.dart';

class OrderDetailScreen extends StatelessWidget {
  final String orderId;

  const OrderDetailScreen({super.key, required this.orderId});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          context.read<OrderState>().clearSelection();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Détail de la commande'),
          elevation: 0,
        ),
        body: Consumer<OrderState>(
          builder: (context, orderState, _) {
            final order = orderState.selectedOrder;

            if (orderState.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            if (order == null) {
              return const Center(child: Text('Commande introuvable'));
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Order Header
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Expanded + ellipsis : le titre et la puce se
                          // partagent une largeur fixe, et un public_id long
                          // faisait déborder la Row (5.7 px sur émulateur).
                          // Sans contrainte, chaque enfant prend sa taille
                          // naturelle et la somme peut dépasser l'écran.
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  'Commande ${order.publicId}',
                                  style: Theme.of(context).textTheme.titleLarge,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Chip(
                                label: Text(order.status),
                                backgroundColor: _getStatusColor(order.status),
                                labelStyle: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildInfoRow('Créée le :', order.createdAt.toString().split('.')[0]),
                          _buildInfoRow('Mise à jour :', order.updatedAt.toString().split('.')[0]),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Locations
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _PlaceBlock(
                            label: 'Enlèvement',
                            place: order.pickupPlace,
                          ),
                          const SizedBox(height: 16),
                          _PlaceBlock(
                            label: 'Livraison',
                            place: order.dropoffPlace,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Dire pourquoi les contacts manquent. Sans ce message, une
                  // fiche expurgée se lit comme une commande mal saisie, et le
                  // transporteur cherche un numéro qui ne viendra qu'après
                  // acceptation.
                  if (order.redacted) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      child: const ListTile(
                        leading: Icon(Icons.lock_outline),
                        title: Text('Coordonnées masquées'),
                        subtitle: Text(
                          'Les contacts et l\'adresse précise s\'affichent '
                          'dès que vous acceptez cette course.',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  // Tous les signalements, du plus récent au plus ancien.
                  // N'en montrer qu'un effaçait l'historique des tentatives —
                  // et avec lui les photos des précédentes.
                  if (order.deliveryFailures.isNotEmpty) ...[
                    _FailureHistory(failures: order.deliveryFailures),
                    const SizedBox(height: 16),
                  ],
                  // Action Buttons
                  _buildActionButtons(context, order, orderState),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Construit les actions à partir de ce que le SERVEUR propose, jamais
  /// d'une machine à états codée ici.
  ///
  /// L'ancienne version affichait « Accept / Start / Mark as Delivered » selon
  /// des prédicats locaux. Résultat : accepter une commande adhoc l'assigne ET
  /// la démarre côté Fleetbase (§4.2), mais le bouton « Start Delivery »
  /// restait affiché et rejouait une transition déjà faite — « Failed to start
  /// this order ». Les transitions réelles varient selon l'OrderConfig ; seul
  /// `activites-suivantes` les connaît (journal §6.9).
  Widget _buildActionButtons(
    BuildContext context,
    dynamic order,
    OrderState orderState,
  ) {
    final buttons = <Widget>[];
    final busy = orderState.isLoading;

    // Opportunité adhoc : elle n'a pas encore de transition, il faut d'abord
    // la réclamer. Un seul appel serveur assigne et démarre.
    final claimable = order.adhoc == true && order.driverId == null;
    if (claimable) {
      buttons.add(
        ElevatedButton(
          onPressed: busy ? null : () => _acceptOrder(context, order.id, orderState),
          child: const Text('Accepter cette course'),
        ),
      );
    }

    for (final activity in orderState.nextActivities) {
      final code = (activity['code'] ?? '') as String;
      // `_resolved_status` est le libellé déjà interpolé par le serveur ;
      // `status` peut contenir des gabarits non résolus.
      final label = (activity['_resolved_status'] ??
          activity['status'] ??
          code) as String;
      final requiresPod = activity['require_pod'] == true;

      buttons.add(const SizedBox(height: 12));
      buttons.add(
        ElevatedButton(
          onPressed: busy
              ? null
              : () => requiresPod
                  ? _applyActivityWithProof(context, order.id, activity, orderState)
                  : _applyActivity(context, order.id, activity, orderState),
          style: ElevatedButton.styleFrom(
            backgroundColor: code == 'completed' ? Colors.green : Colors.orange,
          ),
          child: Text(requiresPod ? '$label (preuve requise)' : label),
        ),
      );
    }

    // Signalement d'échec : pertinent tant que la commande n'est pas close.
    if (!order.isFinished && !claimable) {
      buttons.add(const SizedBox(height: 12));
      buttons.add(
        ElevatedButton(
          onPressed: busy
              ? null
              : () => context.push('/transporteur/commandes/${order.id}/echec'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Signaler un échec de livraison'),
        ),
      );
    }

    if (buttons.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: buttons);
  }

  /// Étape marquée `require_pod` : la preuve est capturée puis envoyée avant
  /// d'appliquer la transition.
  ///
  /// L'ordre compte — une preuve attachée après clôture n'aurait plus de
  /// valeur probante. Et l'étape n'est pas appliquée si la preuve échoue :
  /// mieux vaut une commande bloquée à l'étape précédente, que le transporteur
  /// peut reprendre, qu'une commande close sans le justificatif que le serveur
  /// exigeait.
  Future<void> _applyActivityWithProof(
    BuildContext context,
    String orderId,
    Map<String, dynamic> activity,
    OrderState orderState,
  ) async {
    final photo = await showModalBottomSheet<CapturedPhoto>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ProofSheet(),
    );

    // Annulation : ne rien appliquer. Le serveur réclame une preuve, l'envoyer
    // sans elle contournerait sa propre règle.
    if (photo == null || !context.mounted) return;

    final sent = await orderState.captureProof(orderId, photo.base64);
    if (!context.mounted) return;

    if (!sent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(orderState.errorMessage ?? 'Envoi de la preuve impossible'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    await _applyActivity(context, orderId, activity, orderState);
  }

  /// Applique une transition serveur.
  Future<void> _applyActivity(
    BuildContext context,
    String orderId,
    Map<String, dynamic> activity,
    OrderState orderState,
  ) async {
    final success = await orderState.applyActivity(orderId, activity);
    if (!context.mounted) return;

    if (success) {
      final label = (activity['_resolved_status'] ?? activity['code'] ?? '') as String;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Étape appliquée : $label')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(orderState.errorMessage ?? 'Échec de la mise à jour'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _acceptOrder(
    BuildContext context,
    String orderId,
    OrderState orderState,
  ) async {
    final success = await orderState.acceptOrder(orderId);
    if (success) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Course acceptée')),
      );
    }
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

/// Feuille de capture de la preuve de livraison.
///
/// Un passage obligé plutôt qu'un champ facultatif dans l'écran : le serveur
/// signale `require_pod` sur l'étape, et l'étape ne doit pas partir sans.
class _ProofSheet extends StatefulWidget {
  const _ProofSheet();

  @override
  State<_ProofSheet> createState() => _ProofSheetState();
}

class _ProofSheetState extends State<_ProofSheet> {
  CapturedPhoto? _photo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 24,
        // Sans ça, le clavier ou la barre système recouvre le bouton de
        // validation sur les petits écrans.
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PhotoField(
            label: 'Preuve de livraison',
            required: true,
            helperText: 'Cette étape exige une photo : colis remis, '
                'signature, ou dépôt convenu.',
            onChanged: (photo) => setState(() => _photo = photo),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _photo == null
                ? null
                : () => Navigator.pop(context, _photo),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('Envoyer la preuve et valider l\'étape'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
        ],
      ),
    );
  }
}

/// Un point de la course, avec ses actions.
///
/// Enlèvement et livraison avaient le même bloc recopié deux fois, avec des
/// libellés anglais et aucune action. Un transporteur qui lit une adresse doit
/// pouvoir la suivre et appeler sur place — sans ça il ressaisit tout à la
/// main dans une autre application, au volant.
class _PlaceBlock extends StatelessWidget {
  final String label;
  final Place? place;

  const _PlaceBlock({required this.label, required this.place});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (place == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Adresse non renseignée', style: theme.textTheme.bodySmall),
        ],
      );
    }

    final p = place!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          p.name,
          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (p.address.isNotEmpty) Text(p.address),
        if (p.contactName != null) Text('Contact : ${p.contactName}'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => _navigate(context, p),
              icon: const Icon(Icons.directions_outlined),
              label: const Text('Itinéraire'),
            ),
            if (p.contactPhone != null)
              TextButton.icon(
                onPressed: () => _call(context, p.contactPhone!),
                icon: const Icon(Icons.phone_outlined),
                label: Text(p.contactPhone!),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _navigate(BuildContext context, Place p) async {
    final ok = await NavigationLauncher.navigateTo(p);
    if (!context.mounted || ok) return;
    // Un bouton qui ne fait rien est indiscernable d'une application figée.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Aucune application de navigation trouvée sur cet appareil.'),
      ),
    );
  }

  Future<void> _call(BuildContext context, String phone) async {
    final ok = await NavigationLauncher.call(phone);
    if (!context.mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Impossible de lancer l\'appel.')),
    );
  }
}

/// Photo jointe à un signalement d'échec.
///
/// Chargée via le client HTTP et non par `Image.network` : la route est
/// protégée par le JWT, que le widget ne porterait pas. Le BFF sert lui-même
/// le fichier, l'app n'atteint jamais Fleetbase directement — l'URL de
/// stockage pointe sur un hôte inaccessible depuis un téléphone, et surtout
/// elle n'est protégée par aucune authentification.
class _ProofImage extends StatefulWidget {
  final String url;

  const _ProofImage({required this.url});

  @override
  State<_ProofImage> createState() => _ProofImageState();
}

class _ProofImageState extends State<_ProofImage> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(_ProofImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _future = _load();
  }

  // Mémorisé dans l'état, jamais construit dans `build` : un FutureBuilder
  // dont le `future` est recréé à chaque reconstruction relance le
  // téléchargement à chaque fois — et l'écran en contient désormais un par
  // tentative de livraison.
  Future<Uint8List> _load() =>
      context.read<BffApiClient>().fetchImage(widget.url);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError || snapshot.data == null) {
          // Dire que la preuve existe : sans ce message, un échec de
          // chargement se lit comme une photo perdue alors qu'elle est bien
          // enregistrée côté serveur.
          return Container(
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                const Icon(Icons.image_not_supported_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Photo enregistrée, mais son chargement a échoué.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            snapshot.data!,
            height: 180,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }
}

/// Ligne « libellé : valeur ».
///
/// Hissée hors de l'écran : l'historique des signalements en a besoin, et une
/// méthode privée de widget n'est pas atteignable depuis un autre widget.
Widget _buildInfoRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

/// Historique des signalements d'échec d'une commande.
///
/// Une seule carte quand il n'y a qu'un rapport, une série numérotée sinon.
/// Le compte figure dans l'en-tête : c'est l'information qui change la
/// décision de l'opérateur, et elle se perdrait dans une liste qu'il faut
/// dénombrer soi-même.
class _FailureHistory extends StatelessWidget {
  final List<DeliveryFailure> failures;

  const _FailureHistory({required this.failures});

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
                        ? '${failures.length} échecs de livraison signalés'
                        : 'Échec de livraison signalé',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: Colors.red.shade700),
                  ),
                ),
              ],
            ),
            for (var i = 0; i < failures.length; i++) ...[
              const SizedBox(height: 12),
              if (multiple) ...[
                const Divider(height: 1),
                const SizedBox(height: 12),
                Text(
                  // Numérotation à rebours : le plus récent porte le numéro le
                  // plus élevé, ce qui rend l'ordre chronologique lisible sans
                  // avoir à comparer les dates.
                  'Tentative ${failures.length - i} — ${_formatDate(failures[i].createdAt)}',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: Colors.red.shade700),
                ),
                const SizedBox(height: 8),
              ],
              _FailureEntry(failure: failures[i]),
            ],
            const SizedBox(height: 12),
            // Le statut Fleetbase reste inchangé par un signalement (§6.5) :
            // le dire, sinon l'écart entre « échec signalé » et « statut
            // enroute » passe pour une incohérence.
            Text(
              'La commande conserve son statut : le signalement est transmis '
              'à l\'opérateur, qui décide de la suite.',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.red.shade700),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)} à ${two(local.hour)}h${two(local.minute)}';
  }
}

class _FailureEntry extends StatelessWidget {
  final DeliveryFailure failure;

  const _FailureEntry({required this.failure});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildInfoRow('Motif :', failure.reason),
        if (failure.notes != null) _buildInfoRow('Notes :', failure.notes!),
        if (failure.photoUrl != null) ...[
          const SizedBox(height: 8),
          _ProofImage(url: failure.photoUrl!),
        ],
      ],
    );
  }
}
