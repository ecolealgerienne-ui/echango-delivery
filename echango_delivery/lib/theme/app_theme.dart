import 'package:flutter/material.dart';
import 'app_semantic_colors.dart';
import 'app_spacing.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// L'identité visuelle d'Echango Delivery
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Le système est repris d'Echango Promo — décrit et mesuré dans
/// `docs/design_echangopromo.md` — avec **une seule chose qui change : la
/// teinte de marque**. Tout le reste (typographie, échelle, rayons, traitement
/// des surfaces, mouvement) est hérité tel quel, parce que c'est ce qui fait la
/// famille.
///
/// ⚠️ **Pourquoi Delivery ne reprend PAS le terracotta de Promo.** Le
/// commentaire d'origine dit que le terracotta a été choisi « pour se distinguer
/// des autres apps de la famille echango (qui restent en teal) sur l'écran
/// d'accueil ». La couleur y est donc un **identifiant de produit à l'intérieur
/// d'une famille**, pas un goût — et le reprendre à l'identique irait contre la
/// raison même qui l'a fait choisir : deux applications Echango deviendraient
/// indiscernables dans le tiroir d'applications, au moment précis où l'une sert
/// à publier une promotion et l'autre à déclarer de l'argent encaissé.
///
/// D'où une troisième teinte, choisie **par contrainte** et non par goût :
///
///   1. distincte des deux autres à l'œil — terracotta ≈ 15°, teal ≈ 175°, donc
///      une teinte autour de 245° est à peu près équidistante des deux ;
///   2. lisible en aplat sous du texte blanc, l'`AppBar` étant pleine couleur —
///      **7,9 : 1 en thème clair**, au-dessus du seuil AAA (7) et pas seulement
///      du seuil AA (4,5). Le thème sombre a sa propre valeur, pour une raison
///      détaillée plus bas qu'un test a trouvée avant l'écran ;
///   3. complémentaire du safran, qui reste l'accent commun à la famille.
///
/// Le résultat se lit « fiable et calme » plutôt que « chaleureux », ce qui va
/// bien à une application où l'on consulte une dette et où l'on prouve une
/// livraison.

/// La teinte de marque d'Echango Delivery — **deux valeurs, une identité**.
///
/// ⚠️ Elle était déclarée **dans chaque thème**, à l'identique — et une
/// troisième fois en littéral dans le thème des onglets. Trois copies d'une
/// couleur qui définit le produit : la changer sans en oublier une relevait de
/// l'attention, pas du mécanisme (règle 5).
///
/// ── Pourquoi une seconde valeur en sombre (02/08/2026) ────────────────────
///
/// Parce qu'une seule ne marche pas, et que `test/theme_test.dart` l'a montré
/// **au premier lancement** : avec `#4338CA` posé en primaire sur les deux
/// thèmes, Material calcule `onPrimary = #2C2960` en sombre — un indigo foncé.
/// L'`AppBar`, qui est en aplat de marque, affichait donc du texte sombre sur
/// fond sombre : **contraste 1,67 : 1**, illisible.
///
/// La cause est une convention Material qu'on enfreignait sans le voir : en
/// thème sombre, `primary` est censé être une teinte **claire** et `onPrimary`
/// une teinte foncée. Forcer un primaire sombre laisse `onPrimary` foncé lui
/// aussi. Promo pose sa teinte unique sur les deux thèmes et court le même
/// risque — son terracotta est simplement assez clair pour que ça passe.
///
/// Le remède tient les deux contraintes réelles, mesurées et testées :
///
///   · texte blanc lisible sur la marque    ≥ 4,5 : 1  (5,50 en sombre)
///   · marque détachée du fond de page      ≥ 3   : 1  (3,41 en sombre)
///
/// La teinte claire (`#5B52E8`) est le même indigo éclairci, pas une autre
/// couleur : la marque reste reconnaissable d'un thème à l'autre.
const _primaryLight = Color(0xFF4338CA);
const _primaryDark = Color(0xFF5B52E8);

