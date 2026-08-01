import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/cash_strings.dart';
import '../../models/cash.dart';
// Pour `orderStatusLabel` : le libellé d'un statut vit à un seul endroit
// (règle 4 du projet), même quand l'écran ne manipule pas de `MerchantOrder`.
import '../../models/merchant_order.dart' show KnownDriver, orderStatusLabel;
import '../../services/navigation_launcher.dart';
import '../../state/cash_state.dart';
import '../../state/locale_state.dart';
import '../../config/app_rules.dart';
import '../../theme/app_buttons.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/dates.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/section_card.dart';

/// Registre de caisse, vu du transporteur ou du commerçant.
///
/// ── Un seul écran pour deux profils ─────────────────────────────────────────
///
/// Les deux regardent le même registre depuis les deux bouts : ce que l'un doit
/// est ce que l'autre attend, et les gestes sont symétriques — déclarer une
/// remise, confirmer celle de l'autre, la contester. Deux écrans auraient
/// dupliqué la seule logique qui doit rester commune : qui peut confirmer quoi.
///
/// Seuls les mots changent, et ils comptent : « je dois » n'est pas « on me
/// doit », même quand c'est le même nombre.
class CashScreen extends StatefulWidget {
  /// `driver` ou `merchant`.
  final String persona;

  const CashScreen({super.key, required this.persona});

  @override
  State<CashScreen> createState() => _CashScreenState();
}

class _CashScreenState extends State<CashScreen> {
  bool get _isDriver => widget.persona == 'driver';

  /// Traduction depuis un **callback** — `read`, jamais `watch`.
  ///
  /// ⚠️ `watch` hors d'une phase de build lève chez Provider, et ces méthodes
  /// (`_declare`, `_dispute`, …) s'exécutent après un appui. C'est le défaut
  /// qui faisait planter les deux actions principales de l'écran flotte le
  /// 31/07, et que `flutter analyze` ne voit pas : c'est une règle d'exécution,
  /// pas de typage.
  ///
  /// Ne pas observer ici ne perd rien : un changement de langue reconstruit
  /// toute l'application (`Consumer<LocaleState>` dans `main.dart`).
  String _t(String key, [Map<String, String>? vars]) =>
      cashLabel(key, context.read<LocaleState>().locale, vars);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<CashState>();
      state.setPersona(widget.persona);
      state.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CashState>();
    final locale = context.watch<LocaleState>().locale;
    String t(String key, [Map<String, String>? vars]) =>
        cashLabel(key, locale, vars);

