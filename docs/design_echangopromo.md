# Le système de design d'Echango Promo — description et transposition

Lecture de `github.com/ecolealgerienne-ui/echangopromo`, partie mobile
(`apps/mobile/`), le 02/08/2026. Écrit pour décider **ce qu'on applique à Echango
Delivery**, donc chaque affirmation est mesurée sur le code plutôt que déduite d'une
impression.

⚠️ **Le système de design n'est documenté nulle part ailleurs que dans le code.**
`lib/app/theme.dart` (194 lignes) le porte en entier, et ses commentaires citent une
« maquette de comparaison des 3 pistes validée avant implémentation » qui **ne se trouve
pas dans le dépôt**. Ce document est donc la première description écrite de ce système —
ce qui veut aussi dire qu'il n'existe aucune source à laquelle le confronter.

---

## 1. La décision qui gouverne tout

Le thème s'ouvre sur une phrase qui n'est pas décorative :

> Système de design **« Chaleureux & communautaire » (terracotta/safran)** — piste choisie
> pour incarner le lien de quartier du pilote plutôt que les codes visuels « app durable »
> vert/bleu.

C'est un **positionnement**, pas une palette. Trois conséquences en découlent, et elles se
vérifient toutes dans le code :

1. **La couleur de marque s'écarte délibérément du bleu/vert** — le registre visuel par
   défaut des applications « utiles ». Le commentaire va jusqu'à noter que l'icône de
   l'application est recolorée dans le même terracotta « pour se distinguer des autres apps
   de la famille echango (qui restent en teal) sur l'écran d'accueil ». La couleur est donc
   un **identifiant produit à l'intérieur d'une famille**, pas un goût.
2. **La typographie est choisie pour l'arabe d'abord**, pas adaptée après coup (§3).
3. **Le mouvement est bridé** par une contrainte matérielle nommée (§5).

C'est ce qui distingue ce thème d'un `ColorScheme.fromSeed` posé à la va-vite : chaque
valeur a une raison écrite à côté d'elle.

---

## 2. La couleur

### Les valeurs, telles qu'elles sont

| rôle | clair | sombre |
|---|---|---|
| `primary` | **`#E8571E`** terracotta | idem (graine) |
| `secondary` | **`#F2A93B`** safran | idem |
| `surface` | `#FDF6EE` crème | `#211710` brun très sombre |
| `error` | `#D6303D` | `#F87171` |
| `success` *(extension)* | `#2F9E62` | `#4ADE80` |
| `warning` *(extension)* | `#B45309` | `#FBBF24` |

### Comment elles sont posées

```dart
ColorScheme.fromSeed(
  seedColor: _terracotta,
  brightness: brightness,
  primary: _terracotta,      // la graine seule ne rend PAS la couleur exacte
  secondary: _safran,
  surface: isDark ? _surfaceDark : _surfaceLight,
  error: isDark ? _errorDark : _errorLight,
)
```

**Le point important est le `primary:` explicite.** `fromSeed` produit une palette
harmonisée, mais elle *décale* la graine — le terracotta rendu ne serait pas
`#E8571E`. Redéclarer les quatre rôles qui portent l'identité (primaire, secondaire,
surface, erreur) et laisser `fromSeed` calculer les vingt autres est exactement le bon
partage : l'identité est tenue à la main, l'harmonie est calculée.

**Les surfaces ne sont pas neutres.** `#FDF6EE` est un crème, pas un blanc ;
`#211710` un brun, pas un gris. C'est ce qui porte le « chaleureux » plus encore que
l'accent — un accent chaud sur fond blanc froid ne change presque rien à la perception,
la teinte du fond, si.

### Les couleurs sémantiques

`AppSemanticColors extends ThemeExtension` — succès et attention, absents de
`ColorScheme` qui n'a que `error`. Deux déclinaisons figées, `light` et `dark`.

**C'est exactement le mécanisme que nous avons déjà**, et pour la raison identique. Notre
version est plus riche : nous portons `success`/`onSuccess`/`successContainer`/
`onSuccessContainer` et les quatre équivalents pour `warning`, là où elle n'a que
`success` et `warning` nus.

### Ce que la mesure dit de la discipline

| | echangopromo |
|---|---|
| `Colors.*` ou `Color(0x…)` dans `lib/features/` | **20** |
| `Theme.of(context)` / `colorScheme.` | **125** |