/// L'accent **partagé par toute la famille Echango**.
///
/// C'est le seul emprunt de couleur à Promo, et il est délibéré : chaque produit
/// porte sa propre teinte primaire, tous partagent le même accent chaud. La
/// famille se reconnaît, les produits se distinguent.
///
/// ⚠️ Il est proche de `AppSemanticColors.warning` (un orange, lui aussi). Ils
/// ne se rencontrent nulle part aujourd'hui — `secondary` ne sert qu'à six
/// endroits, tous décoratifs, et l'avertissement vit dans des bandeaux et des
/// pastilles qui portent en plus une icône. À surveiller si l'un des deux se met
/// à porter une information seul.
const _secondary = Color(0xFFF2A93B);

/// Les surfaces sont **teintées, jamais neutres** — c'est ce qui porte
/// l'identité plus encore que l'accent.
///
/// Promo pose un crème `#FDF6EE`, qui est son terracotta à très faible
/// saturation. L'analogue exact à notre teinte serait `#EFEEFD` (même écart de
/// 15 points entre les canaux). Il est ramené ici à un écart de 10 : un même
/// écart se voit **davantage** sur une teinte froide, où il lit « écran mal
/// calibré » là où le crème lit « papier ». Le principe est repris, la valeur
/// est ajustée — et l'ajustement est dit plutôt que subi.
const _surfaceLight = Color(0xFFF3F2FC);

/// Le pendant sombre, dérivé de la même façon depuis `#211710` : même teinte que
/// la marque, très désaturée, très foncée. Un gris neutre y perdrait la famille.
const _surfaceDark = Color(0xFF111021);

/// Les rouges d'erreur sont **hérités sans modification**, et c'est voulu : une
/// erreur n'a pas à changer de couleur d'un produit à l'autre de la même
/// famille. C'est le seul rôle dont l'utilisateur peut avoir appris le sens
/// ailleurs.
const _errorLight = Color(0xFFD6303D);
const _errorDark = Color(0xFFF87171);

/// ─────────────────────────────────────────────────────────────────────────────
/// Typographie
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Deux familles, et le choix ne porte pas sur le goût : **elles sont retenues
/// parce qu'elles dessinent l'arabe**. Une application trilingue dont la police
/// ne couvre pas l'arabe retombe sur une police système au premier écran
/// traduit, et l'identité disparaît précisément pour la moitié des utilisateurs.
///
/// Vérifié à l'installation : les quatre fichiers couvrent l'arabe (ا ب ة ي),
/// le latin accentué (é à), les chiffres arabes-indiens (٠) et les chiffres
/// latins — 699 glyphes pour Cairo, 1032 pour Plex.
///
/// ⚠️ **Elles sont EMBARQUÉES, pas téléchargées**, et c'est la seule chose que
/// ce lot corrige au système d'origine. Promo passe par `google_fonts` sans
/// déclarer d'assets : les polices sont récupérées **au premier usage**, donc un
/// premier lancement sans réseau retombe en silence sur la police système.
/// Discutable là-bas ; disqualifiant ici, où les transporteurs ouvrent
/// l'application sur le terrain. Un repli silencieux qui détruit l'information
/// « ceci est Echango » est la règle 10 appliquée à une police.
///
/// ⚠️ Cairo n'existe en amont qu'en **police variable** (axes `slnt`, `wght`).
/// Les trois graisses ont donc été instanciées avec `fontTools.varLib.instancer`
/// (`wght=400|600|700`, `slnt=0`) plutôt que déclarées via `fontVariations` :
/// des graisses réelles se comportent comme n'importe quelle police, et un futur
/// contributeur n'a rien de particulier à savoir. `usWeightClass` relu sur les
/// trois fichiers — 400, 600, 700.
const _titleFont = 'Cairo';
const _bodyFont = 'IBMPlexSansArabic';

