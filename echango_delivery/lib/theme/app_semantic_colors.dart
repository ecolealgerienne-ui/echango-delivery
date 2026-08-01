import 'package:flutter/material.dart';

/// Les couleurs que Material 3 ne nomme pas, et dont l'application a besoin.
///
/// ── Pourquoi ce fichier existe ────────────────────────────────────────────
///
/// La règle 6 dit que la couleur vient du thème. Appliquée telle quelle, elle
/// était **inapplicable** pour deux cas pourtant courants : `ColorScheme` a un
/// rôle `error`, mais **aucun rôle « succès » ni « avertissement »**. D'où les
/// huit `Colors.green` et douze `Colors.orange` du dépôt : ce n'était pas de la
/// négligence, c'était l'absence d'un endroit où les mettre.
///
/// Mesuré le 31/07/2026 sur `lib/screens/` + `lib/widgets/` : `grey` 21,
/// `red` 16, `orange` 12, `green` 8, `blue`/`blueGrey` 9, `amber` 5. Les deux
/// premiers ont un équivalent M3 (`onSurfaceVariant`, `error`) ; `orange`,
/// `green` et `amber` n'en ont pas — ce sont eux que ce fichier couvre.
///
/// ── Pourquoi une extension de thème et non des constantes ────────────────
///
/// L'application a **deux** thèmes (`buildAppTheme`, `buildAppDarkTheme`). Une
/// constante `Color(0xFF2E7D32)` serait juste sur fond clair et illisible sur
/// fond sombre — soit exactement le défaut que la règle 6 corrige, reproduit
/// sous un nom plus présentable. `ThemeExtension` fait suivre la valeur au
/// thème actif, et `lerp` la fait suivre pendant une transition.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
  });

  /// Ce qui a abouti, ce qui est actif, ce qui est en ligne.
  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;

  /// Ce qui a abouti **avec une réserve**, ou ce qui appelle l'attention sans
  /// être un échec — « signalement enregistré, photo perdue ».
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;

  /// Teintes claires. Reprises des palettes Material (vert 800, ambre 800)
  /// plutôt qu'inventées : elles ont été éprouvées pour le contraste.
  static const light = AppSemanticColors(
    success: Color(0xFF2E7D32),
    onSuccess: Color(0xFFFFFFFF),
    successContainer: Color(0xFFC8E6C9),
    onSuccessContainer: Color(0xFF1B5E20),
    warning: Color(0xFFEF6C00),
    onWarning: Color(0xFFFFFFFF),
    warningContainer: Color(0xFFFFE0B2),
    onWarningContainer: Color(0xFF5D2C00),
  );

  /// Teintes sombres : les mêmes rôles, éclaircis pour rester lisibles sur fond
  /// sombre. Les recopier depuis [light] aurait produit du vert foncé sur noir.
  static const dark = AppSemanticColors(
    success: Color(0xFF81C784),
    onSuccess: Color(0xFF0B2E0D),
    successContainer: Color(0xFF1B5E20),
    onSuccessContainer: Color(0xFFC8E6C9),
    warning: Color(0xFFFFB74D),
    onWarning: Color(0xFF3E1D00),
    warningContainer: Color(0xFF8C4A00),
    onWarningContainer: Color(0xFFFFE0B2),
  );

  @override
  AppSemanticColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
  }) {
    return AppSemanticColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
    );
  }

  @override
  AppSemanticColors lerp(ThemeExtension<AppSemanticColors>? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer: Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer:
          Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer:
          Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
    );
  }
}

/// Accès court aux couleurs sémantiques depuis un écran.
extension AppSemanticColorsX on BuildContext {
  /// ⚠️ Le repli n'est pas une politesse : `extension<T>()` rend `null` si
  /// l'extension n'a pas été déclarée sur le thème. Sans repli, oublier une
  /// ligne dans `buildAppTheme()` ferait planter tout écran affichant un état
  /// « en ligne » — un défaut de configuration ne doit pas devenir un écran
  /// noir.
  AppSemanticColors get semantic =>
      Theme.of(this).extension<AppSemanticColors>() ?? AppSemanticColors.light;
}
