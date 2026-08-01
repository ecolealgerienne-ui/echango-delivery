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
/// Le fond **et** le texte d'un statut, rendus ensemble.
///
/// ⚠️ **C'étaient deux fonctions jumelles, et le détecteur les a désignées à
/// 93 %** (01/08/2026). Le critère de la règle 5 tranche sans hésiter : si l'une
/// gagne un statut, l'autre DOIT le gagner. Une valeur ajoutée d'un seul côté
/// ne produit aucune erreur — seulement un texte qui retombe sur `surface`
/// par-dessus une teinte inattendue, donc un contraste que personne ne garantit
/// plus. C'est exactement le défaut que la seconde fonction avait été écrite
/// pour corriger (un `Colors.white` unique sur cinq fonds), reproduit un cran
/// plus haut.
///
/// Un enregistrement `(background, foreground)` plutôt que deux appels : le
/// dépôt emploie déjà cette forme (`orders_screen.dart`), et surtout elle rend
/// l'oubli **impossible** au lieu de simplement improbable.
({Color background, Color foreground}) driverStatusColors(
    BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = context.semantic;

  // Alignés sur les statuts Fleetbase réels : une version antérieure testait
  // `accepted` et `picked_up`, qui n'existent pas, et tout tombait dans le
  // gris par défaut. Les deux orthographes de l'annulation sont là parce que
  // Fleetbase émet les deux.
  return switch (status) {
    'created' || 'dispatched' =>
      (background: semantic.warning, foreground: semantic.onWarning),
    'started' || 'enroute' =>
      (background: scheme.primary, foreground: scheme.onPrimary),
    'completed' =>
      (background: semantic.success, foreground: semantic.onSuccess),
    'canceled' || 'cancelled' =>
      (background: scheme.error, foreground: scheme.onError),
    _ => (background: scheme.outline, foreground: scheme.surface),
  };
}