Un rapport de 1 à 6, ce qui est bon — mais pas zéro. Les vingt survivants sont concentrés
sur sept fichiers (`Colors.redAccent` sur un cœur de favori, des couleurs de statut dans
`enum_labels.dart`, le tableau de bord commerçant).

---

## 3. La typographie — le choix le plus structurant

Deux familles, chargées par `google_fonts` :

| usage | famille | graisses |
|---|---|---|
| Titres (`display*`, `headline*`, `title*`) | **Cairo** | 600 / 700 |
| Corps, labels (`body*`, `label*`) | **IBM Plex Sans Arabic** | 400 / 500 |

Le `pubspec` le dit sans ambiguïté : *« support natif FR/EN/AR »*. **Les deux familles sont
choisies parce qu'elles dessinent l'arabe**, pas parce qu'elles sont jolies en latin. Une
application trilingue dont la police ne couvre pas l'arabe retombe sur une police système
au premier écran traduit — et l'identité disparaît précisément pour la moitié des
utilisateurs.

### L'échelle, avec ses interlignes

Elle est écrite explicitement, jamais laissée au défaut Material :

| niveau | taille / interligne | famille, graisse |
|---|---|---|
| `headlineMedium` (H1) | 28 / 34 | Cairo 700 |
| `titleLarge` (H2) | 22 / 28 | Cairo 600 |
| `titleMedium` (H3) | 18 / 24 | Cairo 600 |
| `titleSmall` | 16 / 22 | Cairo 600 |
| `bodyLarge` | 16 / 24 | Plex 400 |
| `bodyMedium` (corps) | 15 / 22 | Plex 400 |
| `bodySmall` (caption) | 12 / 16 | Plex 400 |
| `labelLarge` (bouton) | 14 / 20 | Plex 500 |
| `labelMedium` | 12 / 16 | Plex 500 |
| `labelSmall` | 11 / 14 | Plex 500 |

L'interligne est passé en ratio (`height: lineHeight / size`), ce qui est la seule façon
correcte de l'exprimer en Flutter. Les quatre niveaux `display*` prolongent l'échelle
au-dessus sans être employés à l'écran — ils existent pour que le thème soit complet.

⚠️ **Les polices ne sont PAS embarquées.** `assets:` ne déclare que `assets/images/`,
aucun `fonts:`, et `GoogleFonts.config.allowRuntimeFetching` n'est jamais touché.
Conséquence mesurable : Cairo et IBM Plex Sans Arabic sont **téléchargées au premier
usage**, puis mises en cache. **Au tout premier lancement sans réseau, l'application
retombe silencieusement sur la police système** — l'identité typographique disparaît, et
rien ne le signale. C'est une décision par défaut, pas un arbitrage : le remède tient à
poser les `.ttf` dans `assets/fonts/` et à les déclarer.

---

## 4. La forme — rayons et surfaces

```dart
class AppRadii {
  static const double sm   = 8;    // chips
  static const double md   = 16;   // boutons, champs de saisie
  static const double lg   = 24;   // cartes, feuilles modales
  static const double pill = 999;  // badges
}
```

Le commentaire attribue chaque valeur à un usage — ce n'est pas une gamme abstraite, c'est
une **affectation**. Et c'est ce qui donne la silhouette du produit : des cartes très
arrondies (24), des boutons franchement arrondis (16), des chips discrètes (8).

### Le traitement des composants

| composant | traitement |
|---|---|
| `AppBar` | fond **`primary`**, texte et icônes `onPrimary`, `elevation: 0` |
| `Card` | `elevation: 0`, fond `surface`, **bordure `outlineVariant`**, rayon 24, `margin: zero` |
| `Chip` | rayon 8, bordure `outlineVariant`, sélection en `primary` |
| `InputDecoration` | `filled: true` sur `surface`, rayon 16 |
| `FilledButton` / `ElevatedButton` | `primary`/`onPrimary`, padding **14 × 20**, rayon 16 |
| `OutlinedButton` | bordure `outlineVariant`, padding **12 × 20**, rayon 16 |
| `TextButton` | teinte `primary` |

**Deux partis pris cohérents et à retenir :**

- **Zéro élévation partout.** La profondeur est rendue par une **bordure**, jamais par une
  ombre. C'est un choix Material 3, et il tient debout sur les écrans bon marché où les
  ombres bavent.
