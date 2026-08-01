import 'package:flutter/material.dart';

import '../theme/app_buttons.dart';

/// Une confirmation : une question, un retrait, une action nommée.
///
/// ── Ce que la mesure a donné, et ce qu'elle a démenti (01/08/2026) ────────
///
/// Le plan annonçait « des ordres de boutons et des tons qui ne s'accordent
/// pas ». **L'ordre s'accordait** : les dix `AlertDialog` du dépôt étaient tous
/// en `[retrait à gauche, action à droite]`, sans exception. C'est le **ton**
/// qui divergeait, et d'une façon plus gênante :
///
///  * « supprimer une adresse », « annuler une livraison » (« cette action est
///    définitive »), « se déconnecter », « contester » — servis en `TextButton`
///    **strictement identique** au « Retour » d'à côté ;
///  * « quitter une entreprise », geste de rupture, servi en `FilledButton` —
///    c'est-à-dire l'affordance de l'action *recommandée*.
///
/// Autrement dit **l'insistance visuelle suivait l'écran où l'on se trouvait,
/// pas l'enjeu**. Même motif que les dix refus affichés comme des
/// confirmations, corrigés le 31/07 par `showAppOutcome`.
///
/// Et `AppButtonStyles.destructive*` existait depuis le 31/07 : employé à sept
/// endroits **dans les pages, zéro dans les dix dialogues**. La convention
/// s'arrêtait à la frontière du dialogue.
///
/// ── La décision, et ce qu'elle écarte ────────────────────────────────────
///
/// **Le ton est marqué, l'ordre ne bouge pas** (décision produit, 01/08/2026).
/// Éloigner l'action destructive du pouce protégerait d'un appui sans regarder,
/// mais créerait **deux dispositions selon le dialogue** — une nouvelle
/// incohérence, à l'inverse de la convention Material que les utilisateurs ont
/// dans les doigts. La couleur suffit à distinguer, et elle ne déplace rien.
///
/// ── Les règles que le composant porte ────────────────────────────────────
///
/// 1. **Deux constructeurs, aucun défaut.** Les six confirmations du dépôt sont
///    *toutes* destructives — un `destructive: false` par défaut ne serait donc
///    exercé nulle part, et le premier dialogue ordinaire ajouté hériterait du
///    rouge sans que personne y pense. Nommer les deux force la question à
///    l'écriture, comme `AppEmptyState.unavailable`.
/// 2. **Rendre `false` sur un rejet.** `showDialog` rend `null` quand on tape à
///    côté ou qu'on revient en arrière ; les six sites écrivaient ce garde à la
///    main, en deux orthographes (`confirmed != true`, `confirmed ?? false`).
///    Un `bool` non nullable le retire des six.
/// 3. **L'action se nomme.** `confirmLabel` dit ce qui va se passer
///    (« Supprimer », « Annuler la livraison »), jamais « OK » ni « Oui » : sur
///    un dialogue dont le titre est déjà une question, « Oui » oblige à relire
///    la question pour savoir ce qu'on approuve.
class AppConfirmDialog {
  const AppConfirmDialog._();

  /// L'action **détruit, retire ou rompt** — et ne se rattrape pas.
  ///
  /// Supprimer une adresse, annuler une livraison, quitter une entreprise,
  /// contester un encaissement, se déconnecter.
  static Future<bool> destructive(
    BuildContext context, {
    String? title,
    required String message,
    required String confirmLabel,
    required String cancelLabel,
  }) =>
      _show(
        context,
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: true,
      );

  /// L'action est ordinaire : elle valide, publie, envoie.
  ///
  /// ⚠️ Aucun site ne l'emploie au 01/08/2026 — les six confirmations du dépôt
  /// sont destructives. Il existe pour que la première confirmation ordinaire
  /// n'hérite pas du rouge par accident, ce qu'un `destructive: false` par
  /// défaut aurait garanti.
  static Future<bool> neutral(
    BuildContext context, {
    String? title,
    required String message,
    required String confirmLabel,
    required String cancelLabel,
  }) =>
      _show(
        context,
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: false,
      );

  static Future<bool> _show(
    BuildContext context, {
    required String? title,
    required String message,
    required String confirmLabel,
    required String cancelLabel,
    required bool destructive,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Facultatif : un des six dialogues n'en avait pas, et lui en inventer
        // un aurait ajouté du texte à traduire sans rien corriger.
        title: title == null ? null : Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(cancelLabel),
          ),
          if (destructive)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: AppButtonStyles.destructiveText(dialogContext),
              child: Text(confirmLabel),
            )
          else
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(confirmLabel),
            ),
        ],
      ),
    );
    // Règle 2 : taper à côté n'est pas confirmer.
    return confirmed ?? false;
  }
}
