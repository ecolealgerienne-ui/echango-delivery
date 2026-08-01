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
/// La couleur de marque.
///
/// ⚠️ Elle était déclarée **dans chaque thème**, à l'identique — et une
/// troisième fois en littéral dans le thème des onglets. Trois copies d'une
/// couleur qui définit le produit : la changer sans en oublier une relevait de
/// l'attention, pas du mécanisme (règle 5).
const _primary = Color(0xFF2196F3);

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

/// Les champs de saisie, décidés une fois pour les deux thèmes.
///
/// ── Pourquoi ce n'était pas le thème qui décidait (01/08/2026) ────────────
///
/// Mesuré : **21 des 25 `InputDecoration` du dépôt repassaient un
/// `border: OutlineInputBorder()` nu**, qui écrase celui du thème. Résultat,
/// deux apparences dans la même application — 21 champs à contour visible et
/// coins de 4 px (le défaut Material), 4 champs remplis sans contour à coins de
/// 8 px. Et les quatre étaient **tous dans le profil entreprise**, exactement
/// comme pour les boutons : ce profil suit le thème, les deux autres se
/// peignent eux-mêmes.
///
/// ⚠️ **Mais les 21 avaient une raison qu'ils ignoraient.** Le thème posait
/// `borderSide: BorderSide.none` et **rien d'autre** : pas de `focusedBorder`.
/// Un champ n'avait donc aucun contour au repos *ni au focus* — le seul signal
/// restant était la couleur du libellé. Les 21 surcharges compensaient un
/// défaut du thème sans le savoir. Retirer les surcharges sans corriger le
/// thème aurait uniformisé l'application **vers le pire des deux états**.
///
/// Les cinq états sont donc posés **explicitement**, et non laissés au repli de
/// `InputDecorator` : la façon dont Flutter dérive `focusedBorder` d'un `border`
/// à `BorderSide.none` n'est pas vérifiable ici, et une apparence ne doit pas
/// dépendre d'une règle interne qu'on croit se rappeler.
InputDecorationTheme _inputDecorationTheme(
  ColorScheme scheme, {
  required Color fill,
  required Color hint,
}) {
  OutlineInputBorder shape(BorderSide side) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: side,
      );

  return InputDecorationTheme(
    filled: true,
    fillColor: fill,
    border: shape(BorderSide.none),
    enabledBorder: shape(BorderSide.none),
    // Le seul contour visible : celui qui dit où l'on tape.
    focusedBorder: shape(BorderSide(color: scheme.primary, width: 2)),
    errorBorder: shape(BorderSide(color: scheme.error)),
    focusedErrorBorder: shape(BorderSide(color: scheme.error, width: 2)),
    contentPadding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.md,
    ),
    hintStyle: TextStyle(color: hint),
  );
}

/// Les onglets, décidés une fois pour les deux thèmes.
///
/// ⚠️ **Écrits pour un fond clair, et le thème sombre n'en avait aucun.**
/// Libellé actif en couleur de marque, inactif en gris : cela suppose que la
/// barre est posée sur la page. `FlotteHomeScreen` la posait dans l'AppBar,
/// qui est bleue — donc bleu sur bleu pour l'onglet actif, indicateur bleu sur
/// bleu, et gris délavé pour les autres. Un seul thème ne peut pas servir les
/// deux fonds ; c'est l'écran qui a été aligné sur les deux autres profils,
/// plutôt qu'un second thème d'onglets ajouté à côté du premier.
const _tabBarTheme = TabBarThemeData(
  labelColor: _primary,
  unselectedLabelColor: Colors.grey,
  indicator: UnderlineTabIndicator(
    borderSide: BorderSide(color: _primary, width: 2),
  ),
);

/// Thème Echango Delivery — couleurs, typographie, et styles cohérents.
ThemeData buildAppTheme() {
  const primaryColor = _primary;
  final scheme = ColorScheme.fromSeed(
    seedColor: primaryColor,
    brightness: Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
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
    inputDecorationTheme: _inputDecorationTheme(
      scheme,
      fill: Colors.grey[100]!,
      hint: Colors.grey[500]!,
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
    tabBarTheme: _tabBarTheme,
    fontFamily: 'Roboto',
  );
}

ThemeData buildAppDarkTheme() {
  const primaryColor = _primary;
  final scheme = ColorScheme.fromSeed(
    seedColor: primaryColor,
    brightness: Brightness.dark,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: const [AppSemanticColors.dark],
    primaryColor: primaryColor,
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1a1a1a),
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    // Les mêmes qu'en clair, à la teinte de remplissage près : le thème sombre
    // n'avait pas non plus de contour de focus, et une divergence de plus ici
    // n'aurait été vue par personne.
    inputDecorationTheme: _inputDecorationTheme(
      scheme,
      fill: Colors.grey[800]!,
      hint: Colors.grey[400]!,
    ),
    // Les mêmes qu'en clair : sans elles, le même écran affichait des boutons
    // à coins arrondis en clair et des pilules Material 3 en sombre.
    filledButtonTheme: FilledButtonThemeData(style: _filledStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: _outlinedStyle),
    // Le même qu'en clair : sans lui, les onglets du thème sombre retombaient
    // sur les défauts Material 3 — donc deux apparences pour un même écran.
    tabBarTheme: _tabBarTheme,
    fontFamily: 'Roboto',
  );
}
