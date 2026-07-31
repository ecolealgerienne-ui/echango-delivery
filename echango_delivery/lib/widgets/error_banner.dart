import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// Bandeau d'erreur, posé **au-dessus** du contenu et jamais à sa place.
///
/// ── La règle qu'il transporte, et pourquoi elle compte ────────────────────
///
/// Un rechargement raté ne doit pas effacer ce qui était lisible. Remplacer la
/// liste par un message d'erreur retire à l'utilisateur les informations qu'il
/// avait déjà — au moment précis où il n'en obtiendra pas de nouvelles. Le
/// bandeau se pose donc en tête de colonne, le contenu reste dessous.
///
/// C'est une règle métier, pas une mise en page : la recopier sans elle
/// reproduirait le défaut qu'elle corrige, déjà corrigé deux fois dans ce
/// projet.
///
/// ── Pourquoi un widget, et pas sept copies ───────────────────────────────
///
/// Mesuré le 31/07/2026 : sept bandeaux, **quatre mises en page différentes**,
/// dont trois peignant leur propre rouge (`Colors.red.shade50`, bordure rouge,
/// texte `red.shade700`) et quatre passant par le thème. Le même événement —
/// « le serveur a refusé » — se présentait donc de quatre façons selon l'écran
/// atteint. Personne ne l'avait décidé ; c'est ce que produit la recopie.
///
/// La couleur vient de `colorScheme.errorContainer` : un `Colors.red` en dur ne
/// suit pas un changement de thème, et c'est ce que la règle 6 interdit.
class AppErrorBanner extends StatelessWidget {
  const AppErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel,
  });

  /// Le message déjà traduit. Le bandeau n'appelle pas le traducteur lui-même :
  /// les écrans n'ont pas tous la même source d'erreur (`AuthState`,
  /// `OrderState`, `FleetState`…) et savent, eux, laquelle lire.
  final String message;

  /// Action de reprise. Absente, aucun bouton n'est affiché — proposer
  /// « Réessayer » là où rien ne se recharge serait une promesse vide.
  final VoidCallback? onRetry;

  /// Libellé du bouton, traduit par l'appelant pour la même raison que
  /// [message].
  final String? retryLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              onPressed: onRetry,
              child: Text(
                retryLabel ?? 'Réessayer',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
