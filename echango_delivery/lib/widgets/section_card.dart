import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// Bloc encadré d'un écran : une carte et son remplissage interne.
///
/// ── Ce qu'il apporte, et ce qu'il n'apporte pas ──────────────────────────
///
/// ⚠️ **Contrairement aux trois autres composants partagés, celui-ci ne corrige
/// aucun défaut.** `AppErrorBanner`, `AppEmptyState` et `showAppOutcome` ont
/// chacun fermé un bug réel en étant extraits — un refus affiché comme une
/// confirmation, une liste inconnue affirmée vide, une absence sans consigne.
/// Ici il n'y a rien de tel : `Card(child: Padding(...))` était juste écrit
/// dix-huit fois.
///
/// Ce qu'il apporte est plus modeste et vaut d'être dit exactement : **il nomme
/// les deux densités** que le code employait sans les distinguer. Mesuré le
/// 31/07/2026 sur `lib/screens/` — 14 cartes à `AppSpacing.lg`, 4 à
/// `AppSpacing.md`, toutes les secondes dans l'écran de caisse. Personne
/// n'avait décidé qu'une carte de caisse serait plus dense qu'une carte de
/// livraison ; c'est ce que produit la recopie. Maintenant c'est un nom, donc
/// une décision qu'on peut discuter.
///
/// ── Pourquoi pas de `padding` paramétrable ───────────────────────────────
///
/// Un troisième remplissage libre rouvrirait exactement ce qu'on vient de
/// fermer. Les deux cas hors barème restants (`xl` sur la carte de profil,
/// `symmetric` sur un formulaire) gardent leur `Card` littérale : ce sont des
/// exceptions assumées, et les faire entrer ici par un paramètre les rendrait
/// invisibles.
class AppSectionCard extends StatelessWidget {
  /// Bloc de plein format — l'immense majorité des cas.
  const AppSectionCard({
    super.key,
    required this.child,
    this.color,
    this.margin,
  }) : _padding = AppSpacing.lg;

  /// Bloc dense, pour une ligne d'une liste plutôt que pour une section.
  const AppSectionCard.dense({
    super.key,
    required this.child,
    this.color,
    this.margin,
  }) : _padding = AppSpacing.md;

  final Widget child;

  /// Fond. Doit venir du thème (`colorScheme` ou `context.semantic`) — un
  /// `Colors.*` ici annulerait le lot qui vient de les retirer.
  final Color? color;

  final EdgeInsetsGeometry? margin;

  final double _padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      margin: margin,
      child: Padding(
        padding: EdgeInsets.all(_padding),
        child: child,
      ),
    );
  }
}