    return Scaffold(
      appBar: AppBar(
        title: Text(switch (widget.persona) {
          'driver' => t('cash.title.driver'),
          'fleet' => t('cash.title.fleet'),
          _ => t('cash.title.merchant'),
        }),
      ),
      body: RefreshIndicator(
        onRefresh: state.load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            if (state.errorMessage != null)
              AppErrorBanner(
                message: state.errorMessage!,
                onRetry: () => context.read<CashState>().load(),
              ),
            _totalCard(state, t),
            const SizedBox(height: AppSpacing.lg),

            // Ce qui appelle une action passe en premier. Une confirmation en
            // attente bloque une dette : la reléguer sous l'historique la ferait
            // oublier, et la dette resterait due alors que l'argent a changé de
            // mains.
            // Un encaissement que le commerçant a déclaré à ma place attend le
            // même geste qu'une remise, et pour la même raison : sans ma
            // confirmation, il n'entre dans aucune dette. Le placer ailleurs
            // que dans « À confirmer » en ferait deux mécaniques distinctes
            // pour une seule règle.
            if (state.collectionsToConfirm.isNotEmpty) ...[
              _sectionTitle(t('cash.section.collections_to_confirm')),
              for (final c in state.collectionsToConfirm)
                _CollectionToConfirmCard(
                  entry: c,
                  onConfirm: () => _confirmCollection(state, c),
                  onDispute: () => _disputeCollection(state, c),
                ),
              const SizedBox(height: AppSpacing.lg),
            ],

            if (state.awaitingMyConfirmation.isNotEmpty) ...[
              _sectionTitle(t('cash.section.to_confirm')),
              for (final r in state.awaitingMyConfirmation)
                _PendingRemittanceCard(
                  remittance: r,
                  onConfirm: () => _confirm(state, r),
                  onDispute: () => _dispute(state, r),
                ),
              const SizedBox(height: AppSpacing.lg),
            ],

            // ── L'anomalie passe avant les soldes ────────────────────────────
            //
            // Une livraison terminée dont l'encaissement n'a jamais été déclaré
            // est le seul cas où le registre ne peut PAS trancher : il ignore
            // si l'argent a changé de mains. La reléguer sous l'historique la
            // ferait manquer, et c'est précisément l'argent qu'on risque de ne
            // jamais revoir.
            if (!_isDriver && state.unrecorded.isNotEmpty) ...[
              _UnrecordedBanner(
                total: state.unrecordedTotal,
                count: state.unrecorded.length,
                currency: state.currency,
              ),
              for (final p in state.unrecorded)
                _PendingCard(
                  entry: p,
                  currency: state.currency,
                  isAnomaly: true,
                  onRegularise: () => _regularise(state, p),
                ),
              const SizedBox(height: AppSpacing.lg),
            ],

            // « Mes transporteurs » est faux pour une entreprise : sa liste
            // mêle ses conducteurs et les commerçants qu'elle sert.
            _sectionTitle(t(_isDriver || widget.persona == 'fleet'
                ? 'cash.section.accounts'
                : 'cash.section.carriers')),
            if (state.isLoading && state.ledger == null)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.xxl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (state.ledger?.isEmpty ?? true)
              _empty(
                t,
                hasPending: state.pending.isNotEmpty,
                hasUnrecorded: state.unrecorded.isNotEmpty,
              )
            else
              for (final balance in state.ledger!.balances)
                _BalanceCard(
                  balance: balance,
                  currency: state.currency,
                  persona: widget.persona,
                  onDeclare: () => _declare(state, balance),
                ),

            // L'attendu vient après les soldes et avant le détail du perçu :
            // c'est l'ordre du temps. Ce qu'on détient, ce qui va venir, puis
            // d'où venait ce qu'on détient.
            if (state.pending.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _sectionTitle(t('cash.section.pending')),
              for (final p in state.pending)
                _PendingCard(entry: p, currency: state.currency),
            ],

            // Le détail vient APRÈS les soldes, et c'est délibéré : on lit
            // d'abord combien, ensuite d'où ça vient. L'inverse noierait le
            // chiffre qui intéresse dans une liste de lignes.
            if (state.collections.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _sectionTitle(t('cash.section.collections')),
              for (final c in state.collections.take(AppRules.cashCollectionsPreview))
                _CollectionCard(entry: c, persona: widget.persona),
              if (state.collections.length > AppRules.cashCollectionsPreview)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    // ⚠️ Le nombre était écrit en dur ICI AUSSI. Trois
                    // occurrences du même 20 dans le même bloc : en changer une
                    // seule aurait fait mentir l'écran — vingt-cinq lignes sous
                    // un titre en annonçant vingt.
                    t('cash.collections.preview', {
                      'count': '${AppRules.cashCollectionsPreview}',
                      'total': '${state.collections.length}',
                    }),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],

            if (state.awaitingOther.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _sectionTitle(t('cash.section.awaiting_other')),
              for (final r in state.awaitingOther)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.hourglass_empty),
                    title: Text(r.formattedAmount),
                    subtitle: Text(t(switch (widget.persona) {
                      'driver' => 'cash.awaiting.driver',
                      // `CashRemittance` ne porte pas le type de la
                      // contrepartie : une entreprise remet à un commerçant et
                      // reçoit d'un conducteur, et on ne peut pas dire lequel
                      // ici. On reste neutre plutôt que de deviner.
                      'fleet' => 'cash.awaiting.fleet',
                      _ => 'cash.awaiting.merchant',
                    })),
                  ),
                ),
            ],
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _totalCard(CashState state, _T t) {
    final theme = Theme.of(context);
    // ⚠️ **Deux totaux, pas un — parce qu'une entreprise de transport est au
    // MILIEU de la chaîne.** Ses conducteurs lui doivent, elle doit aux
    // commerçants : `CashLedger.total` soustrayait donc sa créance de sa dette
    // et affichait leur différence sous le libellé « Espèces encaissées pour
    // vous ». Un nombre qui ne désignait rien.
    //
    // La structure suit la DONNÉE et non le profil : `totalOn` rend `null`
    // quand personne ne se trouve de ce côté, donc le conducteur et le
    // commerçant — qui ne font face qu'à un seul côté — gardent exactement leur
    // ligne unique d'avant.
    final owedToMe = state.totalOn(CashSide.upstream);
    final iHold = state.totalOn(CashSide.downstream);
    final bothSides = owedToMe != null && iHold != null;

    Widget line(String label, double amount) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${amount.toStringAsFixed(0)} ${state.currency}',
              style: theme.textTheme.headlineMedium,
            ),
          ],
        );

    return AppSectionCard(
      // Un ton unique ne peut pas décrire les deux côtés à la fois : ce que
      // l'entreprise détient appelle une action, ce qu'on lui doit non. Neutre
      // pour elle, plutôt qu'une couleur qui affirmerait l'un des deux.
      color: bothSides
          ? Theme.of(context).colorScheme.secondaryContainer
          : _isDriver
              ? context.semantic.warningContainer
              : context.semantic.successContainer,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (owedToMe != null)
              line(
                t(bothSides
                    ? 'cash.total.owed_by_drivers'
                    : 'cash.total.collected_for_you'),
                owedToMe,
              ),
            if (bothSides) const Divider(height: 24),
            if (iHold != null)
              line(
                t(bothSides
                    ? 'cash.total.owed_to_merchants'
                    : 'cash.total.you_hold'),
                iHold,
              ),
            // Aucun côté renseigné : le serveur n'a pas typé les contreparties.
            // On sert le total brut plutôt qu'un écran vide, en le disant.
            if (owedToMe == null && iHold == null)
              line(t('cash.total.position'), state.total),
            const SizedBox(height: AppSpacing.sm),
            Text(
              // Dire que ce total ne se règle pas d'un coup : il est dû à
              // plusieurs personnes, et c'est le point qui distingue ce modèle
              // d'un compte chez un transporteur classique.
              t(bothSides
                  ? 'cash.total.note.both'
                  : _isDriver
                      ? 'cash.total.note.driver'
                      : 'cash.total.note.merchant'),
              style: theme.textTheme.bodySmall,
            ),
            // ── Ce qui est attendu, et qui n'est encore à personne ───────────
            //
            // Séparé du total par une ligne, jamais additionné : le total est
            // détenu par quelqu'un, l'attendu ne l'est par personne. Les
            // confondre ferait croire à une somme récupérable aujourd'hui.
            if (!_isDriver && state.expectedTotal > 0) ...[
              const Divider(height: 24),
              Text(
                t('cash.expected.total', {
                  'amount': state.expectedTotal.toStringAsFixed(0),
                  'currency': state.currency,
                }),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                // Deux formes seulement, choisies ici : l'arabe en distingue
                // davantage, et `cash_strings.dart` dit pourquoi on s'arrête là.
                t(
                  state.pending.length > 1
                      ? 'cash.expected.count.many'
                      : 'cash.expected.count.one',
                  {'count': '${state.pending.length}'},
                ),
                style: theme.textTheme.bodySmall,
              ),
            ],

            // La commission ne se règle pas ici, et l'écran doit le dire :
            // l'afficher comme un solde exigible promettrait un bouton qui
            // n'existe pas. C'est un montant enregistré, pas une dette que
            // l'application sait encaisser.
            if (_isDriver && (state.ledger?.platformCommission ?? 0) > 0) ...[
              const Divider(height: 24),
              Text(
                t('cash.commission.total', {
                  'amount':
                      state.ledger!.platformCommission!.toStringAsFixed(0),
                  'currency': state.currency,
                }),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                t('cash.commission.note'),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
    );
  }

  /// Aucun solde ouvert. [hasPending] change le texte du tout au tout.
  ///
  /// « Aucune somme en attente » était faux dès qu'une course encaissée était
  /// en route : rien n'était *détenu*, mais de l'argent était bel et bien
  /// attendu. C'est la formulation qui rassure à tort — celle qui coûte le plus
  /// cher, parce qu'on ne va pas vérifier ce qu'un écran déclare tranquille.
  Widget _empty(_T t, {bool hasPending = false, bool hasUnrecorded = false}) {
    // ⚠️ L'ordre des cas compte : avec une anomalie au-dessus, « aucune somme
    // en attente » contredirait la bannière qui vient d'annoncer des
    // livraisons non enregistrées.
    if (widget.persona == 'fleet') {
      // `hasPending`/`hasUnrecorded` sont toujours faux ici : « l'argent
      // attendu aux portes » est une lecture propre au commerçant, et
      // `CashState.load()` ne la demande pas pour une entreprise. Les brancher
      // aurait affiché une consigne sur une donnée jamais chargée.
      return AppEmptyState(
        title: t('cash.empty.fleet.title'),
        hint: t('cash.empty.fleet.hint'),
        icon: Icons.payments_outlined,
        scrollable: false,
      );
    }

    final String prefix = _isDriver
        ? 'cash.empty.driver'
        : hasUnrecorded
            ? 'cash.empty.unrecorded'
            : hasPending
                ? 'cash.empty.pending'
                : 'cash.empty.none';

    return AppEmptyState(
      title: t('$prefix.title'),
      hint: t('$prefix.hint'),
      icon: hasPending ? Icons.schedule_outlined : Icons.payments_outlined,
      // Déjà dans un `ListView` : une seconde liste imbriquée ne défilerait pas.
      scrollable: false,
    );
  }

  Future<void> _declare(CashState state, CashBalance balance) async {
    final amount = await showDialog<double>(
      context: context,
      builder: (_) => _AmountDialog(
        title: _t('cash.declare.title'),
        subtitle: _t('cash.declare.subtitle', {
          'name': balance.displayName(context.read<LocaleState>().locale),
        }),
        maximum: balance.outstanding,
        currency: state.currency,
      ),
    );

    if (amount == null || !mounted) return;

    final ok = await state.declareRemittance(balance.counterpartyId, amount);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? _t('cash.declare.failed'),
      _t('cash.declare.done'),
    );
  }

  Future<void> _confirm(CashState state, CashRemittance r) async {
    final ok = await state.confirmRemittance(r.id);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? _t('cash.confirm.failed'),
      _t('cash.confirm.done', {'amount': r.formattedAmount}),
    );
  }

  /// Régularise une livraison close hors application.
  ///
  /// Le montant est prérempli avec celui qui était **annoncé** — c'est le seul
  /// chiffre que nous connaissions, et dans le cas courant c'est le bon. Le
  /// commerçant le corrige si le client a payé autrement ; un écart exige alors
  /// un motif, comme à la porte.
  Future<void> _regularise(CashState state, PendingCollection p) async {
    final amount = await showDialog<double>(
      context: context,
      builder: (_) => _AmountDialog(
        title: _t('cash.regularise.title'),
        subtitle: p.driverName != null
            ? _t('cash.regularise.subtitle.named', {'name': p.driverName!})
            : _t('cash.regularise.subtitle.anon'),
        maximum: p.expectedAmount,
        currency: state.currency,
        // Zéro est une réponse légitime ici — « le client n'a pas payé » est un
        // fait à enregistrer, pas une absence de saisie. Sur une remise, au
        // contraire, remettre zéro ne décrit aucun geste.
        allowZero: true,
      ),
    );

    if (amount == null || !mounted) return;

    // ── Qui a effectué la course, quand la livraison ne le dit pas ──────────
    //
    // Une course close depuis la console peut ne porter aucun transporteur.
    // Le serveur refuse alors avec `cash.driver_required` — mais lui laisser
    // renvoyer cette erreur serait un aller-retour perdu : le commerçant sait
    // qui est venu, il faut le lui demander, pas le lui reprocher.
    String? driverUuid;
    if (p.driverName == null) {
      driverUuid = await showDialog<String>(
        context: context,
        builder: (_) => const _DriverPickerDialog(),
      );
      if (driverUuid == null || !mounted) return;
    }

    // Un écart demande un motif — le serveur le refuse sans, et lui répondre
    // par une erreur alors qu'on pouvait le demander serait un aller-retour
    // inutile.
    String? reason;
    if (amount != p.expectedAmount) {
      reason = await showDialog<String>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: Text(_t('cash.discrepancy.why')),
          children: [
            for (final code in cashDiscrepancyReasons)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, code),
                child: Text(_t('cash.discrepancy.$code')),
              ),
          ],
        ),
      );
      if (reason == null || !mounted) return;
    }

    final ok = await state.declareMissingCollection(
      orderId: p.orderUuid,
      collectedAmount: amount,
      fleetbaseDriverUuid: driverUuid,
      discrepancyReason: reason,
    );
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? _t('cash.declare.failed'),
      _t('cash.regularise.done'),
    );
  }

  Future<void> _confirmCollection(CashState state, CashCollectionEntry c) async {
    final ok = await state.confirmCollection(c.id);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? _t('cash.confirm.failed'),
      _t('cash.collection.confirm.done'),
    );
  }

  Future<void> _disputeCollection(CashState state, CashCollectionEntry c) async {
    final confirmed = await AppConfirmDialog.destructive(
      context,
      title: _t('cash.collection.dispute.title'),
      message: _t('cash.collection.dispute.body', {
        'amount': c.collectedAmount.toStringAsFixed(0),
        'currency': c.currency,
      }),
      cancelLabel: _t('cash.action.back'),
      confirmLabel: _t('cash.action.dispute'),
    );

    if (!confirmed || !mounted) return;

    final ok = await state.disputeCollection(c.id);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? _t('cash.dispute.failed'),
      _t('cash.collection.dispute.done'),
    );
  }

  Future<void> _dispute(CashState state, CashRemittance r) async {
    final confirmed = await AppConfirmDialog.destructive(
      context,
      title: _t('cash.remittance.dispute.title'),
      message: _t('cash.remittance.dispute.body', {
        'amount': r.formattedAmount,
      }),
      cancelLabel: _t('cash.action.back'),
      confirmLabel: _t('cash.action.dispute'),
    );

    if (!confirmed || !mounted) return;

    final ok = await state.disputeRemittance(r.id);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? _t('cash.dispute.failed'),
      _t('cash.remittance.dispute.done'),
    );
  }
}

