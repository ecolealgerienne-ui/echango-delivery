import 'package:flutter/material.dart';
import 'app_semantic_colors.dart';
import 'app_spacing.dart';

/// La forme d'un bouton, décidée une fois pour les deux thèmes.
///
/// ⚠️ **Le thème sombre n'avait AUCUN style de bouton.** Le rayon et le
/// rembourrage n'étaient écrits que dans le thème clair : le même écran
/// affichait donc des boutons à coins arrondis en clair et des pilules
/// Material 3 en sombre. Personne ne l'avait vu parce que personne ne compare
/// deux thèmes côte à côte — c'est exactement la forme d'invariant que la règle
/// 5 demande de tenir plutôt que de recopier.
const _buttonPadding = EdgeInsets.symmetric(
  horizontal: AppSpacing.xl,
  vertical: AppSpacing.md,
);

final _buttonShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(AppRadius.md),
);

/// Le bouton principal — `FilledButton`, et lui seul (`theme/app_buttons.dart`).
final ButtonStyle _filledStyle = FilledButton.styleFrom(
  padding: _buttonPadding,
  shape: _buttonShape,
);

/// L'action alternative. Même forme : sans elle, un « Annuler » bordé restait
/// en pilule à côté d'un « Publier » à coins arrondis, dans la même colonne.
final ButtonStyle _outlinedStyle = OutlinedButton.styleFrom(
  padding: _buttonPadding,
  shape: _buttonShape,
);

/// Thème Echango Delivery — couleurs, typographie, et styles cohérents.
ThemeData buildAppTheme() {
  const primaryColor = Color(0xFF2196F3);

  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: Brightness.light,
    ),
    // Les rôles que Material 3 ne fournit pas — succès et avertissement. Sans
    // eux, la règle 6 (« la couleur vient du thème ») n'a pas d'endroit où
    // envoyer un `Colors.green`.
    extensions: const [AppSemanticColors.light],
    primaryColor: primaryColor,
    appBarTheme: const AppBarTheme(
      backgroundColor: primaryColor,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.grey[100],
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      hintStyle: TextStyle(color: Colors.grey[500]),
    ),
    // ── Le bouton principal, et un seul (31/07/2026) ────────────────────────
    //
    // ⚠️ C'était `elevatedButtonTheme`, qui repeignait `ElevatedButton` en
    // couleur primaire. L'application déclarant `useMaterial3: true`, il y
    // avait donc **deux boutons principaux d'aspect différent** — un
    // `ElevatedButton` repeint et un `FilledButton` natif — et le choix entre
    // eux ne tenait qu'à l'écran où l'on se trouvait : 15 Elevated côté
    // transporteur, 5 Filled côté entreprise, dans la même application.
    //
    // Le style est **repris à l'identique** (même rayon, même rembourrage) :
    // ce lot rend les écrans cohérents entre eux, il ne redessine pas le
    // produit. Les boutons pleins qui existaient déjà (flotte, caisse)
    // adoptent au passage ce rayon à la place de la pilule Material 3 par
    // défaut — c'est précisément l'homogénéité recherchée.
    //
    // Voir `theme/app_buttons.dart` pour le choix du bouton par intention.
    filledButtonTheme: FilledButtonThemeData(style: _filledStyle),
    // Même forme pour l'action alternative : sans elle, un « Annuler » bordé
    // restait en pilule à côté d'un « Publier » à coins arrondis, dans la même
    // colonne de boutons.
    outlinedButtonTheme: OutlinedButtonThemeData(style: _outlinedStyle),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primaryColor,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.grey[100],
      selectedColor: primaryColor,
      labelStyle: const TextStyle(color: Colors.black),
      side: const BorderSide(color: Color(0xFFBDBDBD)),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: Color(0xFF2196F3),
      unselectedLabelColor: Colors.grey,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: Color(0xFF2196F3), width: 2),
      ),
    ),
    fontFamily: 'Roboto',
  );
}

ThemeData buildAppDarkTheme() {
  const primaryColor = Color(0xFF2196F3);

  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: Brightness.dark,
    ),
    extensions: const [AppSemanticColors.dark],
    primaryColor: primaryColor,
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1a1a1a),
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.grey[800],
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      hintStyle: TextStyle(color: Colors.grey[400]),
    ),
    // Les mêmes qu'en clair : sans elles, le même écran affichait des boutons
    // à coins arrondis en clair et des pilules Material 3 en sombre.
    filledButtonTheme: FilledButtonThemeData(style: _filledStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: _outlinedStyle),
    fontFamily: 'Roboto',
  );
}
