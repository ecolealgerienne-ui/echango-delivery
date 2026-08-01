import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../i18n/order_strings.dart';
import '../../models/cash.dart';
import '../../state/locale_state.dart';
import '../../models/order.dart';
import '../../services/navigation_launcher.dart';
import '../../services/photo_service.dart';
import '../../state/order_state.dart';
import '../../widgets/photo_field.dart';
import '../../widgets/proof_image.dart';
import '../../theme/app_buttons.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/dates.dart';
import 'status_colors.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/notice.dart';
import '../../widgets/section_card.dart';

class OrderDetailScreen extends StatelessWidget {
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _t(BuildContext context, String key,
          [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

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
          title: Text(_t(context, 'driver.order.title')),
          elevation: 0,
        ),
        body: Consumer<OrderState>(
          builder: (context, orderState, _) {
            final order = orderState.selectedOrder;

            // ⚠️ `order == null` en plus de `isLoading`. `OrderState._isLoading`
            // est levé par **toutes** les écritures — accepter, démarrer,
            // refuser, envoyer la preuve — et pas seulement par la lecture. Sans
            // cette condition, chaque appui sur un bouton effaçait l'écran
            // entier au profit d'un indicateur nu : le transporteur perdait
            // l'adresse et le montant à encaisser qu'il était peut-être en train
            // de lire, ainsi que sa position de défilement, et l'envoi d'une
            // photo — le plus long des quatre — laissait l'écran vide plusieurs
            // secondes. L'attente s'affiche désormais là où l'action a été
            // déclenchée, cf. `_buildActionButtons`.
            if (orderState.isLoading && order == null) {
              return const Center(child: CircularProgressIndicator());
            }

            if (order == null) {
              return Center(child: Text(_t(context, 'driver.order.not_found')));
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
                                  _t(context, 'driver.order.number',
                                      {'id': order.publicId}),
                                  style: Theme.of(context).textTheme.titleLarge,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              // Le fond et l'encre viennent du même appel :
                              // un blanc unique sur cinq teintes laissait le
                              // contraste au hasard, et deux appels séparés
                              // laissaient l'oubli possible.
                              Builder(builder: (context) {
                                final c =
                                    driverStatusColors(context, order.status);
                                return Chip(
                                  label: Text(order.status),
                                  backgroundColor: c.background,
                                  labelStyle: TextStyle(
                                    color: c.foreground,
                                    fontWeight: FontWeight.bold,
                                  ),
                                );
                              }),
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
                                        _t(context, 'driver.order.cod.label', {
                                          'amount':
                                              '${order.codAmount!.toStringAsFixed(0)} '
                                                      '${order.codCurrency ?? ''}'
                                                  .trim(),
                                        }),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    _t(context, 'driver.order.cod.hint'),
                                    style: const TextStyle(fontSize: 12),
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
                          _buildInfoRow(
                              _t(context, 'driver.order.created'),
                              formatFull(order.createdAt,
                                  context.read<LocaleState>().locale)),
                          _buildInfoRow(
                              _t(context, 'driver.order.updated'),
                              formatFull(order.updatedAt,
                                  context.read<LocaleState>().locale)),
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
                            label: _t(context, 'order.schedule.title'),
                            place: order.pickupPlace,
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          _PlaceBlock(
                            label: _t(context, 'order.section.dropoff'),
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
                    AppNotice.info(
                      icon: Icons.lock_outline,
                      title: _t(context, 'driver.order.redacted.title'),
                      // ⚠️ Réécrit le 31/07/2026 avec la règle qu'il décrit.
                      // Il annonçait une adresse réduite à la commune, alors
                      // que l'adresse complète est servie : le transporteur
                      // cherchait une information déjà sous ses yeux. Un
                      // libellé qui décrit l'ancienne règle est pire que pas
                      // de libellé du tout.
                      message: _t(context, 'driver.order.redacted.body'),
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
        FilledButton(
          onPressed: busy ? null : () => _acceptOrder(context, order.id, orderState),
          child: Text(_t(context, 'driver.order.accept')),
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
        FilledButton(
          onPressed: busy
              ? null
              : () => requiresPod
                  ? _applyActivityWithProof(context, order, activity, orderState)
                  : _applyActivity(context, order, activity, orderState),
          style: FilledButton.styleFrom(
            backgroundColor: code == 'completed'
                ? context.semantic.success
                : context.semantic.warning,
          ),
          child: Text(requiresPod
              ? _t(context, 'driver.order.activity.pod', {'label': label})
              : label),
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
          label: Text(claimable ? _t(context, 'driver.order.decline') : _t(context, 'driver.order.release')),
          style: AppButtonStyles.destructiveOutlined(context),
        ),
      );
    }

    // Signalement d'échec : pertinent tant que la commande n'est pas close.
    if (!order.isFinished && !claimable) {
      buttons.add(const SizedBox(height: AppSpacing.md));
      buttons.add(
        FilledButton(
          onPressed: busy
              ? null
              : () => context.push('/transporteur/commandes/${order.id}/echec'),
          style: AppButtonStyles.destructiveFilled(context),
          child: Text(_t(context, 'driver.order.report_failure')),
        ),
      );
    }

    if (buttons.isEmpty) {
      return const SizedBox.shrink();
    }

    // L'attente se montre **ici**, à l'endroit d'où part l'action, et non en
    // effaçant l'écran. Des boutons simplement grisés ne diraient pas si quelque
    // chose est en cours — c'est la règle que porte déjà `AppLoadMore` : pendant
    // le chargement, l'indicateur *remplace* le bouton au lieu de s'y ajouter.
    //
    // ⚠️ **Après** `buttons.isEmpty`, et non avant : une course close n'a aucun
    // bouton, et un indicateur y apparaîtrait à chaque relecture, à l'endroit où
    // il n'y a jamais rien eu. Les `busy ? null :` de chaque bouton deviennent
    // de ce fait redondants ; ils restent, parce qu'un garde qui ne coûte rien
    // vaut mieux qu'un ordre d'instructions qu'il faudrait se rappeler.
    if (busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
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
        orderState.errorMessage ?? _t(context, 'driver.order.proof.failed'),
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
      showAppSnackBar(
          context, _t(context, 'driver.order.activity.done', {'label': label}));
    } else {
      showAppError(context, orderState.errorMessage ?? _t(context, 'driver.order.activity.failed'));
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
      showAppError(context, orderState.errorMessage ?? _t(context, 'driver.order.decline.failed'));
      return;
    }

    showAppSnackBar(
      context,
      orderState.lastDeclineReleasedToPool == true
          ? _t(context, 'driver.order.release.done')
          : _t(context, 'driver.order.decline.done'),
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
      showAppSnackBar(context, _t(context, 'driver.order.accept.done'));
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
  String _t(String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

  // Le code part au serveur et sera compté, l'icône est de l'écran, le libellé
  // est de la langue — d'où trois choses et non une map de deux. Même
  // séparation que `deliveryFailureReasons` / `deliveryFailureLabel`.
  static const _reasons = <(String, IconData)>[
    ('prix_insuffisant', Icons.payments_outlined),
    ('trop_loin', Icons.route_outlined),
    ('vehicule_inadapte', Icons.two_wheeler_outlined),
    ('creneau_impossible', Icons.schedule_outlined),
    ('colis_inadapte', Icons.inventory_2_outlined),
    ('indisponible', Icons.do_not_disturb_on_outlined),
    ('autre', Icons.more_horiz),
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
              widget.assigned ? _t('driver.order.release') : _t('driver.order.decline'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.assigned
                  ? _t('driver.order.release.body')
                  : _t('driver.order.decline.body'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            // Des ListTile sélectionnables plutôt que des RadioListTile : le
            // couple `groupValue`/`onChanged` est déprécié depuis Flutter 3.32
            // au profit de RadioGroup, et cet écran doit compiler sans
            // avertissement sur la version de l'utilisateur, que je ne peux
            // pas éprouver ici. Un tri visuel par coche rend d'ailleurs la
            // sélection plus lisible sur un téléphone tenu d'une main.
            for (final (code, icon) in _reasons)
              ListTile(
                onTap: () => setState(() => _reason = code),
                leading: Icon(icon),
                title: Text(_t('driver.reason.$code')),
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
              decoration: InputDecoration(
                labelText: _t('driver.order.note'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(
              onPressed: _reason == null
                  ? null
                  : () => Navigator.pop(
                        context,
                        (
                          reason: _reason!,
                          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
                        ),
                      ),
              // ⚠️ Le rembourrage vertical valait 14, hors barème — glissé sur
              // `AppSpacing.md` (12), le jeton voisin. Deux pixels, mais la
              // seule valeur d'espacement du fichier qui n'était pas nommée.
              style: AppButtonStyles.destructiveFilled(
                context,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              ),
              child: Text(widget.assigned ? _t('driver.order.release.confirm') : _t('driver.order.decline.confirm')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_t('common.cancel')),
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
  String _t(String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

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
            label: _t('order.pod.label'),
            required: true,
            helperText: _t('driver.order.proof.hint'),
            onChanged: (photo) => setState(() => _photo = photo),
          ),
          const SizedBox(height: AppSpacing.xl),
          FilledButton(
            onPressed: _photo == null
                ? null
                : () => Navigator.pop(context, _photo),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            ),
            child: Text(_t('driver.order.proof.submit')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('common.cancel')),
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
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _t(BuildContext context, String key,
          [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

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
          Text(_t(context, 'driver.order.place.no_address'), style: theme.textTheme.bodySmall),
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
          Text(_t(context, 'driver.order.place.address_in_notes'), style: theme.textTheme.bodySmall),
        if (p.contactName != null) Text(_t(context, 'driver.order.place.contact', {'name': p.contactName!})),
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
                label: Text(_t(context, 'driver.order.route')),
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
      _t(context, 'driver.order.nav.none'),
    );
  }

  Future<void> _call(BuildContext context, String phone) async {
    final ok = await NavigationLauncher.call(phone);
    if (!context.mounted || ok) return;
    showAppError(context, _t(context, 'driver.order.call.failed'));
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
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _t(BuildContext context, String key,
          [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

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
                        ? _t(context, 'driver.order.failures.many',
                            {'count': '${failures.length}'})
                        : _t(context, 'driver.order.failures.one'),
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
                  _t(context, 'driver.order.failures.attempt', {
                    'n': '${failures.length - i}',
                    'date': formatDayTime(
                        failures[i].createdAt, context.read<LocaleState>().locale),
                  }),
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
              _t(context, 'driver.order.failures.note'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ],
        ),
    );
  }

}

class _FailureEntry extends StatelessWidget {
  // ⚠️ `context` en paramètre : un `StatelessWidget` n'a pas de champ
  // `context`, contrairement à un `State`. La même signature partout aurait
  // été plus jolie — elle ne compile pas.
  String _t(BuildContext context, String key,
          [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

  final DeliveryFailure failure;

  const _FailureEntry({required this.failure});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildInfoRow(_t(context, 'driver.order.failures.reason'), failure.reason),
        if (failure.notes != null) _buildInfoRow(_t(context, 'driver.order.failures.notes'), failure.notes!),
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
  String _t(String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

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
            Text(_t('driver.order.cash.title'), style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _t('driver.order.cash.expected', {
                'amount':
                    '${widget.expected.toStringAsFixed(0)} ${widget.currency}',
              }),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _t('driver.order.cash.collected'),
                prefixIcon: const Icon(Icons.account_balance_wallet_outlined),
                suffixText: widget.currency,
              ),
            ),
            if (_differs) ...[
              const SizedBox(height: AppSpacing.lg),
              Text(_t('driver.order.cash.why'), style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              // Le code part au serveur, le libellé suit la langue : la table
              // mêlée figeait les deux dans le même objet.
              for (final code in cashDiscrepancyReasons)
                ListTile(
                  onTap: () => setState(() => _reason = code),
                  title: Text(cashDiscrepancyLabel(
                      code, context.watch<LocaleState>().locale,
                      fallback: code)),
                  trailing: _reason == code
                      ? Icon(Icons.check_circle,
                          color: context.semantic.warning)
                      : null,
                  selected: _reason == code,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              TextField(
                controller: _notes,
                maxLines: 2,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: _t('driver.order.note'),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Text(
              // Rappeler ce qu'implique la validation : la somme devient une
              // dette du transporteur envers le commerçant, et elle le suit
              // jusqu'à la remise.
              _t('driver.order.cash.hint'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
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
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(_t('driver.order.cash.submit')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_t('common.back')),
            ),
          ],
        ),
      ),
    );
  }
}