- **L'`AppBar` est pleine couleur.** Sur un accent aussi saturé que le terracotta, c'est ce
  qui rend la marque visible sur chaque écran sans avoir à la répéter ailleurs.

---

## 5. Le mouvement

```dart
/// Durée de transition unique (≤180ms, easeOut) — la piste retenue
/// proscrit les animations spring/physics, coûteuses à interpoler sur les
/// appareils d'entrée de gamme visés par le pilote.
const kAppTransitionDuration = Duration(milliseconds: 180);
```

Une constante, une courbe, une justification **matérielle**. C'est la seule partie du
système qui nomme explicitement sa contrainte d'exécution — et c'est aussi celle qu'on
oublie le plus souvent d'écrire.

---

## 6. Les composants extraits

Le dépôt applique une règle maison — *« extrait dès la 2ᵉ duplication »* — et la cite dans
les commentaires des widgets concernés. Vingt widgets partagés, dont :

| widget | ce qu'il porte |
|---|---|
| `PromoDiscountBadge` | le badge `-X%` : pilule `primary`, calcul du pourcentage inclus |
| `PromoPriceRow` | prix barré + prix remisé, avec le format monétaire `DA` |
| `LoadingButton` | `FilledButton` + spinner 20×20 (strokeWidth 2), désactivé pendant le chargement |
| `ErrorText` | message d'erreur ; rend `SizedBox.shrink()` quand il n'y a rien, donc utilisable sans condition |
| `PromoPhotoHero`, `PhotoPickerField`, `CommuneCascadeField`… | motifs métier |

Deux détails de méthode qui valent d'être notés, parce qu'ils se transposent :

- **Les composants prennent des surcharges de taille plutôt que d'être dupliqués.**
  `PromoDiscountBadge` accepte `padding` et `textStyle` : la carte passe `labelSmall`, la
  fiche garde `labelLarge`. Un seul composant, deux densités.
- **`ErrorText` occupe un espace nul quand il n'a rien à dire.** C'est ce qui permet de
  l'écrire inconditionnellement dans une liste de `children`, au lieu du `if (_error !=
  null) ...[]` que tout le monde recopie.

---

## 7. Ce que le système **ne** couvre **pas**

À dire clairement, parce qu'on s'apprête à emprunter et qu'il ne faut pas emprunter les
trous avec le reste.

**Il n'y a aucun jeton d'espacement.** Les marges sont des littéraux bruts, sur 182 sites.
Distribution mesurée :

| valeur | 12 | 16 | 8 | 4 | 24 | 20 | 3 | 6 | 10 | 14 | autres |
|---|---|---|---|---|---|---|---|---|---|---|---|
| occurrences | **60** | **49** | **46** | **18** | 6 | 3 | 4 | 2 | 2 | 2 | 3 |

Une grille de 4 points **de fait** — mais tenue par personne. Les écrans qui veulent nommer
une valeur le font localement (`const _listPadding = 12.0;` en tête de fichier), ce qui est
mieux que rien et ne traverse pas les fichiers.

**Il n'y a pas de contrôle exécuté.** Aucun vérificateur ne refuse une couleur en dur, un
littéral d'espacement ou une divergence FR/AR. La discipline tient à la relecture — d'où,
probablement, les 20 couleurs survivantes.

**Le RTL est traité au cas par cas**, pas systématiquement : 8 sites utilisent
`EdgeInsetsDirectional` / `PositionedDirectional` / `AlignmentDirectional`. C'est suffisant
là où c'était nécessaire, mais rien ne garantit qu'un nouvel écran y pense.

**Il n'y a pas d'état vide normalisé**, pas de bandeau d'erreur partagé au-dessus du
contenu, pas de convention de `SnackBar` succès/échec.

---

## 8. Face à Echango Delivery — ce qui changerait vraiment

| axe | echangopromo | Echango Delivery (nous) | verdict |
|---|---|---|---|
| **Couleur de marque** | terracotta `#E8571E` + safran `#F2A93B` | **bleu Material `#2196F3`** | à **prendre** |
| **Surfaces** | crème `#FDF6EE` / brun `#211710` | défaut Material (blanc / `#1a1a1a`) | à **prendre** |
| **Typographie** | Cairo + IBM Plex Sans Arabic | **Roboto** | à **prendre**, en embarquant les polices |
| **Échelle typo** | 10 niveaux, interlignes explicites | défaut Material | à **prendre** |
| **Rayons** | 4 jetons affectés (8/16/24/999) | **`AppRadius.md = 8`, un seul** | à **prendre** |
| **Mouvement** | constante 180 ms easeOut | non normalisé | à **prendre** |
| **AppBar** | pleine couleur `primary` | déjà pleine couleur `primary` | identique |
| **Cartes** | élévation 0 + bordure, rayon 24 | rayon 8 | à **prendre** |
| **Couleurs sémantiques** | `success`/`warning` | `success`+`on`+`container`+`onContainer`, idem `warning` | **garder le nôtre** |
| **Jetons d'espacement** | aucun, 182 littéraux | `AppSpacing` xs→xxl + `check_spacing.dart` | **garder le nôtre** |
| **Couleurs en dur (écrans)** | 20 | **0** | **garder le nôtre** |
| **Contrôles exécutés** | aucun | 5 vérificateurs, 76 cas de refus | **garder le nôtre** |

