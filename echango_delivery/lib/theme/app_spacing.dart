/// Les valeurs d'apparence de l'application, nommées à un seul endroit.
///
/// ── Le barème sort des données, pas d'une convention ──────────────────────
///
/// Mesuré le 31/07/2026 sur `lib/screens/` et `lib/widgets/` : 339 espacements
/// écrits en dur, répartis sur quinze valeurs distinctes. Six d'entre elles en
/// portent **91 %** —
///
///     4 → 31 fois     8 → 74 fois    12 → 70 fois
///    16 → 98 fois    24 → 20 fois    32 → 16 fois
///
/// — et les neuf autres se partagent les 30 restantes. Le barème ci-dessous est
/// donc l'échelle que le code utilisait déjà, sans le savoir : on la nomme, on
/// ne l'invente pas.
///
/// ── ⚠️ Centraliser n'est pas redessiner ───────────────────────────────────
///
/// Les valeurs hors barème (1, 2, 6, 10, 14, 20, 36, 48) **restent littérales**.
/// Les faire glisser vers le jeton voisin changerait le rendu, et un lot de
/// centralisation qui déplace des pixels devient impossible à relire : on ne
/// distingue plus ce qui a été renommé de ce qui a été modifié.
///
/// Les faire converger est une décision de design, elle se prend à part et se
/// regarde à l'écran. `tool/check_spacing.dart` les recense pour que la question
/// reste posée au lieu de se dissoudre.
///
/// ── Pourquoi `double` et non `int` ────────────────────────────────────────
///
/// `EdgeInsets`, `SizedBox` et `BorderRadius` prennent des `double`. Déclarer
/// des `int` obligerait chaque site d'appel à convertir, ce qui rendrait le
/// remplacement moins direct — et un remplacement moins direct est un
/// remplacement qu'on relit moins bien.
///
/// `static const double` reste une constante de compilation : `const
/// EdgeInsets.all(AppSpacing.lg)` compile toujours, et `prefer_const_constructors`
/// (activé dans `analysis_options.yaml`) est satisfait.
library;

/// Échelle d'espacement — marges, remplissages, intervalles.
class AppSpacing {
  AppSpacing._();

  /// 4 — écart le plus fin : deux lignes d'un même bloc.
  static const double xs = 4;

  /// 8 — intervalle courant entre deux éléments voisins.
  static const double sm = 8;

  /// 12 — remplissage interne d'un composant dense.
  static const double md = 12;

  /// 16 — la marge de référence : bord d'écran, remplissage d'une carte.
  static const double lg = 16;

  /// 24 — séparation entre deux groupes.
  static const double xl = 24;

  /// 32 — respiration d'un écran vide ou d'un en-tête.
  static const double xxl = 32;
}

/// Rayons d'arrondi.
class AppRadius {
  AppRadius._();

  /// 8 — **la seule valeur du dépôt**, partagée par les cartes, les champs de
  /// saisie et les boutons. `theme/app_theme.dart` l'emploie déjà pour les
  /// bordures d'`InputDecoration` et d'`ElevatedButton` ; ce jeton la nomme pour
  /// les écrans, qui l'écrivaient en dur.
  ///
  /// Un seul nom tant qu'il n'y a qu'une valeur : en inventer deux (`card`,
  /// `input`) laisserait croire à une distinction que le rendu ne fait pas, et
  /// la première divergence passerait pour intentionnelle.
  static const double md = 8;
}