/// L'échelle typographique, **avec ses interlignes**.
///
/// Reprise telle quelle de Promo (`docs/design_echangopromo.md` §3). Les
/// interlignes sont exprimés en ratio (`height: interligne / taille`), seule
/// façon correcte de les poser en Flutter — un `height` y est un multiplicateur,
/// pas des points.
///
/// Les quatre niveaux `display*` prolongent l'échelle au-dessus de ce que les
/// écrans emploient : ils existent pour que le thème soit complet, et pour qu'un
/// futur écran de mise en avant n'invente pas sa propre taille.
TextTheme _textTheme(ColorScheme scheme) {
  TextStyle title(double size, double lineHeight, FontWeight weight) => TextStyle(
        fontFamily: _titleFont,
        fontSize: size,
        height: lineHeight / size,
        fontWeight: weight,
        color: scheme.onSurface,
      );

  TextStyle body(double size, double lineHeight, FontWeight weight) => TextStyle(
        fontFamily: _bodyFont,
        fontSize: size,
        height: lineHeight / size,
        fontWeight: weight,
        color: scheme.onSurface,
      );

  return TextTheme(
    displayLarge: title(40, 46, FontWeight.w700),
    displayMedium: title(34, 40, FontWeight.w700),
    displaySmall: title(30, 36, FontWeight.w700),
    headlineLarge: title(32, 38, FontWeight.w700),
    // H1
    headlineMedium: title(28, 34, FontWeight.w700),
    headlineSmall: title(24, 30, FontWeight.w700),
    // H2
    titleLarge: title(22, 28, FontWeight.w600),
    // H3
    titleMedium: title(18, 24, FontWeight.w600),
    titleSmall: title(16, 22, FontWeight.w600),
    bodyLarge: body(16, 24, FontWeight.w400),
    // Corps
    bodyMedium: body(15, 22, FontWeight.w400),
    // Caption
    bodySmall: body(12, 16, FontWeight.w400),
    // Bouton / label
    labelLarge: body(14, 20, FontWeight.w500),
    labelMedium: body(12, 16, FontWeight.w500),
    labelSmall: body(11, 14, FontWeight.w500),
  );
}

/// ─────────────────────────────────────────────────────────────────────────────
/// Formes partagées par les deux thèmes
/// ─────────────────────────────────────────────────────────────────────────────
///
/// ⚠️ **Le thème sombre n'avait AUCUN style de bouton.** Le rayon et le
/// rembourrage n'étaient écrits que dans le thème clair : le même écran
/// affichait donc des boutons à coins arrondis en clair et des pilules
/// Material 3 en sombre. Personne ne l'avait vu parce que personne ne compare
/// deux thèmes côte à côte — c'est exactement la forme d'invariant que la règle
/// 5 demande de tenir plutôt que de recopier. Tout ce qui est décidé ici l'est
/// donc **une fois**, au niveau du fichier, et les deux thèmes le consomment.

/// Rembourrage des boutons, repris de Promo : 14 en hauteur, 20 en largeur.
///
/// ⚠️ Ces valeurs ne sont **pas** au barème d'`AppSpacing`, et c'est délibéré :
/// elles décrivent la boîte d'un composant Material, pas une respiration de mise
/// en page. Les tokeniser obligerait à ajouter des jetons dont aucun écran ne se
/// servirait, ce que la règle 7 écarte explicitement — le critère est « quelqu'un
/// pourrait-il vouloir en changer, et faudrait-il alors le changer ailleurs
/// aussi ? », et la réponse est non : ce rembourrage-ci ne bouge que si le dessin
/// du bouton bouge.
const _buttonVertical = 14.0;
const _buttonHorizontal = 20.0;

/// Un bouton bordé compense l'épaisseur de son contour, sinon un « Annuler »
/// bordé est visiblement plus haut que le « Publier » plein posé à côté.
///
/// ⚠️ **Écrit comme une soustraction, pas comme un 12.**
///
/// Ce n'est pas de la coquetterie, et `check_spacing.dart` l'a prouvé : posé en
/// littéral, ce 12 est refusé — c'est `AppSpacing.md`, une valeur du barème. Le
/// commentaire précédent affirmait que les deux rembourrages étaient hors
/// barème ; le contrôle a montré que la moitié de l'affirmation était fausse.
///
/// Mais le remède n'est pas de poser `AppSpacing.md` ici, ce qui rattacherait la
/// hauteur d'un bouton à l'échelle des marges — changer le barème redessinerait
/// alors les boutons. Ce 12 n'est pas une valeur : c'est **une conséquence**, et
/// l'écrire ainsi tient l'invariant à notre place (règle 5). Changer 14 fait
/// suivre l'autre.
const _outlinedVertical = _buttonVertical - 2;