/// La fonction de traduction telle qu'elle circule dans cet écran.
///
/// Nommée plutôt que réécrite à chaque signature : c'est le même contrat
/// partout, et une variante qui accepterait un autre type de variables se
/// verrait à la compilation plutôt qu'à l'exécution.
typedef _T = String Function(String key, [Map<String, String>? vars]);

class _BalanceCard extends StatelessWidget {
  final CashBalance balance;
  final String currency;

  /// Le profil qui regarde — `driver`, `fleet` ou `merchant`.
  ///
  /// ⚠️ Remplace un `bool isDriver`. Un booléen ne peut pas distinguer trois
  /// positions dans une chaîne, et c'est exactement ce qui rangeait
  /// l'entreprise de transport du côté du commerçant.
  final String persona;
  final VoidCallback onDeclare;

  const _BalanceCard({
    required this.balance,
    required this.currency,
    required this.persona,
    required this.onDeclare,
  });

  bool get isDriver => persona == 'driver';

  /// « J'ai remis » ou « J'ai reçu » : qui verse dépend de qui détient.
  ///
  /// Une entreprise **reçoit** de son conducteur et **verse** à un commerçant,
  /// sur le même écran — d'où un libellé calculé par solde et non par profil.
  String _declareLabel(CashBalance balance, _T t) {
    final holdsIt = switch (cashSide(persona, balance.counterpartyType)) {
      // La contrepartie encaisse : c'est elle qui détient quand la dette est
      // positive, donc c'est moi qui reçois.
      CashSide.upstream => !balance.upstreamHolds,
      // C'est moi qui encaisse pour elle.
      CashSide.downstream => balance.upstreamHolds,
      // Sans type de contrepartie, on retombe sur l'ancien raisonnement par
      // profil plutôt que d'inventer : le conducteur détient, les autres non.
      CashSide.unknown => isDriver == balance.upstreamHolds,
    };
    return t(holdsIt ? 'cash.action.remitted' : 'cash.action.received');
  }

