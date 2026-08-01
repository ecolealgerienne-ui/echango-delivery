import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/common_strings.dart';
import '../state/locale_state.dart';

import '../theme/app_spacing.dart';

/// Absence de contenu, **avec sa consigne**.
///
/// ── La première règle : une liste vide sans explication se lit comme une
/// panne ───────────────────────────────────────────────────────────────────
///
/// [hint] est **obligatoire**, et c'est le seul moyen de tenir la règle : un
/// paramètre facultatif est un paramètre qu'on oublie, et le compilateur ne
/// dirait rien. C'est le défaut des deux impasses d'écran corrigées le
/// 29/07/2026 — « Mes transporteurs » affichait une page vide sans aucun moyen
/// d'en trouver un, et le carnet d'adresses vide ne disait pas à quoi il
/// servirait. Dans les deux cas l'utilisateur concluait que l'application était
/// cassée.
///
/// ── La seconde règle, plus coûteuse : ne dire « aucun » que si c'est vrai ──
///
/// `FleetState.load()` avale l'échec de `getFleetDrivers()` par un `catchError`
/// qui rend une liste vide : un BFF injoignable devenait **indiscernable**
/// d'une entreprise sans conducteur. On affirmait un fait possiblement faux au
/// moment précis où l'entreprise veut agir.
///
/// D'où [AppEmptyState.unavailable] : un constructeur distinct, pour que la
/// question « est-ce vide, ou est-ce que je n'ai pas pu savoir ? » se pose à
/// l'écriture. Un écran qui n'a pas de réponse à cette question a un défaut,
/// pas un état vide.
///
/// ── Défilable, sinon « tirer pour recharger » ne marche pas ───────────────
///
/// Le contenu est rendu dans un [ListView] : `RefreshIndicator` exige un enfant
/// défilable pour capter le geste, et sans lui tirer vers le bas ne déclenche
/// rien — précisément dans le cas où l'on veut recharger. L'appelant peut
/// désactiver ce comportement avec `scrollable: false` quand il est déjà dans
/// une liste.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.title,
    required this.hint,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.scrollable = true,
  })  : _unavailable = false,
        onRetry = null;

  /// L'information n'a **pas pu être obtenue** — ce n'est pas un état vide.
  ///
  /// Rendu différemment (icône, ton) et porteur d'une reprise, parce que
  /// l'action utile n'est pas la même : sur un vide réel on crée, sur une
  /// indisponibilité on réessaie.
  const AppEmptyState.unavailable({
    super.key,
    required this.title,
    required this.hint,
    this.onRetry,
    this.scrollable = true,
  })  : icon = Icons.cloud_off_outlined,
        action = null,
        _unavailable = true;

  /// Ce qui est absent, en une ligne. Déjà traduit par l'appelant.
  final String title;

  /// **Obligatoire** : ce que l'utilisateur peut faire, ou pourquoi c'est vide.
  /// Voir l'en-tête — c'est la règle que ce widget existe pour tenir.
  final String hint;

  final IconData icon;

  /// Bouton d'action sur un vide réel (« Ajouter une adresse »).
  final Widget? action;

  /// Bouton de reprise sur une indisponibilité.
  final VoidCallback? onRetry;

  /// Faux quand l'appelant place déjà ce widget dans une liste défilable.
  final bool scrollable;

  final bool _unavailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = _unavailable
        ? theme.colorScheme.error
        : theme.colorScheme.outline;

    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 64, color: tone),
        const SizedBox(height: AppSpacing.lg),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          hint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        if (action != null) ...[
          const SizedBox(height: AppSpacing.lg),
          action!,
        ],
        if (onRetry != null) ...[
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(commonLabel(
                'common.retry', context.read<LocaleState>().locale)),
          ),
        ],
      ],
    );

    if (!scrollable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: content,
        ),
      );
    }

    return ListView(
      // Sans cette physique, une liste vide ne capte pas le geste de
      // rechargement — voir l'en-tête.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.xxl),
      children: [
        const SizedBox(height: 48),
        content,
      ],
    );
  }
}
