import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/cash.dart';
// Pour `orderStatusLabel` : le libellé d'un statut vit à un seul endroit
// (règle 4 du projet), même quand l'écran ne manipule pas de `MerchantOrder`.
import '../../models/merchant_order.dart' show KnownDriver, orderStatusLabel;
import '../../services/navigation_launcher.dart';
import '../../state/cash_state.dart';
import '../../config/app_rules.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_banner.dart';
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

    return Scaffold(
      appBar: AppBar(
        title: Text(_isDriver ? 'Ma caisse' : 'Encaissements'),
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
            _totalCard(state),
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
              _sectionTitle('Encaissements à confirmer'),
              for (final c in state.collectionsToConfirm)
                _CollectionToConfirmCard(
                  entry: c,
                  onConfirm: () => _confirmCollection(state, c),
                  onDispute: () => _disputeCollection(state, c),
                ),
              const SizedBox(height: AppSpacing.lg),
            ],

            if (state.awaitingMyConfirmation.isNotEmpty) ...[
              _sectionTitle('À confirmer'),
              for (final r in state.awaitingMyConfirmation)
                _PendingRemittanceCard(
                  remittance: r,
                  isDriver: _isDriver,
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

            _sectionTitle(_isDriver ? 'Mes comptes' : 'Mes transporteurs'),
            if (state.isLoading && state.ledger == null)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.xxl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (state.ledger?.isEmpty ?? true)
              _empty(
                hasPending: state.pending.isNotEmpty,
                hasUnrecorded: state.unrecorded.isNotEmpty,
              )
            else
              for (final balance in state.ledger!.balances)
                _BalanceCard(
                  balance: balance,
                  currency: state.currency,
                  isDriver: _isDriver,
                  onDeclare: () => _declare(state, balance),
                ),

            // L'attendu vient après les soldes et avant le détail du perçu :
            // c'est l'ordre du temps. Ce qu'on détient, ce qui va venir, puis
            // d'où venait ce qu'on détient.
            if (state.pending.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _sectionTitle('En cours — pas encore encaissé'),
              for (final p in state.pending)
                _PendingCard(entry: p, currency: state.currency),
            ],

            // Le détail vient APRÈS les soldes, et c'est délibéré : on lit
            // d'abord combien, ensuite d'où ça vient. L'inverse noierait le
            // chiffre qui intéresse dans une liste de lignes.
            if (state.collections.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _sectionTitle('Détail des encaissements'),
              for (final c in state.collections.take(AppRules.cashCollectionsPreview))
                _CollectionCard(entry: c, isDriver: _isDriver),
              if (state.collections.length > AppRules.cashCollectionsPreview)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    // ⚠️ Le nombre était écrit en dur ICI AUSSI. Trois
                    // occurrences du même 20 dans le même bloc : en changer une
                    // seule aurait fait mentir l'écran — vingt-cinq lignes sous
                    // un titre en annonçant vingt.
                    '${AppRules.cashCollectionsPreview} dernières livraisons '
                    'encaissées sur ${state.collections.length}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],

            if (state.awaitingOther.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _sectionTitle('En attente de l\'autre partie'),
              for (final r in state.awaitingOther)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.hourglass_empty),
                    title: Text(r.formattedAmount),
                    subtitle: Text(
                      _isDriver
                          ? 'Le commerçant n\'a pas encore confirmé la réception.'
                          : 'Le transporteur n\'a pas encore confirmé.',
                    ),
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

  Widget _totalCard(CashState state) {
    final theme = Theme.of(context);
    return AppSectionCard(
  color: _isDriver
          ? context.semantic.warningContainer
          : context.semantic.successContainer,
  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isDriver
                  ? 'Espèces que vous détenez'
                  : 'Espèces encaissées pour vous',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${state.total.toStringAsFixed(0)} ${state.currency}',
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              // Dire que ce total ne se règle pas d'un coup : il est dû à
              // plusieurs personnes, et c'est le point qui distingue ce modèle
              // d'un compte chez un transporteur classique.
              _isDriver
                  ? 'Votre rémunération est déjà déduite. Le reste est à remettre '
                      'à chaque commerçant lors de votre prochain enlèvement chez '
                      'lui. Echango ne détient jamais cet argent.'
                  : 'Détenues par vos transporteurs, rémunération déduite, '
                      'jusqu\'à leur prochain passage. Echango ne détient jamais '
                      'cet argent.',
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
                'À encaisser aux portes : '
                '${state.expectedTotal.toStringAsFixed(0)} ${state.currency}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${state.pending.length} livraison'
                '${state.pending.length > 1 ? 's' : ''} en cours. '
                'Cet argent n\'a pas encore été perçu.',
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
                'Commission Echango cumulée : '
                '${state.ledger!.platformCommission!.toStringAsFixed(0)} '
                '${state.currency}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Déjà prélevée sur vos courses. Facturée séparément par Echango, '
                'pas depuis cette application.',
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
  Widget _empty({bool hasPending = false, bool hasUnrecorded = false}) {
    // ⚠️ L'ordre des cas compte : avec une anomalie au-dessus, « aucune somme
    // en attente » contredirait la bannière qui vient d'annoncer des
    // livraisons non enregistrées.
    final (String title, String hint) = _isDriver
        ? (
            'Vous ne détenez aucune somme',
            'Les encaissements que vous déclarez à la livraison apparaîtront '
                'ici, avec ce que vous devez à chaque commerçant.',
          )
        : hasUnrecorded
            ? (
                'Aucun solde ouvert',
                'Mais des livraisons closes hors application n\'ont laissé '
                    'aucun encaissement : régularisez-les depuis l\'alerte '
                    'ci-dessus.',
              )
            : hasPending
                ? (
                    'Rien à récupérer pour l\'instant',
                    'Les livraisons en cours ne sont pas encore encaissées : '
                        'la somme apparaîtra à la remise du colis.',
                  )
                : (
                    'Aucune somme en attente',
                    'Vous verrez ici ce que chaque transporteur vous doit, dès '
                        'qu\'une livraison sera encaissée à la porte.',
                  );

    return AppEmptyState(
      title: title,
      hint: hint,
      icon: hasPending ? Icons.schedule_outlined : Icons.payments_outlined,
      // Déjà dans un `ListView` : une seconde liste imbriquée ne défilerait pas.
      scrollable: false,
    );
  }

  Future<void> _declare(CashState state, CashBalance balance) async {
    final amount = await showDialog<double>(
      context: context,
      builder: (_) => _AmountDialog(
        title: 'Enregistrer un versement',
        subtitle: 'Avec ${balance.displayName}. '
            'La somme ne sera déduite qu\'après confirmation par l\'autre partie.',
        maximum: balance.outstanding,
        currency: state.currency,
      ),
    );

    if (amount == null || !mounted) return;

    final ok = await state.declareRemittance(balance.counterpartyId, amount);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? 'Déclaration impossible',
      'Remise déclarée. Elle sera déduite après confirmation.',
    );
  }

  Future<void> _confirm(CashState state, CashRemittance r) async {
    final ok = await state.confirmRemittance(r.id);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? 'Confirmation impossible',
      'Remise confirmée — ${r.formattedAmount} déduits.',
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
        title: 'Déclarer l\'encaissement',
        subtitle: p.driverName != null
            ? '${p.driverName} a encaissé combien sur cette livraison ? '
                'Il devra confirmer avant que la somme ne soit comptée.'
            : 'Combien a été encaissé sur cette livraison ? '
                'Le transporteur devra confirmer avant que la somme ne soit comptée.',
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
          title: const Text('Pourquoi ce montant diffère ?'),
          children: [
            for (final entry in cashDiscrepancyLabels.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, entry.key),
                child: Text(entry.value),
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
      ok ? null : state.errorMessage ?? 'Déclaration impossible',
      'Déclaré. En attente de confirmation du transporteur.',
    );
  }

  Future<void> _confirmCollection(CashState state, CashCollectionEntry c) async {
    final ok = await state.confirmCollection(c.id);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? 'Confirmation impossible',
      'Encaissement confirmé — il entre dans votre caisse.',
    );
  }

  Future<void> _disputeCollection(CashState state, CashCollectionEntry c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Contester cet encaissement ?'),
        content: Text(
          'Vous déclarez ne pas avoir encaissé '
          '${c.collectedAmount.toStringAsFixed(0)} ${c.currency} sur cette '
          'livraison. Rien ne sera compté et Echango sera alerté.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Retour'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Contester'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final ok = await state.disputeCollection(c.id);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? 'Contestation impossible',
      'Encaissement contesté.',
    );
  }

  Future<void> _dispute(CashState state, CashRemittance r) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Contester cette remise ?'),
        content: Text(
          'Vous déclarez ne pas avoir reçu ${r.formattedAmount}. '
          'La somme reste due et Echango sera alerté.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Retour'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Contester'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final ok = await state.disputeRemittance(r.id);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : state.errorMessage ?? 'Contestation impossible',
      'Remise contestée. La somme reste due.',
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final CashBalance balance;
  final String currency;
  final bool isDriver;
  final VoidCallback onDeclare;

  const _BalanceCard({
    required this.balance,
    required this.currency,
    required this.isDriver,
    required this.onDeclare,
  });

  /// Qui doit à qui, en toutes lettres. Un montant nu sur un solde signé se
  /// lit dans le mauvais sens une fois sur deux.
  String _sense(CashBalance balance) {
    if (balance.merchantOwes) {
      return isDriver
          ? 'Ce commerçant vous doit cette somme (course non couverte par '
              'l\'encaissement).'
          : 'Vous devez cette somme à ce transporteur.';
    }
    return isDriver
        ? 'Vous détenez cette somme pour ce commerçant.'
        : 'Détenue par ce transporteur.';
  }

  @override
  Widget build(BuildContext context) {
    return AppSectionCard.dense(
  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    balance.displayName,
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
                        color: balance.merchantOwes
                            ? context.semantic.success
                            : null,
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
                          ? 'Plafond atteint : plus de course encaissée pour ce '
                              'commerçant avant votre remise.'
                          : 'Plafond atteint pour ce transporteur.',
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
              _sense(balance),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                if (balance.phone != null)
                  TextButton.icon(
                    onPressed: () => NavigationLauncher.call(balance.phone!),
                    icon: const Icon(Icons.phone, size: 18),
                    label: const Text('Appeler'),
                  ),
                const Spacer(),
                FilledButton.tonal(
                  onPressed: onDeclare,
                  // Le libellé suit le sens réel du versement, pas le profil :
                  // un transporteur à qui le commerçant doit de l'argent
                  // *reçoit*, il ne remet pas.
                  child: Text(
                    balance.driverOwes
                        ? (isDriver ? 'J\'ai remis' : 'J\'ai reçu')
                        : (isDriver ? 'J\'ai reçu' : 'J\'ai versé'),
                  ),
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
  final bool isDriver;
  final VoidCallback onConfirm;
  final VoidCallback onDispute;

  const _PendingRemittanceCard({
    required this.remittance,
    required this.isDriver,
    required this.onConfirm,
    required this.onDispute,
  });

  @override
  Widget build(BuildContext context) {
    return AppSectionCard.dense(
  color: context.semantic.warningContainer,
  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(remittance.formattedAmount,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              isDriver
                  ? 'Le commerçant déclare vous avoir remis cette somme.'
                  : 'Le transporteur déclare vous avoir remis cette somme.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                TextButton(
                  onPressed: onDispute,
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('Je n\'ai rien reçu'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: onConfirm,
                  child: const Text('Confirmer'),
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
              labelText: 'Montant (${widget.currency})',
              border: const OutlineInputBorder(),
              helperText: 'Maximum ${widget.maximum.toStringAsFixed(0)}',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _value == null ? null : () => Navigator.pop(context, _value),
          child: const Text('Valider'),
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
  final bool isDriver;

  const _CollectionCard({required this.entry, required this.isDriver});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  entry.collectedAt.toLocal().toString().split(' ')[0],
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  money(entry.collectedAmount),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _line(theme, 'Perçu du destinataire', money(entry.collectedAmount)),
            if (entry.retainedAmount > 0)
              _line(
                theme,
                isDriver ? 'Votre rémunération retenue' : 'Retenu par le transporteur',
                '− ${money(entry.retainedAmount)}',
              ),
            _line(
              theme,
              isDriver ? 'Reste à remettre' : 'Vous revient',
              money(entry.netAmount),
              strong: true,
            ),
            // ⚠️ L'écart n'est signalé QUE s'il existe : un motif affiché sur
            // une ligne conforme se lirait comme un incident.
            if (entry.hasDiscrepancy) ...[
              const SizedBox(height: 6),
              Text(
                '${cashDiscrepancyLabels[entry.discrepancyReason] ?? entry.discrepancyReason ?? 'Écart signalé'}'
                ' — ${money(entry.expectedAmount)} étaient attendus.',
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
        title: Text(entry.dropoffName ?? 'Livraison'),
        subtitle: Text(
          isAnomaly
              // Pas le statut ici : « Livrée » est vrai mais ne dit pas ce qui
              // manque, et c'est ce qui manque qui appelle une action.
              ? entry.driverName != null
                  ? 'Livrée par ${entry.driverName} · encaissement non déclaré'
                  : 'Livrée · encaissement non déclaré'
              : [
                  // Le libellé vient de la table partagée : deux écrans ne
                  // doivent pas nommer différemment le même statut (règle 4).
                  orderStatusLabel(entry.status ?? '', driverName: entry.driverName),
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
    String money(double amount) =>
        '${amount.toStringAsFixed(0)} ${entry.currency}'.trim();

    return AppSectionCard.dense(
  color: context.semantic.warningContainer,
  margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Le commerçant déclare que vous avez encaissé '
              '${money(entry.collectedAmount)}',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Montant annoncé sur la livraison : ${money(entry.expectedAmount)}.'
              '${entry.hasDiscrepancy ? ' Écart déclaré : '
                  '${cashDiscrepancyLabels[entry.discrepancyReason] ?? entry.discrepancyReason ?? ''}.' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Tant que vous n\'avez pas confirmé, cette somme n\'entre dans '
              'aucun compte.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onDispute, child: const Text('Contester')),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(onPressed: onConfirm, child: const Text('Confirmer')),
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
                    '$count livraison${count > 1 ? 's' : ''} '
                    'sans encaissement enregistré',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Montant annoncé : ${total.toStringAsFixed(0)} $currency. '
              'La livraison est terminée, mais le transporteur n\'a pas déclaré '
              'ce qu\'il a encaissé — cela arrive quand la course est clôturée '
              'depuis l\'administration et non depuis son application. '
              'Contactez-le pour régulariser.',
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
  String? _error;
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
      _error = null;
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
      setState(() => _error = 'Recherche impossible');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Qui a effectué cette livraison ?'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cette livraison ne désigne aucun transporteur. '
              'Cherchez-le par son nom ou son téléphone.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: 'Nom ou téléphone',
                border: const OutlineInputBorder(),
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (_tooMany)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md),
                child: Text(
                  'Trop de correspondances — précisez le nom.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (_searched && !_searching && _results.isEmpty && !_tooMany)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md),
                child: Text(
                  'Aucun transporteur trouvé.',
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
                      title: Text(d.name ?? 'Transporteur'),
                      subtitle: d.hasAccount
                          ? null
                          : const Text(
                              'Pas de compte dans l\'application : '
                              'il ne pourrait rien confirmer',
                            ),
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
          child: const Text('Annuler'),
        ),
      ],
    );
  }
}
