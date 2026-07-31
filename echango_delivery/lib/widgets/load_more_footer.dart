import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// Le pied de liste qui charge la page suivante.
///
/// ── Ce qu'il porte avec lui (règle 6) ─────────────────────────────────────
///
/// Un composant partagé porte sa règle métier, sinon le recopier reproduit le
/// défaut qu'il corrigeait. Ici : **il ne s'affiche que s'il reste vraiment
/// quelque chose**, et c'est à l'appelant de ne le construire que dans ce cas —
/// d'où l'absence de tout repli « au cas où » ici. Un bouton « charger plus »
/// qui ne rapporte rien se lit comme une panne.
///
/// Et pendant le chargement il **remplace** le bouton plutôt que de s'ajouter à
/// lui : deux appuis pendant la même requête demanderaient deux fois la même
/// page, qui s'ajouterait deux fois à la liste.
class AppLoadMore extends StatelessWidget {
  const AppLoadMore({
    super.key,
    required this.isLoading,
    required this.label,
    required this.onPressed,
  });

  final bool isLoading;

  /// Le libellé vient de l'appelant : « livraisons précédentes » chez le
  /// commerçant, « courses précédentes » chez l'entreprise. C'est la même
  /// mécanique et deux vocabulaires — le partage porte le geste, pas le mot.
  final String label;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: isLoading
            ? const CircularProgressIndicator()
            : OutlinedButton(onPressed: onPressed, child: Text(label)),
      ),
    );
  }
}
