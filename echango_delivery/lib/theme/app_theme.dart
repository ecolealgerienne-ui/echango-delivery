import 'package:flutter/material.dart';
import 'app_semantic_colors.dart';
import 'app_spacing.dart';

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
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    ),
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
    fontFamily: 'Roboto',
  );
}
