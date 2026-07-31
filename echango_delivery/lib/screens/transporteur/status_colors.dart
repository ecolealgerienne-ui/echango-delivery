import 'package:flutter/material.dart';

import '../../theme/app_semantic_colors.dart';

/// Couleur du statut d'une course, **vue par le transporteur**.
///
/// ── Pourquoi une fonction partagée, et pourquoi seulement ici ─────────────
///
/// Cette table existait **deux fois**, à l'identique caractère pour caractère
/// — commentaire de documentation compris —, dans `dashboard_screen.dart` et
/// `order_detail_screen.dart`. C'est le motif exact que la règle 5 désigne :
/// deux copies qui doivent changer ensemble, donc un seul endroit.
///
/// ⚠️ **Et elles avaient toutes deux le même défaut, qui disparaît en
/// fusionnant** : elles traitaient `canceled` sans traiter `cancelled`.
/// Fleetbase émet **les deux orthographes** (constaté et consigné dans
/// `CLAUDE.md`), donc une course annulée sur deux tombait dans le gris par
/// défaut au lieu du rouge. Personne ne l'avait vu parce que les deux copies
/// s'accordaient entre elles — et deux copies d'accord ne prouvent rien.
///
/// ── Pourquoi le commerçant garde la sienne ───────────────────────────────
///
/// `_StatusChip` de `commercant/orders_screen.dart` se ressemble beaucoup et
/// répond à une autre question. Deux statuts y divergent délibérément :
///
///  * `created` — pour le commerçant c'est **son brouillon**, un état neutre
///    dont il est l'auteur ; pour le transporteur c'est une course qui attend,
///    donc un avertissement.
///  * `canceled` — pour le commerçant c'est une décision classée, en gris ;
///    pour le transporteur c'est une course qui lui échappe, en rouge.
///
/// Si l'un change, l'autre ne doit pas suivre : ce sont deux lectures de la
/// même donnée, pas deux copies. Les fusionner obligerait à réintroduire une
/// branche par persona, ce qui est la duplication déguisée en factorisation.
Color driverStatusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = context.semantic;

  return switch (status) {
    // Alignés sur les statuts Fleetbase réels : une version antérieure testait
    // `accepted` et `picked_up`, qui n'existent pas, et tout tombait dans le
    // gris par défaut.
    'created' || 'dispatched' => semantic.warning,
    'started' || 'enroute' => scheme.primary,
    'completed' => semantic.success,
    'canceled' || 'cancelled' => scheme.error,
    _ => scheme.outline,
  };
}

/// Couleur du texte posé sur [driverStatusColor].
///
/// Rendue par une fonction jumelle plutôt que laissée à l'appelant : la version
/// précédente posait un `Colors.white` unique sur cinq fonds, donc le contraste
/// dépendait de la teinte qui sortait du `switch`.
Color onDriverStatusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = context.semantic;

  return switch (status) {
    'created' || 'dispatched' => semantic.onWarning,
    'started' || 'enroute' => scheme.onPrimary,
    'completed' => semantic.onSuccess,
    'canceled' || 'cancelled' => scheme.onError,
    _ => scheme.surface,
  };
}