  /// Qui doit à qui, en toutes lettres. Un montant nu sur un solde signé se
  /// lit dans le mauvais sens une fois sur deux.
  ///
  /// ⚠️ **Le sens vient de la POSITION de la contrepartie, plus du profil qui
  /// regarde.** L'écran testait `isDriver`, donc toute entreprise de transport
  /// était traitée comme un commerçant — or elle est au milieu de la chaîne, et
  /// ses soldes face à un commerçant se lisaient exactement à l'envers :
  /// « Détenue par ce transporteur » alors que c'est elle qui détient, et
  /// qu'elle doit.
  ///
  /// La règle tient en une ligne et vaut pour les trois profils : une dette
  /// positive signifie que la partie **en amont** détient l'argent.
  String _sense(CashBalance balance, _T t, Locale locale) {
    final who = cashPartyLabel(balance.counterpartyType, locale);
    switch (cashSide(persona, balance.counterpartyType)) {
      case CashSide.upstream:
        return t(
          balance.upstreamHolds ? 'cash.sense.held_by' : 'cash.sense.you_owe',
          {'who': who},
        );
      case CashSide.downstream:
        return balance.upstreamHolds
            ? t('cash.sense.you_hold', {'who': who})
            // La majuscule initiale reste ici : en tête de phrase en français,
            // et sans effet en arabe, qui n'a pas de casse. La faire porter par
            // la table aurait demandé deux entrées pour un même mot.
            : t('cash.sense.owes_you', {
                'who': '${who[0].toUpperCase()}${who.substring(1)}',
              });
      case CashSide.unknown:
        // Le serveur n'a pas dit de quel type est la contrepartie : on montre
        // le montant sans affirmer un sens. Se tromper de sens sur de l'argent
        // coûte plus cher que de ne rien dire.
        return t(balance.upstreamHolds
            ? 'cash.sense.upstream_unknown'
            : 'cash.sense.reverse_unknown');
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleState>().locale;
    String t(String key, [Map<String, String>? vars]) =>
        cashLabel(key, locale, vars);

    return AppSectionCard.dense(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    balance.displayName(locale),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${balance.outstanding.toStringAsFixed(0)} $currency',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        // Le sens se lit à la couleur avant le texte : ce que je
                        // dois n'est pas ce qu'on me doit, même quand c'est le
                        // même nombre.
                        color: balance.upstreamHolds
                            ? null
                            : context.semantic.success,
                      ),
                ),
              ],
            ),
            // Le blocage se dit, il ne se subit pas en silence : un transporteur
            // qui cesse de recevoir des courses encaissées sans savoir pourquoi
            // conclurait à une panne, ou à une mise à l'écart.
            if (balance.blocked) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Icon(Icons.block,
                      size: 16, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isDriver
                          ? t('cash.blocked.driver')
                          : t('cash.blocked.other', {
                              'who': cashPartyLabel(
                                  balance.counterpartyType, locale),
                            }),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
            Text(
              _sense(balance, t, locale),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                if (balance.phone != null)
                  TextButton.icon(
                    onPressed: () => NavigationLauncher.call(balance.phone!),
                    icon: const Icon(Icons.phone, size: 18),
                    label: Text(t('cash.action.call')),
                  ),
                const Spacer(),
                FilledButton.tonal(
                  onPressed: onDeclare,
                  // Le libellé suit le sens réel du versement, pas le profil :
                  // un transporteur à qui le commerçant doit de l'argent
                  // *reçoit*, il ne remet pas.
                  // Qui remet dépend de qui détient, donc du CÔTÉ de la
                  // contrepartie : une entreprise reçoit de son conducteur et
                  // verse à un commerçant, sur le même écran.
                  child: Text(_declareLabel(balance, t)),
                ),
              ],
            ),
          ],
        ),
    );
  }
}

