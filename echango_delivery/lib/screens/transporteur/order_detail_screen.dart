import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/cash.dart';
import '../../models/order.dart';
import '../../services/navigation_launcher.dart';
import '../../services/photo_service.dart';
import '../../state/order_state.dart';
import '../../widgets/photo_field.dart';
import '../../widgets/proof_image.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/dates.dart';
import 'status_colors.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/section_card.dart';

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
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Order Header
                  AppSectionCard(
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
                              const SizedBox(width: AppSpacing.sm),
                              Chip(
                                label: Text(order.status),
                                backgroundColor:
                                    driverStatusColor(context, order.status),
                                // Le texte suit le fond : un blanc unique sur
                                // cinq teintes laissait le contraste au hasard.
                                labelStyle: TextStyle(
                                  color: onDriverStatusColor(
                                      context, order.status),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          if (order.formattedPrice != null) ...[
                            const SizedBox(height: AppSpacing.md),
                            Row(
                              children: [
                                Icon(Icons.payments_outlined,
                                    color: context.semantic.success),
                                const SizedBox(width: AppSpacing.sm),
                                Text(
                                  order.formattedPrice!,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(color: context.semantic.success),
                                ),
                              ],
                            ),
                          ],
                          // Le montant à encaisser, séparé et nommé. Le
                          // confondre avec la rémunération serait la pire
                          // erreur possible sur cet écran : l'un est ce que le
                          // transporteur gagne, l'autre ce qu'il transporte
                          // pour le compte du commerçant.
                          if (order.codAmount != null) ...[
                            const SizedBox(height: AppSpacing.md),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(AppSpacing.md),
                              decoration: BoxDecoration(
                                color: context.semantic.warningContainer,
                                borderRadius: BorderRadius.circular(AppRadius.md),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.account_balance_wallet_outlined),
                                      const SizedBox(width: AppSpacing.sm),
                                      Text(
                                        'À encaisser : '
                                        '${order.codAmount!.toStringAsFixed(0)} '
                                        '${order.codCurrency ?? ''}'.trim(),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  const Text(
                                    'Somme due par le destinataire au commerçant. '
                                    'Vous la conservez et la lui remettez au '
                                    'prochain enlèvement.',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: AppSpacing.lg),
                          // ⚠️ `toString()` sans `toLocal()` affichait l'UTC :
                          // « Créée le » était une heure trop tôt, juste
                          // au-dessus d'une date d'échec que le même écran
                          // localisait. `formatFull` porte le `toLocal()`.
                          _buildInfoRow('Créée le :', formatFull(order.createdAt)),
                          _buildInfoRow('Mise à jour :', formatFull(order.updatedAt)),
                        ],
                      ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  // Locations
                  AppSectionCard(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // L'enlèvement est un commerce : rien n'y est
                          // masqué, hors son téléphone.
                          _PlaceBlock(
                            label: 'Enlèvement',
                            place: order.pickupPlace,
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          _PlaceBlock(
                            label: 'Livraison',
                            place: order.dropoffPlace,
                            obscured: order.redacted,
                          ),
                        ],
                      ),
                  ),
                  // Dire pourquoi les contacts manquent. Sans ce message, une
                  // fiche expurgée se lit comme une commande mal saisie, et le
                  // transporteur cherche un numéro qui ne viendra qu'après
                  // acceptation.
                  if (order.redacted) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Card(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      child: const ListTile(
                        leading: Icon(Icons.lock_outline),
                        title: Text('Course non réclamée'),
                        // ⚠️ Réécrit le 31/07/2026 avec la règle qu'il décrit.
                        // Il annonçait une adresse réduite à la commune, alors
                        // que l'adresse complète est servie : le transporteur
                        // cherchait une information déjà sous ses yeux. Un
                        // libellé qui décrit l'ancienne règle est pire que pas
                        // de libellé du tout.
                        subtitle: Text(
                          'Le nom et le téléphone du destinataire apparaissent '
                          'dès que vous acceptez. Tout le reste est affiché.',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  // Tous les signalements, du plus récent au plus ancien.
                  // N'en montrer qu'un effaçait l'historique des tentatives —
                  // et avec lui les photos des précédentes.
                  if (order.deliveryFailures.isNotEmpty) ...[
                    _FailureHistory(failures: order.deliveryFailures),
                    const SizedBox(height: AppSpacing.lg),
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

      buttons.add(const SizedBox(height: AppSpacing.md));
      buttons.add(
        ElevatedButton(
          onPressed: busy
              ? null
              : () => requiresPod
                  ? _applyActivityWithProof(context, order, activity, orderState)
                  : _applyActivity(context, order, activity, orderState),
          style: ElevatedButton.styleFrom(
            backgroundColor: code == 'completed'
                ? context.semantic.success
                : context.semantic.warning,
          ),
          child: Text(requiresPod ? '$label (preuve requise)' : label),
        ),
      );
    }

    // Refus. Deux situations, un seul geste :
    //
    // — une opportunité diffusée qu'on écarte : elle quitte la liste, et rien
    //   d'autre ne se passe ;
    // — une course assignée (favori sollicité) qu'on rend : elle repart au
    //   réseau et le commerçant est prévenu.
    //
    // Rendre n'est plus possible une fois la course démarrée : à ce stade le
    // transporteur est engagé, et la sortie est le signalement d'échec, qui
    // laisse une trace. Le libellé change donc avec l'enjeu, plutôt que de
    // présenter deux actions différentes sous un même mot.
    final returnable = !order.isFinished && !claimable && order.isPending;
    if (claimable || returnable) {
      buttons.add(const SizedBox(height: AppSpacing.md));
      buttons.add(
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => _declineOrder(context, order.id, orderState,
                  assigned: returnable),
          icon: const Icon(Icons.do_not_disturb_on_outlined),
          label: Text(claimable ? 'Refuser cette course' : 'Rendre cette course'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
      );
    }

    // Signalement d'échec : pertinent tant que la commande n'est pas close.
    if (!order.isFinished && !claimable) {
      buttons.add(const SizedBox(height: AppSpacing.md));
      buttons.add(
        ElevatedButton(
          onPressed: busy
              ? null
              : () => context.push('/transporteur/commandes/${order.id}/echec'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
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
    dynamic order,
    Map<String, dynamic> activity,
    OrderState orderState,
  ) async {
    final orderId = order.id as String;
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
      showAppError(
        context,
        orderState.errorMessage ?? 'Envoi de la preuve impossible',
      );
      return;
    }

    await _applyActivity(context, order, activity, orderState);
  }

  /// Applique une transition serveur.
  ///
  /// Sur la transition **terminale** d'une course payée à la réception, le
  /// montant encaissé est demandé d'abord : le serveur refuse la clôture sans
  /// lui, et « livré » et « perçu X » sont un seul fait. Interroger après
  /// coup, dans un écran séparé, garantirait l'oubli un jour de pluie.
  Future<void> _applyActivity(
    BuildContext context,
    dynamic order,
    Map<String, dynamic> activity,
    OrderState orderState,
  ) async {
    final orderId = order.id as String;
    final code = (activity['code'] ?? activity['status'] ?? '') as String;
    final needsCash = code == 'completed' && order.codAmount != null;

    _CashDeclaration? cash;
    if (needsCash) {
      cash = await showModalBottomSheet<_CashDeclaration>(
        context: context,
        isScrollControlled: true,
        // Non annulable d'un geste : la livraison est faite, l'argent a changé
        // de mains. Fermer par inadvertance laisserait la course ouverte sans
        // que le transporteur comprenne pourquoi.
        isDismissible: false,
        enableDrag: false,
        builder: (_) => _CashSheet(
          expected: (order.codAmount as num).toDouble(),
          currency: (order.codCurrency ?? '') as String,
        ),
      );

      // L'utilisateur a fait « retour » : on n'applique rien. Mieux vaut une
      // course encore ouverte, qu'il peut reprendre, qu'une course close dont
      // l'argent n'est comptabilisé nulle part.
      if (cash == null || !context.mounted) return;
    }

    final success = await orderState.applyActivity(
      orderId,
      activity,
      collectedAmount: cash?.amount,
      discrepancyReason: cash?.reason,
      cashNotes: cash?.notes,
    );
    if (!context.mounted) return;

    if (success) {
      final label = (activity['_resolved_status'] ?? activity['code'] ?? '') as String;
      showAppSnackBar(context, 'Étape appliquée : $label');
    } else {
      showAppError(context, orderState.errorMessage ?? 'Échec de la mise à jour');
    }
  }

  /// Demande le motif, puis refuse.
  ///
  /// Le motif n'est pas décoratif : c'est la seule donnée qui dise pourquoi le
  /// réseau ne prend pas une course. `PricingService` enregistre ce qu'elle
  /// valait, le refus dit ce que le marché en pense — et l'appariement des deux
  /// est ce qui permettra d'écrire un barème sur des courses réelles plutôt
  /// que sur une estimation de bureau. D'où la liste fermée : un champ libre
  /// ne se compte pas.
  Future<void> _declineOrder(
    BuildContext context,
    String orderId,
    OrderState orderState, {
    required bool assigned,
  }) async {
    final choice = await showModalBottomSheet<({String reason, String? notes})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DeclineSheet(assigned: assigned),
    );

    if (choice == null || !context.mounted) return;

    final success = await orderState.declineOrder(
      orderId: orderId,
      reason: choice.reason,
      notes: choice.notes,
    );
    if (!context.mounted) return;

    if (!success) {
      showAppError(context, orderState.errorMessage ?? 'Refus impossible');
      return;
    }

    showAppSnackBar(
      context,
      orderState.lastDeclineReleasedToPool == true
          ? 'Course rendue au réseau. Le commerçant en a été informé.'
          : 'Course écartée. Elle ne vous sera plus proposée.',
    );

    // Retour à la liste : la fiche d'une course qu'on vient d'écarter n'a plus
    // de contenu, et la relire renverrait un 404 dès qu'elle a quitté le
    // périmètre de ce transporteur.
    if (context.mounted && context.canPop()) context.pop();
  }

  Future<void> _acceptOrder(
    BuildContext context,
    String orderId,
    OrderState orderState,
  ) async {
    final success = await orderState.acceptOrder(orderId);
    if (success) {
      if (!context.mounted) return;
      showAppSnackBar(context, 'Course acceptée');
    }
  }

}

/// Feuille de refus : motif obligatoire, précision facultative.
///
/// Les libellés sont écrits du point de vue du transporteur, pas de la base de
/// données : « Le prix ne couvre pas le trajet » se choisit sans réfléchir,
/// `prix_insuffisant` demande une traduction mentale. Le code part au serveur,
/// la phrase reste à l'écran.
class _DeclineSheet extends StatefulWidget {
  /// La course est-elle assignée à ce transporteur ? Le texte d'avertissement
  /// en dépend : rendre une course engage le commerçant, écarter une
  /// proposition n'engage personne.
  final bool assigned;

  const _DeclineSheet({required this.assigned});

  @override
  State<_DeclineSheet> createState() => _DeclineSheetState();
}

class _DeclineSheetState extends State<_DeclineSheet> {
  static const _reasons = <(String, String, IconData)>[
    ('prix_insuffisant', 'Le prix ne couvre pas le trajet', Icons.payments_outlined),
    ('trop_loin', 'Trop loin de ma position', Icons.route_outlined),
    ('vehicule_inadapte', 'Mon véhicule n\'est pas adapté', Icons.two_wheeler_outlined),
    ('creneau_impossible', 'Je ne suis pas libre à cet horaire', Icons.schedule_outlined),
    ('colis_inadapte', 'Le colis ne me convient pas', Icons.inventory_2_outlined),
    ('indisponible', 'Je ne suis pas disponible', Icons.do_not_disturb_on_outlined),
    ('autre', 'Autre raison', Icons.more_horiz),
  ];

  String? _reason;
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.assigned ? 'Rendre cette course' : 'Refuser cette course',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.assigned
                  ? 'Elle sera proposée aux autres transporteurs du réseau, et '
                      'le commerçant en sera informé.'
                  : 'Elle ne vous sera plus proposée. Les autres transporteurs '
                      'la voient toujours.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            // Des ListTile sélectionnables plutôt que des RadioListTile : le
            // couple `groupValue`/`onChanged` est déprécié depuis Flutter 3.32
            // au profit de RadioGroup, et cet écran doit compiler sans
            // avertissement sur la version de l'utilisateur, que je ne peux
            // pas éprouver ici. Un tri visuel par coche rend d'ailleurs la
            // sélection plus lisible sur un téléphone tenu d'une main.
            for (final (code, label, icon) in _reasons)
              ListTile(
                onTap: () => setState(() => _reason = code),
                leading: Icon(icon),
                title: Text(label),
                trailing: _reason == code
                    ? Icon(Icons.check_circle,
                        color: Theme.of(context).colorScheme.error)
                    : null,
                selected: _reason == code,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _notes,
              maxLines: 2,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Précision (facultatif)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            ElevatedButton(
              onPressed: _reason == null
                  ? null
                  : () => Navigator.pop(
                        context,
                        (
                          reason: _reason!,
                          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
                        ),
                      ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(widget.assigned ? 'Rendre la course' : 'Refuser'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler'),
            ),
          ],
        ),
      ),
    );
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
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.xl,
        // Sans ça, le clavier ou la barre système recouvre le bouton de
        // validation sur les petits écrans.
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
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
          const SizedBox(height: AppSpacing.xl),
          ElevatedButton(
            onPressed: _photo == null
                ? null
                : () => Navigator.pop(context, _photo),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
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

  /// Course pas encore réclamée : le serveur a retiré le nom et le téléphone
  /// du destinataire, et rien d'autre.
  final bool obscured;

  const _PlaceBlock({
    required this.label,
    required this.place,
    this.obscured = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (place == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text('Adresse non renseignée', style: theme.textTheme.bodySmall),
        ],
      );
    }

    final p = place!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        // ⚠️ `name` est **absent** sur une course non réclamée (c'est celui du
        // destinataire), donc `Place.fromJson` rend une chaîne vide : le bloc
        // commençait par une ligne vide en gras.
        if (p.name.isNotEmpty)
          Text(
            p.name,
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        if (p.address.isNotEmpty)
          Text(p.address)
        else if (obscured)
          // Ni le nom ni l'adresse : le lieu n'a aucune composante structurée,
          // ce qui est le cas courant des commandes saisies sans passer par la
          // carte. L'adresse réelle est dans les précisions ci-dessous, et la
          // porte dans l'itinéraire.
          Text('Adresse dans les précisions', style: theme.textTheme.bodySmall),
        if (p.contactName != null) Text('Contact : ${p.contactName}'),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 8,
          children: [
            // ⚠️ L'itinéraire est désormais offert **aussi** sur une course non
            // réclamée : depuis le 31/07/2026 le serveur transmet la position
            // (seule l'identité est retirée), et c'est le détour qui décide si
            // la course vaut le déplacement. La garde porte donc sur la donnée
            // réellement nécessaire — des coordonnées — et non sur un état.
            //
            // Sans ça, une entreprise obtenait « Ouvrir dans une carte » sur une
            // opportunité et un indépendant regardant la MÊME course ne
            // l'obtenait pas.
            if (p.latitude != null && p.longitude != null)
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
    showAppError(
      context,
      'Aucune application de navigation trouvée sur cet appareil.',
    );
  }

  Future<void> _call(BuildContext context, String phone) async {
    final ok = await NavigationLauncher.call(phone);
    if (!context.mounted || ok) return;
    showAppError(context, 'Impossible de lancer l\'appel.');
  }
}

/// Photo jointe à un signalement d'échec.
///
/// Chargée via le client HTTP et non par `Image.network` : la route est
/// protégée par le JWT, que le widget ne porterait pas. Le BFF sert lui-même
/// le fichier, l'app n'atteint jamais Fleetbase directement — l'URL de
/// stockage pointe sur un hôte inaccessible depuis un téléphone, et surtout
/// elle n'est protégée par aucune authentification.

/// Ligne « libellé : valeur ».
///
/// Hissée hors de l'écran : l'historique des signalements en a besoin, et une
/// méthode privée de widget n'est pas atteignable depuis un autre widget.
Widget _buildInfoRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
                        ? '${failures.length} échecs de livraison signalés'
                        : 'Échec de livraison signalé',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            for (var i = 0; i < failures.length; i++) ...[
              const SizedBox(height: AppSpacing.md),
              if (multiple) ...[
                const Divider(height: 1),
                const SizedBox(height: AppSpacing.md),
                Text(
                  // Numérotation à rebours : le plus récent porte le numéro le
                  // plus élevé, ce qui rend l'ordre chronologique lisible sans
                  // avoir à comparer les dates.
                  'Tentative ${failures.length - i} — ${formatDayTime(failures[i].createdAt)}',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              _FailureEntry(failure: failures[i]),
            ],
            const SizedBox(height: AppSpacing.md),
            // Le statut Fleetbase reste inchangé par un signalement (§6.5) :
            // le dire, sinon l'écart entre « échec signalé » et « statut
            // enroute » passe pour une incohérence.
            Text(
              'La commande conserve son statut : le signalement est transmis '
              'à l\'opérateur, qui décide de la suite.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ],
        ),
    );
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
          const SizedBox(height: AppSpacing.sm),
          ProofImage(url: failure.photoUrl!),
        ],
      ],
    );
  }
}

/// Ce que le transporteur déclare avoir perçu.
class _CashDeclaration {
  final double amount;
  final String? reason;
  final String? notes;

  const _CashDeclaration({required this.amount, this.reason, this.notes});
}

/// Feuille de déclaration d'encaissement, présentée juste avant la clôture.
///
/// ── Pourquoi le montant est pré-rempli, et modifiable ───────────────────────
///
/// Le cas de très loin le plus fréquent est « le client a payé la somme
/// exacte » : le pré-remplir supprime une saisie sur un téléphone tenu d'une
/// main devant une porte, et c'est là que se produisent les fautes de frappe.
/// Mais il reste modifiable, parce que l'écart est justement ce que le registre
/// existe pour capter — le masquer derrière un second écran reviendrait à
/// pousser le transporteur à valider le montant théorique.
///
/// Le motif devient obligatoire dès que le montant change, et l'écran le dit
/// avant que le bouton se désactive plutôt qu'après.
class _CashSheet extends StatefulWidget {
  final double expected;
  final String currency;

  const _CashSheet({required this.expected, required this.currency});

  @override
  State<_CashSheet> createState() => _CashSheetState();
}

class _CashSheetState extends State<_CashSheet> {
  late final TextEditingController _amount =
      TextEditingController(text: widget.expected.toStringAsFixed(0));
  final _notes = TextEditingController();
  String? _reason;

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  double? get _value {
    final parsed = double.tryParse(_amount.text.trim());
    if (parsed == null || parsed < 0 || parsed > widget.expected) return null;
    return parsed;
  }

  bool get _differs => _value != null && _value != widget.expected;
  bool get _canSubmit => _value != null && (!_differs || _reason != null);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Encaissement', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Montant attendu : ${widget.expected.toStringAsFixed(0)} '
              '${widget.currency}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Montant réellement perçu',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.account_balance_wallet_outlined),
                suffixText: widget.currency,
              ),
            ),
            if (_differs) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('Pourquoi l\'écart ?', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              for (final entry in cashDiscrepancyLabels.entries)
                ListTile(
                  onTap: () => setState(() => _reason = entry.key),
                  title: Text(entry.value),
                  trailing: _reason == entry.key
                      ? Icon(Icons.check_circle,
                          color: context.semantic.warning)
                      : null,
                  selected: _reason == entry.key,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              TextField(
                controller: _notes,
                maxLines: 2,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Précision (facultatif)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Text(
              // Rappeler ce qu'implique la validation : la somme devient une
              // dette du transporteur envers le commerçant, et elle le suit
              // jusqu'à la remise.
              'Cette somme sera ajoutée à ce que vous devez remettre au '
              'commerçant. Vous la retrouverez dans « Ma caisse ».',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: _canSubmit
                  ? () => Navigator.pop(
                        context,
                        _CashDeclaration(
                          amount: _value!,
                          reason: _differs ? _reason : null,
                          notes: _notes.text.trim().isEmpty
                              ? null
                              : _notes.text.trim(),
                        ),
                      )
                  : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Valider et clôturer la livraison'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Retour'),
            ),
          ],
        ),
      ),
    );
  }
}