**La lecture d'ensemble tient en une phrase : ils ont l'identité que nous n'avons pas, nous
avons la discipline qu'ils n'ont pas.** Notre thème est correctement structuré et
parfaitement anonyme — un bleu Material et un Roboto, c'est-à-dire l'absence de choix.
Le leur porte un produit reconnaissable, sans rien pour empêcher sa dérive.

L'opération n'est donc **pas** « remplacer notre design system par le leur ». C'est
**verser leurs décisions dans notre structure** : nos jetons gardent leurs noms, leurs
valeurs changent.

⚠️ **Un écart de vocabulaire à ne pas rater à la transposition.** Nos deux échelles ne
coïncident pas :

| | leur `md` | notre `md` |
|---|---|---|
| espacement | *(pas de jeton)* | **12** |
| rayon | **16** | **8** |

Reprendre « `md`= 16 » sans regarder ferait passer nos rayons de carte de 8 à 16 **et** nos
espacements de 12 à 16, en une seule ligne, sans que rien ne le signale. Les rayons se
transposent par **affectation** (chip / bouton / carte), jamais par nom.

---

## 9. Ce que je recommande, et ce que je déconseille

### À prendre tel quel

1. **La palette entière** — les six couleurs, clair et sombre.
2. **Les deux familles typographiques et l'échelle complète**, interlignes compris.
3. **Les quatre rayons, avec leur affectation** (chip 8 / bouton-champ 16 / carte-modale 24
   / pilule 999).
4. **Élévation zéro + bordure `outlineVariant`** sur les cartes.
5. **La constante de transition** 180 ms easeOut, et l'interdiction des animations à
   ressort.

### À prendre en corrigeant

6. **Embarquer les polices** (`assets/fonts/`) au lieu de les télécharger. Chez eux le
   défaut est déjà discutable ; chez nous il est disqualifiant — nos transporteurs
   travaillent sur le terrain, et un premier lancement sans réseau perdrait l'identité sans
   rien dire. C'est aussi la règle 10 appliquée à une police.
7. **Verser les valeurs dans nos jetons existants** (`AppSpacing`, `AppRadius`,
   `AppSemanticColors`) plutôt que d'importer `AppRadii`. Deux systèmes de rayons
   coexistants, c'est la règle 5 violée le jour même.

### À ne pas prendre

8. **Leur absence de jetons d'espacement.** Nous avons 320 sites convertis et un
   vérificateur qui les tient ; revenir à des littéraux serait défaire un chantier fini.
9. **Leurs couleurs sémantiques réduites.** Les nôtres portent les paires
   `container`/`on…`, dont nos bandeaux et nos pastilles se servent déjà.
10. **Leur organisation par *features*.** Elle est défendable, mais c'est une refonte
    d'arborescence sans rapport avec le design — et notre code est rangé par couches, avec
    des contrôles qui connaissent ces chemins.

---

## 10. Ce qu'il reste à décider — et qui n'est pas à moi

Trois questions, et la première est la seule qui bloque.