class _PendingRemittanceCard extends StatelessWidget {
  final CashRemittance remittance;
  final VoidCallback onConfirm;
  final VoidCallback onDispute;

  const _PendingRemittanceCard({
    required this.remittance,
    required this.onConfirm,
    required this.onDispute,
  });

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleState>().locale;
    String t(String key) => cashLabel(key, locale);

    return AppSectionCard.dense(
      color: context.semantic.warningContainer,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(remittance.formattedAmount,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              // Le déclarant est NOMMÉ par la donnée (`declared_by`), pas
              // déduit du profil qui regarde. L'ancienne version disait
              // « Le transporteur déclare… » à toute entreprise de transport,
              // y compris quand c'était un commerçant qui avait déclaré.
              t(switch (remittance.declaredBy) {
                'driver' => 'cash.declared_by.driver',
                'fleet' => 'cash.declared_by.fleet',
                'merchant' => 'cash.declared_by.merchant',
                _ => 'cash.declared_by.unknown',
              }),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                TextButton(
                  onPressed: onDispute,
                  style: AppButtonStyles.destructiveText(context),
                  child: Text(t('cash.action.received_nothing')),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: onConfirm,
                  child: Text(t('cash.action.confirm')),
                ),
              ],
            ),
          ],
        ),
    );
  }
}