const _buttonPadding = EdgeInsets.symmetric(
  horizontal: _buttonHorizontal,
  vertical: _buttonVertical,
);

const _outlinedPadding = EdgeInsets.symmetric(
  horizontal: _buttonHorizontal,
  vertical: _outlinedVertical,
);

final _controlShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(AppRadius.control),
);

/// Le bouton principal — `FilledButton`, et lui seul (`theme/app_buttons.dart`).
final ButtonStyle _filledStyle = FilledButton.styleFrom(
  padding: _buttonPadding,
  shape: _controlShape,
);

/// L'action alternative. Même forme : sans elle, un « Annuler » bordé restait
/// en pilule à côté d'un « Publier » à coins arrondis, dans la même colonne.
final ButtonStyle _outlinedStyle = OutlinedButton.styleFrom(
  padding: _outlinedPadding,
  shape: _controlShape,
);

/// Les cartes : **élévation zéro, profondeur rendue par une bordure**.
///
/// C'est le parti pris le plus visible du système repris, et il tient debout au
/// delà du goût : sur les écrans bon marché que visent nos transporteurs, une
/// ombre portée bave et salit le fond, là où une bordure d'un pixel reste nette.
/// `margin: zero` parce que l'espacement d'une carte appartient à la liste qui
/// la contient, pas à la carte — sans ça, deux listes voisines n'ont pas le même
/// rythme et personne ne sait laquelle a raison.
CardThemeData _cardTheme(ColorScheme scheme) => CardThemeData(
      elevation: 0,
      color: scheme.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    );

/// Les puces : rayon discret, bordure plutôt que fond plein au repos.
ChipThemeData _chipTheme(ColorScheme scheme, TextTheme text) => ChipThemeData(
      backgroundColor: scheme.surface,
      selectedColor: scheme.primary,
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      labelStyle: text.labelLarge ?? const TextStyle(),
      secondaryLabelStyle:
          (text.labelLarge ?? const TextStyle()).copyWith(color: scheme.onPrimary),
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
///
/// ⚠️ Promo ne pose qu'un `border` et un `fillColor` — ce système-ci est donc
/// **plus complet que celui dont il hérite**, et il faut le garder ainsi : le
/// reprendre tel quel rouvrirait le défaut du 01/08.
InputDecorationTheme _inputDecorationTheme(
  ColorScheme scheme, {
  required Color fill,
  required Color hint,
}) {
  OutlineInputBorder shape(BorderSide side) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
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
/// qui est en couleur de marque — donc marque sur marque pour l'onglet actif,
/// indicateur invisible, et gris délavé pour les autres. Un seul thème ne peut
/// pas servir les deux fonds ; c'est l'écran qui a été aligné sur les deux
/// autres profils, plutôt qu'un second thème d'onglets ajouté à côté du premier.
///
/// ⚠️ **Construit depuis le schéma, plus depuis une constante.** Il lisait
/// `_primary` en dur, ce qui était juste tant qu'il n'y avait qu'une teinte ;
/// depuis que le sombre a la sienne, une constante figée aurait souligné
/// l'onglet actif dans la couleur de l'AUTRE thème. Une divergence qui ne se
/// voit qu'en basculant le téléphone en sombre, c'est-à-dire jamais pendant
/// qu'on écrit le code.
TabBarThemeData _tabBarTheme(ColorScheme scheme) => TabBarThemeData(
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    );

/// La palette, dérivée une fois pour les deux thèmes.
///
/// ⚠️ **Les quatre rôles d'identité sont redéclarés explicitement.**
/// `ColorScheme.fromSeed` produit une palette harmonisée, mais il **décale la
/// graine** : sans ces quatre lignes, le primaire rendu ne serait pas
/// `#4338CA`, et la couleur du produit serait « à peu près » la bonne. Le bon
/// partage est celui de Promo — l'identité est tenue à la main, les vingt autres
/// rôles sont calculés.
ColorScheme _scheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return ColorScheme.fromSeed(
    seedColor: _primaryLight,
    brightness: brightness,
    primary: isDark ? _primaryDark : _primaryLight,
    // ⚠️ **`onPrimary` est posé, pas laissé au calcul.** C'est le rôle qui a
    // produit le défaut : redéclarer `primary` sans lui laisse Material dériver
    // un `onPrimary` depuis la palette de la graine, qui ne s'accorde plus avec
    // la couleur qu'on vient d'imposer. Le blanc est le seul choix qui tienne
    // sur les deux teintes, et il est vérifié par un test de contraste.
    onPrimary: Colors.white,
    secondary: _secondary,
    surface: isDark ? _surfaceDark : _surfaceLight,
    error: isDark ? _errorDark : _errorLight,
  );
}

/// L'`AppBar` est **pleine couleur de marque**, sur les deux thèmes.
///
/// ⚠️ Le thème sombre posait un gris `#1a1a1a` là où le clair posait la marque :
/// la couleur du produit disparaissait complètement pour qui utilise son
/// téléphone en sombre — c'est-à-dire, sur un écran de livraison consulté le
/// soir, à peu près tout le monde. Sur un primaire aussi soutenu, l'aplat est ce
/// qui rend la marque présente sur chaque écran sans avoir à la répéter ailleurs.
AppBarTheme _appBarTheme(ColorScheme scheme, TextTheme text) => AppBarTheme(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onPrimary),
      iconTheme: IconThemeData(color: scheme.onPrimary),
    );

