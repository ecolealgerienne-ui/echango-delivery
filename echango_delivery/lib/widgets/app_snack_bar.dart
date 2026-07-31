import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';

/// Ce qu'annonce un message éphémère.
///
/// Le ton n'est pas une couleur : c'est ce que l'utilisateur doit en conclure.
/// Nommer `Colors.red` à l'appel obligerait chaque site à rejuger de la couleur,
/// et c'est ainsi qu'un même événement finit par s'afficher de deux façons.
enum SnackTone {
  /// L'opération a abouti. Fond par défaut du thème — un succès n'a pas besoin
  /// d'être signalé par une couleur, il a besoin d'être bref.
  success,

  /// L'opération a échoué. Fond `colorScheme.error`.
  failure,

  /// L'opération a abouti, mais avec une réserve que l'utilisateur doit voir —
  /// « signalement enregistré, photo perdue ». Ni un succès muet, ni un échec.
  warning,
}

/// Affiche un message éphémère au ton donné.
///
/// ── Pourquoi passer par ici ───────────────────────────────────────────────
///
/// Mesuré le 31/07/2026 : 43 appels à `showSnackBar`, dont 17 posaient une
/// couleur à la main. Toutes écrivaient `Colors.red` — une couleur en dur, qui
/// ne suit pas le thème (règle 6) et ne s'accorde pas au bandeau d'erreur, qui
/// lui passait par `colorScheme.errorContainer`. Le même refus s'affichait donc
/// dans deux rouges selon qu'il arrivait en bandeau ou en message.
///
/// Les 26 autres appels n'en posaient aucune, y compris sur des échecs : un
/// refus s'affichait alors exactement comme une confirmation.
///
/// ── Ce que ça ne fait pas ─────────────────────────────────────────────────
///
/// Aucune traduction ici. Les messages viennent de `translateErrorCode` ou du
/// vocabulaire de l'écran ; centraliser l'affichage ne veut pas dire centraliser
/// le texte, et un widget qui choisirait ses mots masquerait la dette i18n au
/// lieu de la réduire.
void showAppSnackBar(
  BuildContext context,
  String message, {
  SnackTone tone = SnackTone.success,
}) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = context.semantic;
  final (Color? background, Color? foreground) = switch (tone) {
    SnackTone.success => (null, null),
    SnackTone.failure => (scheme.error, scheme.onError),
    // `warning` vient de `AppSemanticColors` : Material 3 n'a pas ce rôle, et
    // se rabattre sur `tertiary` aurait donné une couleur qui ne veut rien dire
    // — la réserve doit se distinguer du succès ET de l'échec.
    SnackTone.warning => (semantic.warningContainer, semantic.onWarningContainer),
  };

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: foreground == null ? null : TextStyle(color: foreground),
      ),
      backgroundColor: background,
    ),
  );
}

/// Raccourci pour le cas le plus fréquent : « ça a échoué, voici pourquoi ».
///
/// Existe parce que la forme complète (`tone: SnackTone.failure`) était
/// systématiquement oubliée : sur 43 appels, 26 ne posaient rien alors que
/// plusieurs annonçaient un refus.
void showAppError(BuildContext context, String message) =>
    showAppSnackBar(context, message, tone: SnackTone.failure);

/// Annonce le résultat d'une opération qui rend `null` en cas de succès et un
/// message d'erreur sinon — la convention de toutes les méthodes de `FleetState`
/// et de plusieurs autres classes d'état.
///
/// ⚠️ **C'est ici que se corrige le défaut le plus répandu du lot.** Le code
/// écrivait `SnackBar(content: Text(error ?? 'Course prise'))` : un seul
/// message, aucune couleur, donc **un refus s'affichait exactement comme une
/// confirmation**. Six sites du seul profil entreprise. Le ton se déduit
/// désormais de la donnée — il n'y a plus rien à penser à l'appel, et c'est la
/// seule façon de ne pas l'oublier.
void showAppOutcome(BuildContext context, String? error, String onSuccess) =>
    showAppSnackBar(
      context,
      error ?? onSuccess,
      tone: error == null ? SnackTone.success : SnackTone.failure,
    );