/// Saisie d'un montant, bornée par la dette réelle.
///
/// Le plafond n'est pas une commodité : déclarer plus qu'on ne doit ne décrit
/// aucun geste possible, et le serveur le refuse. L'imposer ici évite d'envoyer
/// une requête vouée à l'échec, et le bouton « tout » couvre le cas courant —
/// on solde généralement l'intégralité.
class _AmountDialog extends StatefulWidget {
  final String title;
  final String subtitle;
  final double maximum;
  final String currency;

  /// Autorise un montant nul. Faux par défaut : sur une remise, zéro ne décrit
  /// aucun geste. Vrai sur une régularisation, où « le client n'a rien payé »
  /// est un fait qu'il faut pouvoir enregistrer.
  final bool allowZero;

  const _AmountDialog({
    required this.title,
    required this.subtitle,
    required this.maximum,
    required this.currency,
    this.allowZero = false,
  });

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.maximum.toStringAsFixed(0));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _value {
    final parsed = double.tryParse(_controller.text.trim());
    if (parsed == null || parsed > widget.maximum) return null;
    if (widget.allowZero ? parsed < 0 : parsed <= 0) return null;
    return parsed;
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleState>().locale;
    String t(String key, [Map<String, String>? vars]) =>
        cashLabel(key, locale, vars);

    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: t('cash.amount.label', {'currency': widget.currency}),
              helperText: t('cash.amount.max', {
                'amount': widget.maximum.toStringAsFixed(0),
              }),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('cash.action.cancel')),
        ),
        FilledButton(
          onPressed: _value == null ? null : () => Navigator.pop(context, _value),
          child: Text(t('cash.action.validate')),
        ),
      ],
    );
  }
}

/// Une livraison encaissée, décomposée.
///
/// ── Pourquoi les trois montants et pas seulement le solde ──────────────────
///
/// Depuis que le montant réclamé à la porte comprend la livraison, « perçu »
/// et « ce qui vous revient » ne sont plus le même nombre. Un commerçant qui
/// ne voit que le total ne peut ni le vérifier, ni expliquer un écart à son
/// client — alors que c'est exactement ce qu'il contrôle avant de confirmer une
/// remise, geste qui éteint une dette.
///
/// La retenue est celle **réellement prélevée**, plafonnée à ce qui a été
/// perçu : sur une livraison payée en partie, elle diffère du prix de la
/// course, et afficher le prix théorique ferait mentir la soustraction.
class _CollectionCard extends StatelessWidget {
  final CashCollectionEntry entry;
  /// `driver`, `fleet` ou `merchant`. Un booléen ne suffisait pas : le net
  /// d'un encaissement **revient** au commerçant, il ne fait que **transiter**
  /// par l'entreprise qui a facilité la course.
  final String persona;

  const _CollectionCard({required this.entry, required this.persona});

  bool get isDriver => persona == 'driver';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = context.watch<LocaleState>().locale;
    String t(String key, [Map<String, String>? vars]) =>
        cashLabel(key, locale, vars);
    String money(double amount) =>
        '${amount.toStringAsFixed(0)} ${entry.currency}'.trim();