1. **Echango Delivery doit-il porter le terracotta, ou sa propre couleur ?** Le commentaire
   d'echangopromo dit que le terracotta a été choisi **pour se distinguer des autres
   applications de la famille**, qui « restent en teal ». Reprendre le terracotta à
   l'identique irait donc à l'encontre de la raison qui l'a fait choisir : deux
   applications de la même famille deviendraient indistinguables sur l'écran d'accueil.
   Trois lectures possibles, et c'est un arbitrage produit :
   - **une famille, une couleur par produit** — Delivery prend une troisième teinte, et
     hérite de tout le reste (typo, rayons, surfaces, mouvement) ;
   - **une famille, une couleur commune** — Delivery prend le terracotta, et la distinction
     se fait par l'icône ;
   - **Delivery garde le teal** de la famille historique, et n'emprunte que la structure.

   **Ma recommandation : la première.** C'est elle qui respecte l'intention d'origine, et
   c'est la moins coûteuse — la teinte est *une* constante ; tout le reste du système est
   identique quelle que soit la réponse.

2. **Les surfaces chaudes conviennent-elles à Delivery ?** Le crème `#FDF6EE` porte le
   « lien de quartier » d'une application de promotions. Delivery affiche des dettes, des
   montants à encaisser et des preuves de livraison — un fond plus neutre se défend. À
   regarder à l'écran, pas à trancher sur le papier.

3. **Faut-il un vérificateur de plus ?** Nos cinq contrôles ne savent rien du thème. Un
   `check_theme.dart` qui refuse un `Color(0x…)` hors de `lib/theme/` fermerait le seul
   trou que ce lot pourrait rouvrir. À décider une fois le lot appliqué, pas avant — un
   contrôle écrit sur une cible mouvante ne prouve rien.

⚠️ **Et une limite de cette lecture, à connaître avant d'y appuyer une décision : je n'ai
jamais vu ces écrans.** Tout ce qui précède est mesuré sur le code — valeurs, ratios,
comptages — et rien n'est jugé sur le rendu. Le document décrit un système, pas une
apparence.

---

# Appliqué — Echango Delivery, 02/08/2026

Décision retenue : **une teinte propre à Delivery, tout le reste hérité** (option 1 du
§10). Ce qui suit est ce qui a réellement changé, et ce qui a été délibérément laissé.

## La teinte, choisie par contrainte

**`#4338CA`** en thème clair — un indigo. Le choix n'est pas un goût, il tient à trois
contraintes énoncées avant de chercher une couleur :

1. **distincte des deux autres à l'œil** : terracotta ≈ 15°, teal ≈ 175°, indigo ≈ 245° —
   à peu près équidistante des deux, donc reconnaissable dans un tiroir d'applications ;
2. **lisible en aplat sous du texte blanc**, l'`AppBar` étant pleine couleur : **7,9 : 1**,
   au-dessus du seuil AAA (7) et pas seulement du seuil AA (4,5) ;
3. **complémentaire du safran**, qui reste l'accent commun à la famille.

Le safran `#F2A93B` est en effet **conservé tel quel** : chaque produit porte sa propre
teinte primaire, tous partagent le même accent chaud. La famille se reconnaît, les produits
se distinguent — ce qui est exactement l'intention que le commentaire de Promo énonce.

### ⚠️ Une seconde valeur en sombre, et c'est un test qui l'a imposée

Posé sur les deux thèmes, `#4338CA` produisait une `AppBar` **illisible** en sombre :
Material calcule alors `onPrimary = #2C2960`, un indigo foncé, soit **1,67 : 1**. La cause
est une convention qu'on enfreignait sans la voir — en thème sombre, `primary` est censé
être une teinte *claire* et `onPrimary` une teinte foncée ; forcer un primaire sombre
laisse `onPrimary` foncé lui aussi.

Rien ne compilait différemment, rien n'était `null` : la couleur était simplement fausse.
**C'est `test/theme_test.dart` qui l'a trouvé, à son tout premier lancement**, et c'est la
meilleure justification de son existence.

Le remède tient les deux contraintes, chacune vérifiée par un test qui tire dans un sens
différent :

| | clair | sombre |
|---|---|---|
| teinte | `#4338CA` | `#5B52E8` |
| texte blanc sur la marque (≥ 4,5) | 7,9 | **5,50** |
| marque détachée du fond (≥ 3) | 5,2 | **3,41** |

Les deux teintes ont la **même** teinte HSL à moins de 5° près — deux valeurs, une seule
couleur —, et un test le refuse si elles divergent.

⚠️ **Promo court le même risque** : il pose sa teinte unique sur les deux thèmes sans
redéclarer `onPrimary`. Son terracotta est simplement assez clair pour que ça passe. Le
signaler vaut mieux que de le taire — c'est le genre de défaut qui ne se voit qu'en
basculant le téléphone en sombre.

