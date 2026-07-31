import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/cash.dart';
import '../../models/merchant_order.dart';
import '../../models/order.dart' show DeliveryFailure, Place;
import '../../models/vehicle_type.dart';
import '../../services/navigation_launcher.dart';
import '../../state/merchant_order_state.dart';
import '../../widgets/proof_image.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/section_card.dart';

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

    final success = await orderState.cancelOrder(widget.orderId);
    if (!mounted) return;

    showAppOutcome(
      context,
      success ? null : orderState.errorMessage ?? 'Annulation impossible',
      'Livraison annulée',
    );
  }

  /// Publie un brouillon : déclenche le dispatch (favori ou pool commun).
  ///
  /// Le geste qui manque depuis la création — sans lui, un brouillon reste
  /// invisible de tout transporteur indéfiniment, ce qui est précisément le
  /// but tant qu'il n'a pas été relu.
  Future<void> _publish(MerchantOrderState orderState) async {
    final success = await orderState.publishOrder(widget.orderId);
    if (!mounted) return;

    showAppOutcome(
      context,
      success ? null : orderState.errorMessage ?? 'Publication impossible',
      'Livraison publiée : Echango recherche un transporteur.',
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

    final template = await orderState.loadOrderTemplate(widget.orderId);
    if (!mounted) return;

    if (template == null) {
      showAppError(
        context,
        orderState.errorMessage ??
            'Reprise impossible — le formulaire s\'ouvre vide.',
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

            final scheme = Theme.of(context).colorScheme;

            return SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppSectionCard(
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
                                const SizedBox(width: AppSpacing.sm),
                                // Le libellé, pas le code Fleetbase brut :
                                // cet écran affichait « created » quand la
                                // liste affichait « En attente », pour la
                                // même commande.
                                Text(order.statusLabel),
                              ],
                            ),
                            if (order.trackingNumber != null) ...[
                              const SizedBox(height: AppSpacing.sm),
                              Text('Numéro de suivi : ${order.trackingNumber}'),
                            ],
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              'Créée le ${order.createdAt.toLocal().toString().split('.')[0]}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    // Le commerçant a surtout besoin de savoir « où ça en
                    // est » : l'exprimer en clair plutôt qu'en code de statut.
                    //
                    // Un brouillon n'est PAS « en attente d'attribution » —
                    // personne ne cherche encore de transporteur, et dire le
                    // contraire ferait croire à une recherche en cours là où
                    // rien n'a démarré.
                    if (order.isDraft)
                      _banner(
                        scheme.secondaryContainer,
                        Icons.edit_note,
                        'Brouillon : aucun transporteur n\'est sollicité tant '
                        'que vous ne publiez pas cette livraison.',
                      )
                    // ⚠️ `isWaitingDispatch` ne suffit pas. Le statut Fleetbase
                    // reste `dispatched` **après** l'affectation d'un
                    // transporteur — il ne bouge qu'au démarrage de la course.
                    // L'écran affichait donc « Echango recherche un
                    // transporteur » juste au-dessus de « Pris en charge par
                    // Driver Alice1 », deux affirmations contradictoires dont
                    // la première est fausse.
                    //
                    // Rien n'est dérivé ni mémorisé ici : deux champs servis
                    // par Fleetbase, lus ensemble pour choisir une phrase.
                    else if (order.isWaitingDispatch && order.driverName == null)
                      _banner(
                        context.semantic.warningContainer,
                        Icons.hourglass_empty,
                        'En attente d\'attribution. Echango recherche un '
                        'transporteur disponible.',
                      )
                    else if (order.isWaitingDispatch)
                      _banner(
                        scheme.primaryContainer,
                        Icons.assignment_turned_in_outlined,
                        'Transporteur affecté. La course démarrera à '
                        'l\'enlèvement.',
                      ),
                    if (order.driverName != null) _driverCard(order),
                    if (order.isCompleted)
                      _banner(context.semantic.successContainer,
                          Icons.check_circle_outline, 'Livraison effectuée.'),
                    if (order.isCancelled)
                      _banner(scheme.outlineVariant, Icons.cancel_outlined,
                          'Livraison annulée.'),
                    const SizedBox(height: AppSpacing.md),
                    _placeCard('Retrait', order.pickup, order.pickupNotes),
                    const SizedBox(height: AppSpacing.md),
                    _placeCard('Livraison', order.dropoff, order.dropoffNotes),
                    // Signalements d'échec : le commerçant devra répondre à son
                    // client, et le justificatif n'allait jusqu'ici qu'à celui
                    // qui l'avait produit.
                    if (order.deliveryFailures.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      _FailureHistory(failures: order.deliveryFailures),
                    ],
                    if (order.isCompleted) ...[
                      const SizedBox(height: AppSpacing.md),
                      _proofCard(),
                    ],
                    if (order.codAmount != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      _cashCard(order),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    _orderOptionsCard(order),
                    if (order.isCompleted && order.driverName != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      _favouriteCard(order),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    // Publier passe avant tout le reste sur un brouillon :
                    // c'est l'unique geste qui manque pour que la livraison
                    // existe réellement aux yeux d'un transporteur.
                    if (order.isDraft) ...[
                      ElevatedButton.icon(
                        onPressed:
                            orderState.isLoading ? null : () => _publish(orderState),
                        icon: const Icon(Icons.publish_outlined),
                        label: const Text('Publier'),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
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
                    const SizedBox(height: AppSpacing.md),
                    if (order.canCancel)
                      OutlinedButton.icon(
                        onPressed:
                            orderState.isLoading ? null : () => _cancel(orderState),
                        icon: const Icon(Icons.close),
                        label: const Text('Annuler la livraison'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: AppSpacing.xxl),
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
        color: Theme.of(context).colorScheme.primaryContainer,
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
  Widget _proofCard() => AppSectionCard(
  child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Preuve de livraison',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              ProofImage(url: '/commercant/commandes/${widget.orderId}/preuve'),
            ],
          ),
);

  /// Paiement à la livraison : ce qui était demandé, et ce qui a été perçu.
  ///
  /// Les deux montants sont affichés séparément dès qu'ils diffèrent. Ne
  /// montrer que le premier ferait passer une livraison à moitié payée pour une
  /// livraison réglée — et c'est précisément l'écart que le registre existe
  /// pour rendre visible.
  Widget _cashCard(MerchantOrder order) {
    final collection = order.cashCollection;
    final currency = order.codCurrency ?? collection?.currency ?? '';
    final theme = Theme.of(context);

    // ── Ce qui revient réellement au commerçant ────────────────────────────
    //
    // L'écran donnait les deux nombres — « à encaisser 1200 », « rémunération
    // 550 » — et laissait la soustraction au commerçant, au moment précis où
    // il compte sa caisse. C'est pourtant le seul chiffre qui l'intéresse là.
    //
    // La formule est la même que les frais de livraison soient inclus ou non
    // dans le montant encaissé (règlement net, journal §17) : le transporteur
    // retient sa rémunération sur ce qu'il a perçu et remet la différence.
    // `cod_includes_delivery` ne change donc pas ce calcul — il ne sert qu'à
    // dire au commerçant ce que le destinataire croit payer.
    //
    // Calculé sur le montant **réellement perçu** dès qu'il est connu, et non
    // sur celui qui était demandé : sur un écart constaté à la porte,
    // annoncer la somme demandée promettrait de l'argent qui ne viendra pas.
    // Le montant et sa devise, en une seule forme. `currency` peut être vide
    // (commande d'avant que la devise soit projetée) : concaténer sans couper
    // laisserait « 650 » suivi d'une espace, visible entre parenthèses.
    String money(num amount) => '${amount.toStringAsFixed(0)} $currency'.trim();

    final price = order.price;
    final settlement = <Widget>[];

    if (price != null) {
      final base = collection?.collectedAmount ?? order.codAmount!;
      final net = base - price;
      // Le futur tant que rien n'est encaissé : c'est une projection, pas un
      // solde. Les annoncer du même ton ferait compter sur une somme
      // qu'aucun transporteur n'a encore perçue.
      final tense = collection == null ? 'Vous reviendra' : 'Vous revient';

      settlement.addAll([
        const Divider(height: 20),
        Text(
          net >= 0
              ? '$tense : ${money(net)}'
              // Cas réel et non théorique : la retenue du transporteur est
              // plafonnée à ce qu'il a perçu, donc une course chère payée en
              // partie laisse le commerçant débiteur. Le taire afficherait 0
              // là où il doit de l'argent.
              : 'Vous devrez au transporteur : ${money(-net)}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Le transporteur retient sa rémunération (${money(price)}) sur ce '
          'qu\'il encaisse et vous remet la différence.',
          style: theme.textTheme.bodySmall,
        ),
      ]);
    }

    return AppSectionCard(
  // Même rôle des deux côtés : l'écart se signale par son libellé,
  pas par
      // une nuance d'orange que personne ne sait nommer.
      color: context.semantic.warningContainer,
  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_balance_wallet_outlined, size: 20),
                const SizedBox(width: AppSpacing.sm),
                Text('Paiement à la livraison', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Montant demandé : '
                '${order.codAmount!.toStringAsFixed(0)} $currency'.trim()),
            if (collection == null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Pas encore encaissé.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Perçu : ${collection.collectedAmount.toStringAsFixed(0)} $currency'
                    .trim(),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (collection.hasDiscrepancy) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  cashDiscrepancyLabels[collection.discrepancyReason] ??
                      collection.discrepancyReason ??
                      'Écart signalé',
                  style: TextStyle(color: context.semantic.onWarningContainer),
                ),
                if (collection.notes != null) Text(collection.notes!),
              ],
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Cette somme est détenue par le transporteur jusqu\'à sa remise. '
                'Suivez-la dans « Encaissements ».',
                style: theme.textTheme.bodySmall,
              ),
            ],
            ...settlement,
          ],
        ),
);
  }

  Widget _banner(Color color, IconData icon, String text) => Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: AppSpacing.md),
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
          switch (order.podMethod!) {
            'photo' => 'Photo à la livraison',
            'aucune' => 'Aucune preuve demandée',
            final other => other,
          },
        ),
      // Le montant à encaisser figure ici en plus de la carte d'encaissement :
      // celle-ci ne parle que de ce qui a été RÉELLEMENT perçu, et n'apparaît
      // qu'après la livraison. Le commerçant doit pouvoir relire ce qu'il a
      // demandé, avant.
      // ⚠️ Le suffixe ne décrit plus la composition du montant — la livraison
      // est réclamée à la porte dans les deux cas —, mais **qui la paie**.
      // « (marchandise seule) » sur un montant qui contient la livraison
      // aurait été un contresens : le commerçant aurait lu 1950 en croyant
      // que son client ne paie que la marchandise.
      if (order.codAmount != null)
        (
          Icons.account_balance_wallet_outlined,
          'À encaisser',
          '${order.codAmount!.toStringAsFixed(0)} ${order.codCurrency ?? ''}'.trim() +
              (order.codIncludesDelivery
                  ? ' (livraison à votre charge)'
                  : ' (livraison payée par le client)'),
        ),
      // Une ligne par article : le poids et la mention fragile étaient saisis
      // puis invisibles, alors que ce sont eux qui fondent un refus pour
      // « colis inadapté ».
      for (final item in order.items)
        (Icons.inventory_2_outlined, 'Colis', item.label),
      // Repli pour les commandes d'avant la projection détaillée des articles.
      if (order.items.isEmpty && order.packageContents != null)
        (Icons.inventory_2_outlined, 'Colis', order.packageContents!),
      if (order.preferFavourites != null)
        (
          order.preferFavourites! ? Icons.star_outline : Icons.public,
          'Diffusion',
          order.preferFavourites!
              ? 'Mes transporteurs habituels en priorité'
              : 'Tout le réseau',
        ),
      if (order.instructions != null)
        (Icons.notes_outlined, 'Instructions', order.instructions!),
    ];

    return AppSectionCard(
  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Votre demande',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.md),
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

  /// Carte d'un point de la livraison, avec **tout** ce qui a été saisi.
  ///
  /// ⚠️ La version précédente ne prenait que le nom et l'adresse : le contact
  /// et son téléphone, pourtant saisis au formulaire et bien renvoyés par le
  /// serveur (`Place.contactName`/`contactPhone`), n'étaient affichés nulle
  /// part. Le commerçant ne pouvait donc pas relire le numéro qu'il avait
  /// donné au transporteur — ni le corriger s'il s'était trompé.
  ///
  /// [notes] est la précision d'adresse tapée à la création : elle vit dans
  /// `meta.pickup_notes`/`dropoff_notes`, pas sur le `Place`, et se perdait
  /// pour la même raison.
  Widget _placeCard(String title, Place? place, String? notes) {
    final theme = Theme.of(context);
    final contact = place?.contactName;
    final phone = place?.contactPhone;

    return AppSectionCard(
  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            Text(place?.name ?? '—',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            if (place?.address != null && place!.address.isNotEmpty)
              Text(place.address),
            if (notes != null && notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(notes, style: theme.textTheme.bodySmall),
              ),
            if (contact != null && contact.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  const Icon(Icons.person_outline, size: 16),
                  const SizedBox(width: 6),
                  Expanded(child: Text(contact)),
                ],
              ),
            ],
            if (phone != null && phone.isNotEmpty)
              Row(
                children: [
                  const Icon(Icons.phone_outlined, size: 16),
                  const SizedBox(width: 6),
                  Expanded(child: Text(phone)),
                  // Appeler depuis la fiche : c'est le geste attendu quand une
                  // livraison pose question, et le numéro était déjà là.
                  IconButton(
                    icon: const Icon(Icons.call, size: 18),
                    tooltip: 'Appeler',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => NavigationLauncher.call(phone),
                  ),
                ],
              ),
          ],
        ),
);
  }
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
  bool _loading = false;

  /// `false` tant que le commerçant n'a pas demandé la position.
  ///
  /// Charger la position — et donc dessiner la carte, qui télécharge des
  /// tuiles OpenStreetMap — dès l'ouverture de la fiche sollicitait le
  /// serveur et le réseau du commerçant pour un écran qu'il ne regarde pas
  /// forcément. La demande explicite (décision produit, 30/07/2026) rend ce
  /// coût proportionné à l'usage réel.
  bool _requested = false;

  Future<void> _load() async {
    setState(() {
      _requested = true;
      _loading = true;
    });
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
    if (!_requested) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
        child: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.map_outlined),
          label: const Text('Voir la position du transporteur'),
        ),
      );
    }

    if (_loading) {
      return const SizedBox(
        height: 60,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final position = _position;
    if (position == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
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
                      color: position.isStale
                          ? Theme.of(context).colorScheme.outline
                          : Theme.of(context).colorScheme.primary,
                      size: 32,
                    ),
                  ),
                  if (dropoff != null)
                    Marker(
                      point: dropoff,
                      width: 40,
                      height: 40,
                      child: Icon(Icons.flag,
                          color: Theme.of(context).colorScheme.error, size: 28),
                    ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
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

    return AppSectionCard(
  color: theme.colorScheme.errorContainer,
  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline,
                    color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    multiple
                        ? '${failures.length} tentatives de livraison ont échoué'
                        : 'La livraison n\'a pas pu être effectuée',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            for (var i = 0; i < failures.length; i++) ...[
              const SizedBox(height: AppSpacing.md),
              if (multiple)
                Text(
                  'Tentative ${failures.length - i}',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
              Text(_labels[failures[i].reason] ?? failures[i].reason,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (failures[i].notes != null) Text(failures[i].notes!),
              if (failures[i].photoUrl != null) ...[
                const SizedBox(height: AppSpacing.sm),
                ProofImage(url: failures[i].photoUrl!),
              ],
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              'Contactez Echango pour convenir d\'une nouvelle tentative.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ],
        ),
);
  }
}