    return AppSectionCard.dense(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  // « 2026-07-31 » était un format ISO au milieu d'un écran
                  // en jj/MM/aaaa.
                  formatDay(entry.collectedAt),
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  money(entry.collectedAmount),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _line(theme, t('cash.line.collected'), money(entry.collectedAmount)),
            if (entry.retainedAmount > 0)
              _line(
                theme,
                t(isDriver
                    ? 'cash.line.retained.driver'
                    : 'cash.line.retained.other'),
                '− ${money(entry.retainedAmount)}',
              ),
            _line(
              theme,
              t(switch (persona) {
                'driver' => 'cash.line.net.driver',
                'fleet' => 'cash.line.net.fleet',
                _ => 'cash.line.net.merchant',
              }),
              money(entry.netAmount),
              strong: true,
            ),
            // ⚠️ L'écart n'est signalé QUE s'il existe : un motif affiché sur
            // une ligne conforme se lirait comme un incident.
            if (entry.hasDiscrepancy) ...[
              const SizedBox(height: 6),
              Text(
                t('cash.discrepancy.line', {
                  'reason': cashDiscrepancyLabel(
                      entry.discrepancyReason, locale,
                      fallback: t('cash.discrepancy.default')),
                  'amount': money(entry.expectedAmount),
                }),
                style: TextStyle(
                  color: context.semantic.onWarningContainer,
                  fontSize: 12,
                ),
              ),
              if (entry.notes != null && entry.notes!.isNotEmpty)
                Text(entry.notes!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
    );
  }

  Widget _line(ThemeData theme, String label, String value, {bool strong = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: strong ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      );
}

/// Une livraison dont l'argent sera réclamé à une porte.
///
/// Volontairement plus sobre qu'une ligne d'encaissement : rien ici n'est un
/// fait comptable, et une carte aussi détaillée que celle du perçu laisserait
/// croire que la somme est acquise.
class _PendingCard extends StatelessWidget {
  final PendingCollection entry;
  final String currency;

  /// Livraison terminée sans encaissement déclaré. Change les mots, pas la
  /// forme : c'est le même objet, mais il ne demande pas la même chose.
  final bool isAnomaly;

  /// Ouvre la déclaration. Nul sur une livraison en cours : il n'y a rien à
  /// régulariser tant que personne n'est passé à la porte.
  final VoidCallback? onRegularise;

  const _PendingCard({
    required this.entry,
    required this.currency,
    this.isAnomaly = false,
    this.onRegularise,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = context.watch<LocaleState>().locale;
    String t(String key, [Map<String, String>? vars]) =>
        cashLabel(key, locale, vars);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      color: isAnomaly ? context.semantic.warningContainer : null,
      child: ListTile(
        leading: Icon(
          isAnomaly
              ? Icons.help_outline
              : entry.isUnderway
                  ? Icons.local_shipping_outlined
                  : Icons.search,
          color: isAnomaly
              ? context.semantic.warning
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(entry.dropoffName ?? t('cash.pending.delivery')),
        subtitle: Text(
          isAnomaly
              // Pas le statut ici : « Livrée » est vrai mais ne dit pas ce qui
              // manque, et c'est ce qui manque qui appelle une action.
              ? entry.driverName != null
                  ? t('cash.pending.anomaly.named', {'name': entry.driverName!})
                  : t('cash.pending.anomaly.anon')
              : [
                  // Le libellé vient de la table partagée : deux écrans ne
                  // doivent pas nommer différemment le même statut (règle 4).
                  orderStatusLabel(entry.status ?? '', locale,
                      driverName: entry.driverName),
                  if (entry.driverName != null) entry.driverName!,
                ].join(' · '),
        ),
        trailing: Text(
          '${entry.expectedAmount.toStringAsFixed(0)} $currency',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            // Gris et non vert : cet argent n'est pas encore là — et sur une
            // anomalie, on ignore même s'il a été perçu.
            color: isAnomaly
                ? context.semantic.onWarningContainer
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        // Le geste vit sur la ligne et non dans la bannière : chaque livraison
        // se régularise avec son propre montant, et un bouton global aurait
        // demandé un chiffre pour deux courses différentes.
        onTap: onRegularise,
      ),
    );
  }
}

/// Encaissement que le commerçant a déclaré à la place du transporteur.
///
/// Les deux montants sont montrés côte à côte : ce qui était annoncé, et ce que
/// le commerçant affirme. Confirmer, c'est accepter une dette — le transporteur
/// doit voir sur quoi il s'engage, pas seulement un chiffre.
class _CollectionToConfirmCard extends StatelessWidget {
  final CashCollectionEntry entry;
  final VoidCallback onConfirm;
  final VoidCallback onDispute;

  const _CollectionToConfirmCard({
    required this.entry,
    required this.onConfirm,
    required this.onDispute,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = context.watch<LocaleState>().locale;
    String t(String key, [Map<String, String>? vars]) =>
        cashLabel(key, locale, vars);
    String money(double amount) =>
        '${amount.toStringAsFixed(0)} ${entry.currency}'.trim();

    return AppSectionCard.dense(
      color: context.semantic.warningContainer,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('cash.to_confirm.title', {
                'amount': money(entry.collectedAmount),
              }),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              t('cash.to_confirm.expected',
                      {'amount': money(entry.expectedAmount)}) +
                  (entry.hasDiscrepancy
                      ? t('cash.to_confirm.discrepancy', {
                          'reason': cashDiscrepancyLabel(
                              entry.discrepancyReason, locale,
                              fallback: ''),
                        })
                      : ''),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              t('cash.to_confirm.note'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: onDispute,
                    child: Text(t('cash.action.dispute'))),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                    onPressed: onConfirm,
                    child: Text(t('cash.action.confirm'))),
              ],
            ),
          ],
        ),
    );
  }
}

