import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/collections_strings.dart';
import '../../models/collections.dart';
import '../../state/collections_state.dart';
import '../../state/locale_state.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/dates.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/section_card.dart';

/// L'argent des commandes du commerçant, en lecture seule.
///
/// ── Ce que cet écran a remplacé ─────────────────────────────────────────────
///
/// `cash_screen.dart`, 1 399 lignes servant les trois profils : soldes, dettes,
/// remises, confirmations, contestations. Retiré le 03/08/2026 avec le registre
/// de caisse (`docs/registre_caisse_precis.md`). Tenir des soldes est de la
/// trésorerie, et détenir des fonds pour compte de tiers est une activité
/// réglementée qu'un agrégateur n'exerce pas.
///
/// ── Trois sections, trois questions ─────────────────────────────────────────
///
/// Ce ne sont pas trois filtres d'une même liste : en route / perçu / muet
/// répondent à trois questions différentes, et **seule la troisième appelle une
/// action** — celle-là, hors application.
///
/// ⚠️ **La phrase d'avertissement en tête n'est pas décorative.** Sans elle, un
/// commerçant peut croire que l'application suit ce qu'on lui doit, et attendre
/// d'elle un recouvrement qui n'existe pas. C'est exactement le risque que
/// `specs_paiement_livraison.md` nommait : une mise en œuvre partielle est pire
/// que l'absence, parce qu'on confie de l'argent réel à une capacité imaginaire.
class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({super.key});

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  @override
  void initState() {
    super.initState();
    // Après la première trame : `context.read` sur un provider n'est pas sûr
    // pendant `initState`.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<CollectionsState>().load(),
    );
  }

  String _t(String key, [Map<String, String>? vars]) =>
      collectionsLabel(key, context.read<LocaleState>().locale, vars);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CollectionsState>();
    final data = state.collections;

    return Scaffold(
      appBar: AppBar(title: Text(_t('collections.title'))),
      body: RefreshIndicator(
        onRefresh: () => context.read<CollectionsState>().load(),
        child: _body(context, state, data),
      ),
    );
  }

  Widget _body(BuildContext context, CollectionsState state, MerchantCollections? data) {
    // ⚠️ « Je n'ai pas pu savoir » n'est pas « rien à signaler » (règle 10).
    if (state.unavailable) {
      return AppEmptyState.unavailable(
        title: _t('collections.unavailable.title'),
        hint: _t('collections.unavailable.hint'),
        onRetry: () => context.read<CollectionsState>().load(),
      );
    }

    if (data == null && state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (data == null || data.isEmpty) {
      return AppEmptyState(
        title: _t('collections.empty.title'),
        hint: _t('collections.empty.hint'),
        icon: Icons.payments_outlined,
      );
    }

    final locale = context.read<LocaleState>().locale;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        // Le bandeau se pose AU-DESSUS de la liste et ne la remplace pas : un
        // rechargement raté ne doit pas effacer ce qui était lisible.
        if (state.errorMessage != null) ...[
          AppErrorBanner(
            message: state.errorMessage!,
            onRetry: () => context.read<CollectionsState>().load(),
          ),
          const SizedBox(height: AppSpacing.md),
        ],

        AppSectionCard(
          child: Text(
            _t('collections.disclaimer'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),

        // Les livraisons muettes en PREMIER : c'est la seule section qui
        // demande quelque chose au commerçant. La ranger en bas la rendrait
        // invisible, ce qui reviendrait à ne pas l'avoir.
        if (data.unrecorded.isNotEmpty)
          _Section(
            title: _t('collections.section.unrecorded'),
            total: _t('collections.total.unrecorded', {
              'amount': _amount(data.unrecordedTotal),
              'currency': data.currency ?? '',
            }),
            hint: _t('collections.hint.unrecorded'),
            tone: context.semantic.warningContainer,
            onTone: context.semantic.onWarningContainer,
            lines: data.unrecorded,
            locale: locale,
            label: _t,
          ),

        if (data.collected.isNotEmpty)
          _Section(
            title: _t('collections.section.collected'),
            total: _t('collections.total.collected', {
              'amount': _amount(data.collectedTotal),
              'currency': data.currency ?? '',
            }),
            hint: _t('collections.hint.collected'),
            tone: context.semantic.successContainer,
            onTone: context.semantic.onSuccessContainer,
            lines: data.collected,
            locale: locale,
            label: _t,
          ),

        if (data.expected.isNotEmpty)
          _Section(
            title: _t('collections.section.expected'),
            total: _t('collections.total.expected', {
              'amount': _amount(data.expectedTotal),
              'currency': data.currency ?? '',
            }),
            hint: _t('collections.hint.expected'),
            tone: Theme.of(context).colorScheme.surfaceContainerHighest,
            onTone: Theme.of(context).colorScheme.onSurfaceVariant,
            lines: data.expected,
            locale: locale,
            label: _t,
          ),
      ],
    );
  }
}

