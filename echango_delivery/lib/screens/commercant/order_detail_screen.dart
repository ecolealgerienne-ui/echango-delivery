import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../i18n/collections_strings.dart';
import '../../i18n/driver_strings.dart';
import '../../state/locale_state.dart';
import '../../models/merchant_order.dart';
import '../../i18n/order_strings.dart';
import '../../models/order.dart'
    show DeliveryFailure, Place, deliveryFailureLabel;
import '../../models/vehicle_type.dart';
import '../../services/navigation_launcher.dart';
import '../../state/merchant_order_state.dart';
import '../../widgets/proof_image.dart';
import '../../theme/app_buttons.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/dates.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/consultation_map.dart';
import '../../widgets/notice.dart';
import '../../widgets/section_card.dart';

class OrderDetailScreen extends StatefulWidget {
  final String orderId;

  const OrderDetailScreen({super.key, required this.orderId});

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  /// ⚠️ `read` et jamais `watch` : la moitié de ces libellés est lue depuis
  /// `_cancel`, `_publish` ou `_duplicate`, et `watch` hors phase de build lève
  /// chez Provider — défaut d'exécution que `flutter analyze` ne voit pas.
  /// Ne pas observer ne perd rien : `main.dart` reconstruit toute
  /// l'application au changement de langue.
  String _t(String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<MerchantOrderState>().selectOrder(widget.orderId);
    });
  }

  Future<void> _cancel(MerchantOrderState orderState) async {
    final confirmed = await AppConfirmDialog.destructive(
      context,
      title: _t('order.detail.cancel.title'),
      message: _t('order.detail.cancel.body'),
      cancelLabel: _t('order.detail.cancel.back'),
      confirmLabel: _t('order.detail.cancel.confirm'),
    );

    if (!confirmed || !mounted) return;

    final success = await orderState.cancelOrder(widget.orderId);
    if (!mounted) return;

    showAppOutcome(
      context,
      success ? null : orderState.errorMessage ?? _t('order.detail.cancel.failed'),
      _t('order.detail.cancel.done'),
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
      success ? null : orderState.errorMessage ?? _t('order.detail.publish.failed'),
      _t('order.detail.publish.done'),
    );
  }

  /// Change la cible d'une course en attente : diffusion large, ou un favori
  /// nommé. Le serveur **refuse** si la course a déjà été prise ou démarrée —
  /// l'écran n'a donc pas à deviner cette précondition, il la laisse au BFF.
  Future<void> _redirect(MerchantOrderState orderState) async {
    // Les favoris ne sont pas forcément chargés sur cet écran : on les tire au
    // besoin, sinon le tiroir n'offrirait que « large ».
    if (orderState.favourites.isEmpty) await orderState.loadFavourites();
    if (!mounted) return;
    final favourites = orderState.favourites;

    final chosen = await showModalBottomSheet<({bool picked, String? uuid})>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                _t('order.detail.redirect'),
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.public),
              title: Text(_t('order.form.dispatch.large')),
              onTap: () => Navigator.pop(ctx, (picked: true, uuid: null)),
            ),
            ...favourites.map(
              (f) => ListTile(
                leading: Icon(f.isFleet ? Icons.business : Icons.person_outline),
                title: Text(f.name ?? f.driverUuid),
                onTap: () => Navigator.pop(ctx, (picked: true, uuid: f.driverUuid)),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (chosen == null || !chosen.picked) return;

    final success = await orderState.redirectOrder(
      widget.orderId,
      targetFavouriteUuid: chosen.uuid,
    );
    if (!mounted) return;
    showAppOutcome(
      context,
      success ? null : orderState.errorMessage ?? _t('order.detail.redirect.failed'),
      _t('order.detail.redirect.done'),
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
            _t('order.detail.duplicate.failed'),
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
        appBar: AppBar(title: Text(_t('order.detail.title'))),
        body: Consumer<MerchantOrderState>(
          builder: (context, orderState, _) {
            if (orderState.isLoading && orderState.selected == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final order = orderState.selected;
            if (order == null) {
              return Center(
                child: Text(orderState.errorMessage ?? _t('order.detail.not_found')),
              );
            }

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
                                Text(order.statusLabel(
                                    context.watch<LocaleState>().locale)),
                              ],
                            ),
                            if (order.trackingNumber != null) ...[
                              const SizedBox(height: AppSpacing.sm),
                              Text(_t('order.detail.tracking',
                                  {'number': order.trackingNumber!})),
                            ],
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              _t('order.detail.created', {
                                'date': formatFull(order.createdAt,
                                    context.read<LocaleState>().locale)
                              }),
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
                      AppNotice.info(
                        icon: Icons.edit_note,
                        message: _t('order.detail.state.draft'),
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
                      AppNotice.warning(
                        icon: Icons.hourglass_empty,
                        message: _t('order.detail.state.waiting'),
                      )
                    else if (order.isWaitingDispatch)
                      AppNotice.progress(
                        icon: Icons.assignment_turned_in_outlined,
                        message: _t('order.detail.state.assigned'),
                      ),
                    if (order.driverName != null) _driverCard(order),
                    if (order.isCompleted)
                      AppNotice.success(
                        icon: Icons.check_circle_outline,
                        message: _t('order.detail.state.completed'),
                      ),
                    if (order.isCancelled)
                      AppNotice.muted(
                        icon: Icons.cancel_outlined,
                        message: _t('order.detail.state.cancelled'),
                      ),
                    const SizedBox(height: AppSpacing.md),
                    _placeCard(_t('order.section.pickup'), order.pickup, order.pickupNotes),
                    const SizedBox(height: AppSpacing.md),
                    _placeCard(
                      _t('order.section.dropoff'),
                      order.dropoff,
                      order.dropoffNotes,
                      // Corriger la position depuis la fiche client n'a de
                      // sens que tant que la livraison n'a pas encore eu
                      // lieu, et suppose un numéro à chercher.
                      onRefreshFromClient: (!order.isFinished &&
                              order.dropoff?.contactPhone != null &&
                              order.dropoff!.contactPhone!.isNotEmpty)
                          ? () => _refreshDropoffFromClient(
                                orderState,
                                order.dropoff!.contactPhone!,
                              )
                          : null,
                    ),
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
                      FilledButton.icon(
                        onPressed:
                            orderState.isLoading ? null : () => _publish(orderState),
                        icon: const Icon(Icons.publish_outlined),
                        label: Text(_t('order.detail.publish')),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    // Rediriger une course EN ATTENTE : vers un favori, ou en
                    // large. Le serveur refuse si elle a déjà été prise, donc
                    // l'offrir sur toute course « dispatched » est sans risque.
                    if (order.isWaitingDispatch) ...[
                      OutlinedButton.icon(
                        onPressed:
                            orderState.isLoading ? null : () => _redirect(orderState),
                        icon: const Icon(Icons.alt_route),
                        label: Text(_t('order.detail.redirect')),
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
                      label: Text(_t('order.detail.duplicate')),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (order.canCancel)
                      OutlinedButton.icon(
                        onPressed:
                            orderState.isLoading ? null : () => _cancel(orderState),
                        icon: const Icon(Icons.close),
                        label: Text(_t('order.detail.cancel.confirm')),
                        style: AppButtonStyles.destructiveOutlined(context),
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
              title: Text(_t('order.detail.driver.assigned',
                  {'name': order.driverName!})),
              subtitle: order.driverPhone == null
                  ? null
                  : Text(order.driverPhone!),
              trailing: order.driverPhone == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.phone),
                      tooltip: _t('order.detail.driver.call'),
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
              Text(_t('order.pod.label'),
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
  /// livraison réglée — et c'est précisément l'écart que la déclaration à la
  /// porte existe pour rendre visible.
  ///
  /// ── Ce que cette carte ne calcule plus, et pourquoi ────────────────────────
  ///
  /// Elle annonçait « vous reviendra : 1 400 » — le perçu moins la rémunération
  /// du transporteur. C'est une **règle de règlement** (« le transporteur
  /// retient sa course sur les espèces qu'il tient »), pas une lecture : la
  /// plateforme l'arbitrait à la place des deux parties. Retirée le 03/08/2026
  /// avec le registre de caisse (`docs/registre_caisse_precis.md`).
  ///
  /// Les deux nombres restent affichés — le montant perçu et le prix de la
  /// course. Ce qu'ils donnent une fois soustraits dépend de l'arrangement
  /// entre le commerçant et son transporteur, et c'est à eux de le tenir.
  Widget _cashCard(MerchantOrder order) {
    final currency = order.codCurrency ?? '';
    final theme = Theme.of(context);
    final locale = context.watch<LocaleState>().locale;

    // Le montant et sa devise, en une seule forme. `currency` peut être vide
    // (commande d'avant que la devise soit projetée) : concaténer sans couper
    // laisserait « 650 » suivi d'une espace, visible entre parenthèses.
    String money(num amount) => '${amount.toStringAsFixed(0)} $currency'.trim();

    // ⚠️ `!= null` et non une vérité : **zéro est une déclaration**, et c'en
    // est la plus importante — un destinataire qui a refusé de payer. Un test
    // sur la valeur l'aurait rangée avec « pas encore encaissé », c'est-à-dire
    // aurait effacé le seul cas où le commerçant doit être prévenu.
    final declared = order.collectedAmount != null;

    return AppSectionCard(
      // Même rôle des deux côtés : l'écart se signale par son libellé, pas par
      // une nuance d'orange que personne ne sait nommer.
      color: context.semantic.warningContainer,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_balance_wallet_outlined, size: 20),
                const SizedBox(width: AppSpacing.sm),
                Text(_t('order.detail.cash.title'), style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(_t('order.detail.cash.requested', {
              'amount': money(order.codAmount!),
            })),
            if (!declared)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  _t('order.detail.cash.pending'),
                  style: theme.textTheme.bodySmall,
                ),
              )
            else ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _t('order.detail.cash.collected', {
                  'amount': money(order.collectedAmount!),
                }),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (order.hasCollectionDiscrepancy) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  collectionReasonLabel(
                    order.collectionReason,
                    locale,
                    fallback: collectionsLabel('collections.reason.autre', locale),
                  ),
                  style: TextStyle(color: context.semantic.onWarningContainer),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              Text(
                _t('order.detail.cash.held'),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ]),
    );
  }

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
          _t('order.detail.row.price'),
          '${order.price!.toStringAsFixed(0)} ${order.currency ?? ''}'.trim(),
        ),
      if (order.scheduledAt != null)
        (
          Icons.schedule_outlined,
          _t('order.schedule.title'),
          formatDayTime(order.scheduledAt!, context.read<LocaleState>().locale),
        )
      else
        (Icons.schedule_outlined, _t('order.schedule.title'), _t('order.schedule.asap')),
      if (order.vehicleType != null)
        (
          vehicleIcon(order.vehicleType),
          _t('order.detail.row.vehicle'),
          _t('order.detail.row.vehicle.value', {
            'vehicle': vehicleLabel(
                order.vehicleType, context.read<LocaleState>().locale)
          }),
        ),
      if (order.podMethod != null)
        (
          Icons.verified_outlined,
          _t('order.detail.row.proof'),
          switch (order.podMethod!) {
            'photo' => _t('order.pod.photo'),
            'aucune' => _t('order.detail.pod.none_requested'),
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
          _t('order.detail.row.cod'),
          '${order.codAmount!.toStringAsFixed(0)} ${order.codCurrency ?? ''}'.trim() +
              (order.codIncludesDelivery
                  ? _t('order.detail.cod.merchant_pays')
                  : _t('order.detail.cod.client_pays')),
        ),
      // Une ligne par article : le poids et la mention fragile étaient saisis
      // puis invisibles, alors que ce sont eux qui fondent un refus pour
      // « colis inadapté ».
      for (final item in order.items)
        (
          Icons.inventory_2_outlined,
          _t('order.section.parcel'),
          item.label(context.read<LocaleState>().locale)
        ),
      // Repli pour les commandes d'avant la projection détaillée des articles.
      if (order.items.isEmpty && order.packageContents != null)
        (Icons.inventory_2_outlined, _t('order.section.parcel'), order.packageContents!),
      (
        order.targetFavouriteUuid != null ? Icons.star_outline : Icons.public,
        _t('order.detail.row.dispatch'),
        order.targetFavouriteUuid != null
            ? _t('order.detail.dispatch.favourites')
            : _t('order.detail.dispatch.network'),
      ),
      if (order.instructions != null)
        (Icons.notes_outlined, _t('order.detail.row.instructions'), order.instructions!),
    ];

    return AppSectionCard(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t('order.detail.request'),
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
          title: Text(_t('order.detail.favourite.add',
              {'name': order.driverName ?? ''})),
          subtitle: Text(
            _t('order.detail.favourite.hint'),
          ),
          onTap: () => context.push('/commercant/transporteurs'),
        ),
      );


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
  Widget _placeCard(
    String title,
    Place? place,
    String? notes, {
    VoidCallback? onRefreshFromClient,
  }) {
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
                    tooltip: _t('order.detail.driver.call.short'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => NavigationLauncher.call(phone),
                  ),
                ],
              ),
            // Corrige le point à partir de la fiche client mise à jour
            // après coup — capacité entièrement nouvelle
            // (`docs/specs_localisation_client_et_optimisation_parcours.md`
            // §1.6), puisqu'aucune route ne modifiait une commande existante
            // avant elle.
            if (onRefreshFromClient != null) ...[
              const SizedBox(height: AppSpacing.sm),
              TextButton.icon(
                onPressed: onRefreshFromClient,
                icon: const Icon(Icons.my_location, size: 16),
                label: Text(_t('order.detail.refresh_from_client')),
              ),
            ],
          ],
        ),
    );
  }

  /// Relit la fiche client pour ce numéro et, si elle porte une position,
  /// corrige le point de dépose de cette commande.
  Future<void> _refreshDropoffFromClient(
    MerchantOrderState orderState,
    String phone,
  ) async {
    final lookup = await orderState.lookupClient(phone);
    if (!mounted) return;

    if (lookup == null || !lookup.found || !lookup.hasPosition) {
      showAppError(context, _t('order.detail.refresh_from_client.none'));
      return;
    }

    final success = await orderState.updateOrderPosition(
      widget.orderId,
      latitude: lookup.latitude!,
      longitude: lookup.longitude!,
    );
    if (!mounted) return;

    showAppOutcome(
      context,
      success
          ? null
          : orderState.errorMessage ?? _t('order.detail.refresh_from_client.failed'),
      _t('order.detail.refresh_from_client.done'),
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
  /// Sa propre traduction : c'est une autre classe, donc un autre `context`.
  String _t(String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

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
          label: Text(_t('order.detail.driver.position')),
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
      // ⚠️ Un bloc visible, pas une ligne de 12 px. `{ position: null }`
      // couvre trois cas normaux — personne n'a pris la course, le
      // transporteur n'a rien remonté, sa fiche est momentanément illisible —
      // et l'ancien texte minuscule se lisait comme « rien ne s'est passé »
      // après un appui sur le bouton. Le message dit ce qu'on attend et offre
      // de réessayer.
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          children: [
            Icon(Icons.location_off_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _t('order.detail.driver.position.none'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _t('order.detail.driver.position.none.hint'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(_t('order.detail.refresh')),
            ),
          ],
        ),
      );
    }

    final driver = LatLng(position.latitude, position.longitude);
    final dropoff = _pointOf(widget.order.dropoff);

    return Column(
      children: [
        SizedBox(
          height: 200,
          // Les tuiles, leur agent OSM et l'absence de rotation vivent dans le
          // composant partagé : ce sont les deux seules choses qui doivent
          // rester identiques sur toutes les cartes de consultation. Les
          // repères, eux, répondent à la question de cet écran-ci.
          child: AppConsultationMap(
            // Le transporteur ET la dépose dans le cadre : voir l'un sans
            // l'autre ne dit pas si la course avance.
            fitPoints: [driver, if (dropoff != null) dropoff],
            markers: [
              // Le gris (`stale`) dit « ce point n'est plus frais » sans texte
              // à lire : c'est la première chose qu'on voit sur une carte,
              // avant la légende.
              consultationMarker(
                context,
                at: driver,
                kind: position.isStale
                    ? MapMarkerKind.stale
                    : MapMarkerKind.driver,
                tooltip: driverLabel('driver.trip.legend.you',
                    context.read<LocaleState>().locale),
              ),
              if (dropoff != null)
                consultationMarker(
                  context,
                  at: dropoff,
                  kind: MapMarkerKind.dropoff,
                  tooltip: driverLabel('driver.trip.legend.dropoff',
                      context.read<LocaleState>().locale),
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: MapLegend(showDriver: true),
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
                  switch (position
                      .freshness(context.read<LocaleState>().locale)) {
                    null => _t('order.detail.driver.position.unknown'),
                    // `when` est un mot réservé des motifs Dart — d'où `seen`,
                    // alors que la clé de traduction, elle, garde `{when}`.
                    final seen =>
                      _t('order.detail.driver.position.seen', {'when': seen}),
                  },
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: _load,
                child: Text(_t('order.detail.refresh')),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = context.watch<LocaleState>().locale;
    String t(String key, [Map<String, String>? vars]) =>
        orderLabel(key, locale, vars);
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
                        ? t('order.detail.failure.many',
                            {'count': '${failures.length}'})
                        : t('order.detail.failure.one'),
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
                  t('order.detail.failure.attempt',
                      {'n': '${failures.length - i}'}),
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.onErrorContainer),
                ),
              Text(deliveryFailureLabel(failures[i].reason, locale),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (failures[i].notes != null) Text(failures[i].notes!),
              if (failures[i].photoUrl != null) ...[
                const SizedBox(height: AppSpacing.sm),
                ProofImage(url: failures[i].photoUrl!),
              ],
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              t('order.detail.failure.contact'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ],
        ),
    );
  }
}