/// Explique l'anomalie plutôt que d'afficher un chiffre orange sans raison.
///
/// Le montant annoncé n'est PAS présenté comme dû : nous ignorons ce qui a
/// réellement changé de mains à la porte. Écrire « on vous doit 5972 DZD »
/// serait inventer une dette ; écrire 0, comme avant, c'était nier la
/// livraison. Le seul énoncé vrai est « ces livraisons sont faites et rien
/// n'est enregistré ».
class _UnrecordedBanner extends StatelessWidget {
  final double total;
  final int count;
  final String currency;

  const _UnrecordedBanner({
    required this.total,
    required this.count,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = context.watch<LocaleState>().locale;
    String t(String key, [Map<String, String>? vars]) =>
        cashLabel(key, locale, vars);

    return AppSectionCard(
      color: context.semantic.warningContainer,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.report_problem_outlined,
                    color: context.semantic.onWarningContainer),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    t(
                      count > 1
                          ? 'cash.unrecorded.title.many'
                          : 'cash.unrecorded.title.one',
                      {'count': '$count'},
                    ),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              t('cash.unrecorded.body', {
                'amount': total.toStringAsFixed(0),
                'currency': currency,
              }),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
    );
  }
}

/// Choisit le transporteur d'une course qui n'en désigne aucun.
///
/// ── Une recherche, pas un annuaire ──────────────────────────────────────────
///
/// Même règle que l'ajout d'un favori : le serveur refuse d'énumérer le réseau
/// et demande de préciser au-delà de dix correspondances. Le commerçant tape le
/// nom de celui qui est venu — il le connaît, c'est lui qui lui a remis le
/// colis.
///
/// ── Pourquoi les comptes absents sont montrés mais non choisissables ────────
///
/// Un transporteur peut figurer dans l'annuaire Fleetbase sans avoir créé son
/// compte dans l'application. Il ne peut alors **rien confirmer**, et
/// l'encaissement resterait une affirmation pour toujours. Le masquer ferait
/// croire qu'il n'existe pas et enverrait chercher ailleurs ; le montrer grisé,
/// avec le motif, désigne l'action qui débloque — un geste d'opérateur.
class _DriverPickerDialog extends StatefulWidget {
  const _DriverPickerDialog();

  @override
  State<_DriverPickerDialog> createState() => _DriverPickerDialogState();
}

class _DriverPickerDialogState extends State<_DriverPickerDialog> {
  final _controller = TextEditingController();
  List<KnownDriver> _results = const [];
  bool _searching = false;
  bool _tooMany = false;

  /// ⚠️ La **clé**, pas le message. Elle est posée dans un `catch`, donc hors
  /// de toute phase de build : y traduire imposerait un `read` de la locale au
  /// pire endroit, et surtout figerait la langue au moment de l'échec — un
  /// changement de langue laisserait le message précédent à l'écran.
  String? _errorKey;
  bool _searched = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    // ⚠️ **Valait 2, alors que le serveur exige 3.**
    //
    // Une saisie de deux caractères passait donc cette garde et se faisait
    // refuser par le serveur : l'utilisateur voyait une erreur de validation sur
    // une recherche que l'application venait d'accepter. Trois écrans
    // reproduisaient cette règle, et celui-ci était le seul à se tromper —
    // corrigé le 31/07/2026 en instruisant le chantier des valeurs.
    if (query.length < ServerRules.driverSearchMinLength) return;

    setState(() {
      _searching = true;
      _errorKey = null;
    });

    try {
      final result = await context.read<CashState>().searchDrivers(query);
      if (!mounted) return;
      setState(() {
        _results = result.drivers;
        _tooMany = result.tooMany;
        _searched = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorKey = 'cash.picker.failed');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = context.watch<LocaleState>().locale;
    String t(String key) => cashLabel(key, locale);

    return AlertDialog(
      title: Text(t('cash.picker.title')),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('cash.picker.hint'), style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: t('cash.picker.field'),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _searching ? null : _search,
                ),
              ),
            ),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_errorKey != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md),
                child: Text(t(_errorKey!),
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (_tooMany)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md),
                child: Text(
                  t('cash.picker.too_many'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (_searched && !_searching && _results.isEmpty && !_tooMany)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md),
                child: Text(
                  t('cash.picker.none'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final d in _results)
                    ListTile(
                      enabled: d.hasAccount,
                      leading: Icon(
                        d.hasAccount ? Icons.person : Icons.person_off_outlined,
                      ),
                      title: Text(d.name ?? t('cash.picker.driver')),
                      subtitle: d.hasAccount
                          ? null
                          : Text(t('cash.picker.no_account')),
                      onTap: d.hasAccount
                          ? () => Navigator.pop(context, d.driverUuid)
                          : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('cash.action.cancel')),
        ),
      ],
    );
  }
}
