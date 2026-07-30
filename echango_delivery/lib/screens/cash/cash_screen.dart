import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/cash.dart';
// Pour `orderStatusLabel` : le libellé d'un statut vit à un seul endroit
// (règle 4 du projet), même quand l'écran ne manipule pas de `MerchantOrder`.
import '../../models/merchant_order.dart' show orderStatusLabel;
import '../../services/navigation_launcher.dart';
import '../../state/cash_state.dart';

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
          padding: const EdgeInsets.all(16),
          children: [
            if (state.errorMessage != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(state.errorMessage!),
                ),
              ),
            _totalCard(state),
            const SizedBox(height: 16),

            // Ce qui appelle une action passe en premier. Une confirmation en
            // attente bloque une dette : la reléguer sous l'historique la ferait
            // oublier, et la dette resterait due alors que l'argent a changé de
            // mains.
            if (state.awaitingMyConfirmation.isNotEmpty) ...[
              _sectionTitle('À confirmer'),
              for (final r in state.awaitingMyConfirmation)
                _PendingRemittanceCard(
                  remittance: r,
                  isDriver: _isDriver,
                  onConfirm: () => _confirm(state, r),
                  onDispute: () => _dispute(state, r),
                ),
              const SizedBox(height: 16),
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
                _PendingCard(entry: p, currency: state.currency, isAnomaly: true),
              const SizedBox(height: 16),
            ],

            _sectionTitle(_isDriver ? 'Mes comptes' : 'Mes transporteurs'),
            if (state.isLoading && state.ledger == null)
              const Padding(
                padding: EdgeInsets.all(32),
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
              const SizedBox(height: 16),
              _sectionTitle('En cours — pas encore encaissé'),
              for (final p in state.pending)
                _PendingCard(entry: p, currency: state.currency),
            ],

            // Le détail vient APRÈS les soldes, et c'est délibéré : on lit
            // d'abord combien, ensuite d'où ça vient. L'inverse noierait le
            // chiffre qui intéresse dans une liste de lignes.
            if (state.collections.isNotEmpty) ...[
              const SizedBox(height: 16),
              _sectionTitle('Détail des encaissements'),
              for (final c in state.collections.take(20))
                _CollectionCard(entry: c, isDriver: _isDriver),
              if (state.collections.length > 20)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '20 dernières livraisons encaissées sur '
                    '${state.collections.length}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],

            if (state.awaitingOther.isNotEmpty) ...[
              const SizedBox(height: 16),
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
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _totalCard(CashState state) {
    final theme = Theme.of(context);
    return Card(
      color: _isDriver ? Colors.orange.shade50 : Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isDriver
                  ? 'Espèces que vous détenez'
                  : 'Espèces encaissées pour vous',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${state.total.toStringAsFixed(0)} ${state.currency}',
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
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
              const SizedBox(height: 4),
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
              const SizedBox(height: 4),
              Text(
                'Déjà prélevée sur vos courses. Facturée séparément par Echango, '
                'pas depuis cette application.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Aucun solde ouvert. [hasPending] change le texte du tout au tout.
  ///
  /// « Aucune somme en attente » était faux dès qu'une course encaissée était
  /// en route : rien n'était *détenu*, mais de l'argent était bel et bien
  /// attendu. C'est la formulation qui rassure à tort — celle qui coûte le plus
  /// cher, parce qu'on ne va pas vérifier ce qu'un écran déclare tranquille.
  Widget _empty({bool hasPending = false, bool hasUnrecorded = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Icon(
              hasPending ? Icons.schedule_outlined : Icons.payments_outlined,
              size: 56,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 12),
            Text(
              _isDriver
                  ? 'Vous ne détenez aucune somme'
                  // ⚠️ L'ordre des cas compte : avec une anomalie au-dessus,
                  // « aucune somme en attente » contredirait la bannière qui
                  // vient d'annoncer des livraisons non enregistrées.
                  : hasUnrecorded
                      ? 'Aucun solde ouvert — mais voir l\'alerte ci-dessus'
                      : hasPending
                          ? 'Rien à récupérer pour l\'instant :\n'
                              'les livraisons en cours ne sont pas encore encaissées'
                          : 'Aucune somme en attente',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );

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

    final messenger = ScaffoldMessenger.of(context);
    final ok = await state.declareRemittance(balance.counterpartyId, amount);
    if (!mounted) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Remise déclarée. Elle sera déduite après confirmation.'
            : state.errorMessage ?? 'Déclaration impossible'),
        backgroundColor: ok ? null : Colors.red,
      ),
    );
  }

  Future<void> _confirm(CashState state, CashRemittance r) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await state.confirmRemittance(r.id);
    if (!mounted) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Remise confirmée — ${r.formattedAmount} déduits.'
            : state.errorMessage ?? 'Confirmation impossible'),
        backgroundColor: ok ? null : Colors.red,
      ),
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

    final messenger = ScaffoldMessenger.of(context);
    final ok = await state.disputeRemittance(r.id);
    if (!mounted) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Remise contestée. La somme reste due.'
            : state.errorMessage ?? 'Contestation impossible'),
        backgroundColor: ok ? null : Colors.red,
      ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                            ? Colors.green.shade800
                            : null,
                      ),
                ),
              ],
            ),
            // Le blocage se dit, il ne se subit pas en silence : un transporteur
            // qui cesse de recevoir des courses encaissées sans savoir pourquoi
            // conclurait à une panne, ou à une mise à l'écart.
            if (balance.blocked) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.block, size: 16, color: Colors.red.shade700),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isDriver
                          ? 'Plafond atteint : plus de course encaissée pour ce '
                              'commerçant avant votre remise.'
                          : 'Plafond atteint pour ce transporteur.',
                      style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(
              _sense(balance),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
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
    return Card(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(remittance.formattedAmount,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              isDriver
                  ? 'Le commerçant déclare vous avoir remis cette somme.'
                  : 'Le transporteur déclare vous avoir remis cette somme.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: onDispute,
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
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

  const _AmountDialog({
    required this.title,
    required this.subtitle,
    required this.maximum,
    required this.currency,
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
    if (parsed == null || parsed <= 0 || parsed > widget.maximum) return null;
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
          const SizedBox(height: 16),
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

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                style: TextStyle(color: Colors.orange.shade900, fontSize: 12),
              ),
              if (entry.notes != null && entry.notes!.isNotEmpty)
                Text(entry.notes!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
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

  const _PendingCard({
    required this.entry,
    required this.currency,
    this.isAnomaly = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: isAnomaly ? Colors.orange.shade50 : null,
      child: ListTile(
        leading: Icon(
          isAnomaly
              ? Icons.help_outline
              : entry.isUnderway
                  ? Icons.local_shipping_outlined
                  : Icons.search,
          color: isAnomaly ? Colors.orange.shade800 : Colors.grey[600],
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
            color: isAnomaly ? Colors.orange.shade900 : Colors.grey[700],
          ),
        ),
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
    return Card(
      color: Colors.orange.shade100,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.report_problem_outlined, color: Colors.orange.shade900),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$count livraison${count > 1 ? 's' : ''} '
                    'sans encaissement enregistré',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
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
      ),
    );
  }
}