ThemeData _build(Brightness brightness) {
  final scheme = _scheme(brightness);
  final text = _textTheme(scheme);
  final isDark = brightness == Brightness.dark;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    // Le fond de page **suit la surface**, au lieu du blanc/noir par défaut :
    // sans ça, la teinte des surfaces ne se voit nulle part et tout le
    // raisonnement sur les fonds teintés tombe.
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text,
    // Les rôles que Material 3 ne fournit pas — succès et avertissement. Sans
    // eux, la règle 6 (« la couleur vient du thème ») n'a pas d'endroit où
    // envoyer un `Colors.green`.
    extensions: [isDark ? AppSemanticColors.dark : AppSemanticColors.light],
    primaryColor: scheme.primary,
    appBarTheme: _appBarTheme(scheme, text),
    inputDecorationTheme: _inputDecorationTheme(
      scheme,
      // ⚠️ Un rôle du schéma, plus un `Colors.grey[100]` : le remplissage était
      // le dernier gris figé du thème, et il ne s'accordait avec aucune des deux
      // surfaces teintées.
      fill: scheme.surfaceContainerHighest,
      hint: scheme.onSurfaceVariant,
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
    // Voir `theme/app_buttons.dart` pour le choix du bouton par intention.
    filledButtonTheme: FilledButtonThemeData(style: _filledStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: _outlinedStyle),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        textStyle: text.labelLarge,
      ),
    ),
    cardTheme: _cardTheme(scheme),
    chipTheme: _chipTheme(scheme, text),
    tabBarTheme: _tabBarTheme(scheme),
  );
}

/// Thème clair d'Echango Delivery.
ThemeData buildAppTheme() => _build(Brightness.light);

/// Thème sombre — **la même fonction**, à la luminosité près.
///
/// ⚠️ Les deux thèmes étaient deux corps de fonction recopiés, et c'est ainsi
/// que le sombre s'est retrouvé sans style de bouton, sans thème d'onglets et
/// avec une `AppBar` grise. Deux copies ne se comparent jamais ; une seule
/// construction ne peut pas diverger (règle 5).
ThemeData buildAppDarkTheme() => _build(Brightness.dark);
