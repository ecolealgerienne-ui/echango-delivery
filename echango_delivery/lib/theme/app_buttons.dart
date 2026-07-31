import 'package:flutter/material.dart';

/// Quel bouton pour quelle intention — décidé une fois, pour les trois profils.
///
/// ── Ce que la mesure a montré (31/07/2026) ────────────────────────────────
///
/// Le thème est unique et partagé, mais les écrans ne s'en servaient pas
/// également — exactement le constat déjà fait sur les couleurs. Compté sur
/// `lib/screens/` :
///
/// | dossier         | Elevated | Filled | Outlined | Text |
/// |-----------------|----------|--------|----------|------|
/// | `transporteur/` |    15    |   2    |    2     |  11  |
/// | `commercant/`   |     4    |   3    |    4     |   8  |
/// | `flotte/`       |     0    |   5    |    0     |   8  |
/// | `cash/`         |     0    |   4    |    0     |  10  |
///
/// Le profil transporteur est donc en Material 2 et celui de l'entreprise en
/// Material 3, dans **la même application**. Ce n'est pas un choix : c'est ce
/// que produit la recopie, écran après écran.
///
/// ⚠️ **Et le pire cas était dans un seul écran.** `FlotteHomeScreen` sert
/// l'action principale d'une ligne en `FilledButton` dans un onglet
/// (« Prendre cette course ») et en `TextButton` dans l'autre (« Désigner un
/// conducteur ») : la même nature d'action, à deux niveaux de visibilité, à un
/// coup d'onglet d'écart. C'est ce qu'un utilisateur voit en premier, et ce
/// qu'il lit comme deux choses différentes.
///
/// ── La convention ─────────────────────────────────────────────────────────
///
/// L'application déclare `useMaterial3: true`. Le vocabulaire est donc celui de
/// Material 3, et il se choisit par **intention**, jamais par habitude :
///
/// | intention                                   | widget                |
/// |---------------------------------------------|-----------------------|
/// | l'action que l'écran existe pour offrir      | `FilledButton`        |
/// | une action courante, mais pas *la* raison    | `FilledButton.tonal`  |
/// | une sortie, une alternative                  | `OutlinedButton`      |
/// | navigation, annulation, geste sans effet     | `TextButton`          |
/// | destructive                                  | + [destructiveFilled] |
///
/// ⚠️ **`ElevatedButton` n'a plus sa place.** En Material 3 il porte une ombre
/// et un rôle précis — flotter au-dessus d'un contenu qui défile — que cette
/// application n'emploie nulle part. Le thème le repeignait en couleur primaire
/// pour qu'il ressemble à un bouton principal : il y avait donc **deux boutons
/// principaux d'aspect différent**, et le choix entre eux ne tenait qu'à
/// l'écran où l'on se trouvait. `tool/check_buttons.dart` le refuse désormais.
///
/// ── Pourquoi une convention et pas un widget maison ───────────────────────
///
/// La règle 6 dit qu'un motif répété devient un widget. Ici le motif *est* déjà
/// un widget : `FilledButton` existe, il est testé, et l'envelopper demanderait
/// de réexposer `icon`/`label`/`style`/`onLongPress` — c'est-à-dire réécrire
/// l'API de Material pour n'y rien ajouter. Ce qui manquait n'était pas un
/// composant, c'était **une décision**, et une décision se tient par un
/// contrôle exécuté, pas par un commentaire (règle 5).
///
/// Seul le style destructeur est ici : celui-là était vraiment recopié, sept
/// fois, en deux variantes qui ne s'accordaient pas.
class AppButtonStyles {
  AppButtonStyles._();

  /// Une action qui détruit ou refuse, en bouton plein.
  ///
  /// Écrite sept fois dans `lib/screens/`, en deux variantes : quatre posaient
  /// `backgroundColor` **et** `foregroundColor`, trois seulement le premier —
  /// donc un libellé en couleur par défaut sur un fond rouge, dont le contraste
  /// n'était garanti par personne.
  static ButtonStyle destructiveFilled(
    BuildContext context, {
    EdgeInsetsGeometry? padding,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.styleFrom(
      backgroundColor: scheme.error,
      foregroundColor: scheme.onError,
      padding: padding,
    );
  }

  /// La même intention, en bouton bordé — quand l'action destructive n'est pas
  /// celle qu'on attend de l'utilisateur et ne doit pas attirer le pouce.
  static ButtonStyle destructiveOutlined(BuildContext context) =>
      OutlinedButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
      );

  /// Et en bouton de texte, pour une sortie discrète mais nommée.
  static ButtonStyle destructiveText(BuildContext context) =>
      TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
      );
}
