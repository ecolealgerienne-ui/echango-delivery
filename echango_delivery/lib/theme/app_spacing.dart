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
/// ── Un intervalle, pas une taille ─────────────────────────────────────────
///
/// `SizedBox(height: 16)` est un **intervalle** entre deux éléments : il relève
/// du barème. `SizedBox(height: 16, width: 16, child: CircularProgressIndicator())`
/// est une **taille de composant** : elle décrit le widget, comme `maxLines: 1`,
/// et reste littérale. Changer l'échelle d'espacement ne doit pas redimensionner
/// les indicateurs de chargement.
///
/// Vérifié après le lot du 31/07/2026 : aucun `SizedBox` portant un `child`
/// n'a été converti, et les onze littéraux du barème encore présents sont tous
/// de cette nature — ou vivent dans `app_theme.dart`, qui emploie désormais les
/// jetons.
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

/// Rayons d'arrondi — **nommés par ce qu'ils arrondissent**, jamais par taille.
///
/// ── Pourquoi cette gamme, et pourquoi ces noms (02/08/2026) ───────────────
///
/// Reprise du système d'Echango Promo (`docs/design_echangopromo.md` §4), où
/// chaque rayon est attribué à un usage plutôt que rangé sur une échelle
/// abstraite. C'est ce qui donne sa silhouette au produit : des cartes très
/// arrondies, des contrôles franchement arrondis, des puces discrètes.
///
/// ⚠️ **Les noms de taille ont été délibérément abandonnés**, et c'est le point
/// le plus important de ce fichier. Leur `md` vaut 16, notre ancien `md` valait
/// 8, et notre `AppSpacing.md` vaut 12 : transposer par nom aurait changé d'un
/// coup les rayons **et** les espacements, sans que rien ne le signale. Un rayon
/// se transpose par affectation — « ce qui arrondit un bouton » —, jamais par
/// l'étiquette qu'il portait dans l'autre dépôt.
///
/// L'ancien `AppRadius.md` (8) est devenu [chip] : la valeur ne bouge que là où
/// l'affectation le demande, et les six sites qui l'employaient ont été relus
/// un par un.
class AppRadius {
  AppRadius._();

  /// 8 — puces, étiquettes, petites surfaces posées **dans** le contenu.
  ///
  /// C'est l'ancienne valeur unique du dépôt : ce qui était une puce ou une
  /// vignette la garde, ce qui était un contrôle passe à [control].
  static const double chip = 8;

  /// 16 — boutons, champs de saisie, images, blocs en ligne.
  ///
  /// Tout ce sur quoi on agit ou qu'on remplit. `PromoCard` arrondit sa photo
  /// au même rayon que ses boutons, et c'est cohérent : une image posée dans une
  /// ligne est un objet du contenu, pas une surface qui le porte.
  static const double control = 16;

  /// 24 — cartes, feuilles modales, dialogues.
  ///
  /// Réservé aux **surfaces qui portent du contenu**. C'est le rayon le plus
  /// visible de l'identité ; l'employer sur un bouton effacerait la distinction
  /// que toute la gamme existe pour faire.
  static const double card = 24;

  // ⚠️ **Pas de `pill` (999).** Promo en a un, pour son badge « -X% » ; nous
  // n'avons aucune pastille, donc le jeton n'aurait **aucun appelant** — et un
  // jeton sans appelant est exactement le défaut que la règle 9 nomme. Il
  // s'ajoutera avec le premier badge, pas avant : la décision est consignée
  // dans `docs/design_echangopromo.md`, où une décision peut attendre son
  // usage sans faire croire qu'elle est appliquée.
}