/// Un montant, ou rien.
///
/// ⚠️ Rendu `null`-tolérant délibérément : afficher `0` sur un montant absent
/// annoncerait une livraison gratuite. « — » dit qu'on ne sait pas.
String _amount(double? value) =>
    value == null ? '—' : value.toStringAsFixed(value % 1 == 0 ? 0 : 2);

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.total,
    required this.hint,
    required this.tone,
    required this.onTone,
    required this.lines,
    required this.locale,
    required this.label,
  });

  final String title;
  final String total;
  final String hint;
  final Color tone;
  final Color onTone;
  final List<CollectionLine> lines;
  final Locale locale;
  final String Function(String, [Map<String, String>?]) label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionCard(
            color: tone,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium?.copyWith(color: onTone)),
                const SizedBox(height: AppSpacing.xs),
                Text(total, style: theme.textTheme.titleLarge?.copyWith(color: onTone)),
                const SizedBox(height: AppSpacing.sm),
                Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: onTone)),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          ...lines.map((line) => _Line(line: line, locale: locale, label: label)),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.line, required this.locale, required this.label});

  final CollectionLine line;
  final Locale locale;
  final String Function(String, [Map<String, String>?]) label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // ⚠️ Jamais de repli sur l'uuid : afficher `order_1sn4fzn6e2` là où on
    // devrait dire « Livraison » est un repli qui ment poliment (règle 10).
    final heading = line.dropoffName?.trim().isNotEmpty == true
        ? line.dropoffName!
        : label('collections.line.delivery');

    final driver = line.driverName?.trim().isNotEmpty == true
        ? label('collections.line.driver', {'name': line.driverName!})
        : label('collections.line.driver.unknown');

    return AppSectionCard.dense(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            driver,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            label('collections.line.expected', {'amount': _amount(line.expectedAmount)}),
            style: theme.textTheme.bodyMedium,
          ),
          if (line.collectedAmount != null)
            Text(
              label('collections.line.collected', {'amount': _amount(line.collectedAmount)}),
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          if (line.collectedAt != null)
            Text(
              label('collections.line.collected.at', {
                'date': formatDayTime(line.collectedAt!, locale),
              }),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          if (line.hasDiscrepancy) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              // Zéro perçu et un écart partiel ne se disent pas pareil : « rien
              // n'a été perçu » est une information d'une autre nature qu'« il
              // manque 27 ».
              line.collectedAmount == 0
                  ? label('collections.line.nothing_collected', {'reason': _reason()})
                  : label('collections.line.discrepancy', {
                      'amount': _amount(line.expectedAmount! - line.collectedAmount!),
                      'reason': _reason(),
                    }),
              style: theme.textTheme.bodySmall?.copyWith(color: context.semantic.warning),
            ),
          ],
        ],
      ),
    );
  }

  /// Le motif, traduit depuis son code.
  ///
  /// Repli sur `autre` plutôt que sur le code brut : un code technique affiché
  /// à un commerçant ne lui apprend rien, et le serveur ne renvoie que des
  /// valeurs de la liste fermée — un inconnu signifie une version plus récente
  /// du serveur, pas une donnée absente.
  String _reason() {
    final code = line.collectionReason;
    if (code == null || code.isEmpty) return label('collections.reason.autre');
    final translated = label('collections.reason.$code');
    return translated == 'collections.reason.$code'
        ? label('collections.reason.autre')
        : translated;
  }
}