## Ce qui a été repris

| | |
|---|---|
| **Typographie** | Cairo (titres) + IBM Plex Sans Arabic (corps), échelle complète avec interlignes |
| **Rayons** | `chip` 8 · `control` 16 · `card` 24 — **transposés par affectation** |
| **Surfaces** | teintées, jamais neutres : `#F3F2FC` / `#111021` |
| **Cartes** | élévation 0, bordure `outlineVariant`, `margin: zero` |
| **`AppBar`** | pleine couleur de marque, **sur les deux thèmes** |
| **Puces** | rayon discret, bordure au repos |
| **Erreurs** | `#D6303D` / `#F87171`, hérités sans modification |

**Les polices sont embarquées, pas téléchargées** — la seule correction apportée au système
d'origine. Cairo n'existant en amont qu'en police variable, les trois graisses ont été
instanciées (`fontTools.varLib.instancer`, `wght=400|600|700`), et la couverture arabe,
latine et chiffres arabes-indiens a été relue sur les quatre fichiers. ~970 ko dans l'APK,
licences OFL comprises, contre une dépendance de plus et un repli invisible hors ligne.

## Ce qui n'a **pas** été repris, et pourquoi

- **Le jeton `pill` (999).** Promo l'emploie pour son badge « -X% » ; nous n'avons aucune
  pastille, donc il n'aurait **aucun appelant**. Un jeton sans appelant est exactement le
  défaut de la règle 9 — il s'ajoutera avec le premier badge.
- **La constante de mouvement (180 ms, easeOut).** Même raison, et je l'avais d'abord
  écrite avant de me raviser : l'application **n'anime rien** — aucune `Duration` courte,
  aucun `AnimatedSwitcher`, aucun `Tween`. La décision est consignée **ici**, où une
  décision peut attendre son usage ; en constante, elle aurait fait croire qu'elle
  s'applique. La règle, quand la première animation arrivera : **180 ms, `easeOut`, aucune
  animation à ressort.**
- **Leur absence de jetons d'espacement**, leurs couleurs sémantiques réduites, et leur
  organisation par *features* — les trois raisons sont au §9.
- **Leur `InputDecorationTheme`**, qui ne pose qu'un `border` et un `fillColor`. Le nôtre
  pose ses **cinq états** ; le reprendre tel quel rouvrirait le défaut du 01/08 où un champ
  n'avait de contour ni au repos ni au focus.

## Le contrôle qui manquait

`test/theme_test.dart` — **17 cas qui comparent les deux thèmes**, ce que personne ne fait
en relisant. Chacun des cas du groupe « les deux thèmes ne divergent pas » correspond à une
divergence **réellement constatée** : boutons absents du sombre, onglets absents du sombre,
`AppBar` grise en sombre, champs sans contour de focus.

Éprouvé par **trois mutations du vrai fichier**, et il refuse les trois : retirer
`onPrimary`, retirer la bordure des cartes, faire passer le corps en police de titre.

⚠️ **Deux tests ont dû être réécrits pendant le lot**, et c'est instructif : ils
affirmaient « la marque est la même sur les deux thèmes » et « les onglets ont la même
couleur des deux côtés » — deux énoncés que le correctif de contraste a rendus **faux**. Un
test écrit contre l'état d'avant fige cet état : il devient rouge quand on corrige. La
règle qu'ils portent maintenant est la bonne — *chaque thème suit **son** primaire*, et *les
deux teintes restent le même indigo*.

## Ce qui reste, et qui demande un écran

1. **Rien n'a été regardé.** `flutter analyze` est à 0, les 76 tests passent, mais **aucun
   de ces écrans n'a été ouvert**. Tout ce lot est vérifié par mesure, pas par le rendu — et
   un système de design se juge à l'écran.
2. **Les surfaces teintées, en particulier.** Le crème de Promo porte le « lien de
   quartier » ; un fond légèrement violacé sur une application qui affiche des dettes est le
   point le plus discutable du lot. Une constante à changer si le rendu ne convainc pas.
3. **Un `check_theme.dart`** qui refuserait un `Color(0x…)` hors de `lib/theme/`. À écrire
   une fois le rendu validé, pas avant : un contrôle écrit sur une cible mouvante ne prouve
   rien.
