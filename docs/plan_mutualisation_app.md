# Plan de mutualisation — ce qui reste, mesuré le 01/08/2026

## La contrainte qui prime sur tout le reste

**Refonte interne à contrat constant.** Aucun écran ne change d'aspect, aucun
libellé ne change de mot, aucune règle métier n'est retouchée. Chaque lot doit
pouvoir être prouvé **par inversion** : resubstituer ce qui a été extrait doit
redonner la version précédente, au caractère près. C'est la seule preuve qui
distingue un renommage d'une modification, et sans elle un lot de cette taille
est impossible à relire — leçon du lot des jetons d'espacement (320 sites).

Le lot 3 est la seule exception, et elle est nommée dans sa fiche.

## D'où viennent ces chiffres

Mesurés sur le code du 01/08/2026, pas de mémoire :

| mesure | valeur |
|---|---|
| `Colors.*` / `Color(0x…)` dans `screens/` et `widgets/` | **0** |
| enveloppes HTTP dans `bff_api_client.dart` | **86** méthodes, 1620 lignes |
| `Card(` bruts dans les écrans, alors qu'`AppSectionCard` existe | **21**, dans 13 fichiers |
| `AlertDialog` de confirmation | **10**, dans 6 fichiers |
| `TextField` bruts | **22**, dans 12 fichiers |
| `CircularProgressIndicator` | **21**, dans 16 fichiers |
| couples de corps ≥ 90 % côté TypeScript | **7** |
| chaînes visibles en dur | **335** (commerçant 186, transporteur 100, auth 17) |
| littéraux d'espacement hors barème | **21** (assumés) |

Le détecteur de corps similaires est l'outil qui compte : le 31/07 il avait
trouvé **trois défauts sur quatre** que le `grep` sur les formules d'aveu
(« doit rester identique à ») ne voyait pas. Une copie muette ne s'annonce pas.

---

## Lot 1 — Les enveloppes HTTP (86 méthodes)

**Ce que c'est.** `bff_api_client.dart` répète 86 fois la même séquence :
construire l'URI, poser les en-têtes, appeler, passer la réponse à
`_parseResponse`. Le détecteur trouve des couples à **100 %**. Seule la
**projection** qui suit diffère (`as Map`, `as List`, `Model.fromJson`, rien).

**Pourquoi c'est un défaut et pas une répétition saine.** Le critère de la
règle 5 : *si l'un change, l'autre doit-il changer ?* Ajouter un délai maximal,
une reprise réseau, un rafraîchissement de jeton ou un en-tête de traçage
demande aujourd'hui de toucher **86 endroits** — et d'en oublier un ne produit
aucune erreur, seulement un appel qui se comporte autrement que les autres.

⚠️ Le 31/07 j'avais conclu que cette répétition était « contrôlée plutôt que
supposée saine », au motif qu'une seule méthode ne vérifiait pas sa réponse.
Le contrôle était juste et la conclusion fausse : vérifier que 86 copies
s'accordent aujourd'hui ne dit rien de ce qui se passe à la 87ᵉ.

**Ce qu'on écrit.** Quatre helpers privés — `_get`, `_post`, `_put`, `_delete` —
qui font URI + en-têtes + appel + `_parseResponse`, et rendent `dynamic`. Chaque
méthode publique garde **sa seule projection**.

**Ce qu'on ne touche pas.** `_parseResponse`, `_buildHeaders`, la gestion des
erreurs, et `logout` — dont l'absence de vérification est l'exception
documentée (sa route n'existe pas côté BFF, vérifié).

**Ce qui débloque le lot** :
1. `flutter analyze` vert ;
2. **preuve par inversion** : réécrire chaque appel de helper en sa séquence
   d'origine redonne le fichier d'avant, au caractère près ;
3. les 86 chemins listés, chacun avec sa méthode HTTP et son URI **inchangés** —
   comparés avant/après par extraction automatique, pas à l'œil.

**Gain attendu** : ~400 lignes, et un seul endroit pour le jour où il faudra un
délai ou une reprise.

---

## Lot 2 — Les 21 `Card(` bruts

**Ce que c'est.** `AppSectionCard` existe depuis le 31/07 et porte la densité,
la marge et le rayon. 21 écrans posent encore un `Card(` nu — dans les trois
profils, y compris ceux écrits après.

**Pourquoi ça compte.** Ce n'est pas de la dette théorique : c'est une
**incohérence visible**, deux cartes côte à côte n'ayant pas la même marge. Et
c'est exactement le défaut que le composant existe pour empêcher.

**Le piège à éviter.** Tous les `Card(` ne sont pas des cartes de section :
certains sont des lignes de liste (`Card > ListTile`), qui ont leur propre
densité. Chaque site se juge — la conversion mécanique de masse est refusée ici.

**Ce qui débloque le lot** : `flutter analyze`, plus un relevé site par site
disant lequel est converti et **lequel ne l'est pas, avec la raison**. Une
conversion silencieusement partielle serait pire que rien : on croirait le
chantier clos.

### Ce que la mesure a donné — le lot n'était pas celui qu'on croyait

**Zéro `Card(` est devenu un `AppSectionCard`, et c'est le résultat correct.**
Le plan supposait que certains des 21 sites étaient des cartes de section mal
écrites. Ils ne le sont pas : les **deux seuls** qui ont la forme
`Card > Padding` sont précisément les **deux exceptions que la documentation
d'`AppSectionCard` nomme déjà** (`xl` sur la carte de profil transporteur,
`symmetric` sur le sélecteur de motif d'échec). Elles avaient été écartées à
l'écriture du composant, pour la raison qui y est écrite : les faire entrer par
un paramètre `padding` rouvrirait ce que le composant vient de fermer.

En revanche la mesure a trouvé **autre chose**, et de plus lourd : le même
message d'interface écrit de **trois** façons sur **douze** sites.

**Converti — 12 sites, vers le nouveau `AppNotice`** :

| site | forme d'origine | ton |
|---|---|---|
| `commercant/order_detail_screen` ×5 | `_banner(Color, IconData, String)`, helper privé | info, warning, progress, success, muted |
| `commercant/create_order_screen:469` | `Container` + `BoxDecoration`, sans icône | info |
| `flotte/flotte_order_detail_screen:305` | `Card(errorContainer) > ListTile` + retry | error |
| `flotte/flotte_order_detail_screen:325` | `Card(secondaryContainer) > ListTile` | info |
| `flotte/memberships_tab:133` | `Card(errorContainer) > ListTile` | error |
| `transporteur/my_fleets_screen:146` | `Card(errorContainer) > ListTile` + retry | error |
| `transporteur/my_fleets_screen:158` | `Card()` sans couleur `> ListTile` | info |
| `transporteur/order_detail_screen:189` | `Card(secondaryContainer) > ListTile` titre+sous-titre | info + `title` |

⚠️ **C'est la seule extraction du lot qui n'est pas à aspect constant**, et
c'est délibéré : les six `Card > ListTile` perdent leur élévation et leur marge
Material par défaut au profit du bandeau plat que le commerçant employait déjà.
On aligne les profils entreprise et transporteur sur le commerçant — ce qui est
exactement ce qui a été demandé après le constat « le thème entre le commerçant
et le facilitateur est différent ».

**Le site le plus parlant est le douzième** : `create_order_screen` expliquait le
mode brouillon en `primaryContainer` sans icône, et `order_detail_screen` disait
**la même chose** en `secondaryContainer` avec une icône, à une navigation
d'intervalle. Personne ne l'avait décidé.

**Non converti — 15 sites, avec la raison** :

| sites | pourquoi |
|---|---|
| `cash_screen:217`, `cash_screen:1071`, `addresses_screen:118`, `favourite_drivers_screen:204/241/270`, `orders_screen:217`, `dashboard_screen:352`, `my_fleets_screen:193` (9) | **lignes de liste** (`Card > ListTile`) : une densité et une marge verticale qui leur sont propres, souvent tapables. `AppSectionCard` doublerait le retrait interne, `AppNotice` supprimerait l'affordance. |
| `dashboard_screen:451`, `delivery_failure_screen:103` (2) | les **deux exceptions déjà documentées** dans `AppSectionCard` (`xl`, `symmetric`). |
| `create_order_screen:644` | affiche un **montant** en `titleLarge` : ce n'est pas un message mais une valeur, et la convertir la rétrécirait. |
| `map_picker_screen:243` | enveloppe **flottante** d'une liste de suggestions au-dessus de la carte — ni section, ni message. |
| `commercant/order_detail_screen:305` (`_driverCard`) | carte **interactive** (bouton d'appel) sur deux lignes. |
| `commercant/order_detail_screen:580` (`_favouriteCard`) | ligne de **navigation** (`onTap`). |

### Deux trouvailles hors périmètre, faites en cherchant les `Card(`

**(a) `AppErrorBanner` avait un site manqué.** Le tableau de bord transporteur
posait son bandeau d'erreur à la main — `Container(width: infinity, color:
errorContainer, padding: all(md))` avec le texte en `onErrorContainer`, soit le
composant réécrit à l'identique **moins son icône**. Converti. C'est un reliquat
du lot du 31/07, et il illustre pourquoi le relevé compte : le composant
existait, l'écran ne l'appelait pas.

**(b) Un second `_banner` privé, avec une autre signature.** `dashboard_screen`
en a un aussi — `_banner(String text, Color bg, Color fg)`, trois appels — alors
que celui du commerçant était `_banner(Color, IconData, String)`. Deux fichiers,
deux helpers privés, deux ordres d'arguments, pour la même idée.

⚠️ **Il n'est pas converti, et la raison n'est pas la paresse** : c'est une
**bande pleine largeur en tête de page**, pas un message dans le flux — donc ni
un `AppNotice` (arrondi, en retrait, dans le contenu) ni un `AppErrorBanner`
(rouge uniquement), et ses trois branches portent trois tons dont un seul est
une erreur. N'en convertir qu'une la rendrait différente de ses deux sœurs, ce
qui est pire que trois copies cohérentes. **C'est un motif à part entière — une
bande d'état de page — et il n'a qu'un seul site.** À extraire le jour où un
deuxième apparaît, pas avant.

⚠️ **Et il emploie `surfaceContainerHighest`** (`dashboard_screen.dart:197`),
arrivé en **Flutter 3.22**, alors que `pubspec.yaml` déclare `flutter:
'>=3.20.0'`. `flutter analyze` est vert parce qu'il s'exécute contre le SDK
**installé**, plus récent — la borne déclarée, elle, est fausse. Deux
résolutions cohérentes, et une seule ligne à changer : retirer l'API, ou monter
la borne à `>=3.22.0` pour qu'elle dise la vérité. **Laissé tel quel** : je ne
connais pas la version réellement installée, et écrire une borne au jugé
remplacerait une déclaration fausse par une autre.

**Également examiné et laissé** : le bloc « À encaisser » de
`transporteur/order_detail_screen:117` (`Container` + `BoxDecoration`,
`warningContainer`) a la forme d'un `AppNotice.warning` avec titre — mais son
titre *est un montant*, en `titleMedium` gras. Le convertir le passerait en
`titleSmall`. Rétrécir un chiffre d'argent en silence est le genre de
« refactorisation » qui ne se voit qu'à la porte du destinataire.

---

## Lot 3 — Le dialogue de confirmation (10 sites)

**Ce que c'est.** Dix `AlertDialog` de la même forme : un titre, une phrase, un
bouton de retour, un bouton d'action. Répartis sur 6 fichiers, avec des ordres
de boutons et des tons qui ne s'accordent pas.

**⚠️ Le seul lot qui n'est PAS à contrat constant, et c'est délibéré.** Le
composant portera sa règle, comme `AppEmptyState` porte sa consigne : **l'action
destructive ne se met pas sous le pouce**, à l'endroit qu'on touche sans
regarder. Certains dialogues devront donc changer d'ordre. C'est une décision
d'ergonomie, à valider à l'écran avant d'être appliquée aux dix.

**Ce qu'on écrit.** `AppConfirmDialog(title, message, confirmLabel, cancelLabel,
{destructive = false})`, rendant `Future<bool>`.

**Ce qui débloque le lot** : les dix sites relevés avec leur ordre actuel, la
règle tranchée avec vous, puis `flutter analyze` et un passage à l'écran.

### Le relevé a démenti la fiche — l'ordre s'accordait, le ton non

**Les dix `AlertDialog` étaient dans le même ordre** : `[retrait à gauche,
action à droite]`, sans exception. La phrase « des ordres de boutons et des tons
qui ne s'accordent pas » était fausse pour moitié, et c'est la moitié sur
laquelle le lot promettait de changer quelque chose.

**Ce qui divergeait, c'est le ton — et dans le mauvais sens :**

| dialogue | action | bouton avant |
|---|---|---|
| `addresses:78` | supprimer une adresse | `TextButton` — **identique** au « Retour » |
| `order_detail:46` | annuler une livraison (« cette action est définitive ») | `TextButton` — identique au « Retour » |
| `dashboard:521` | se déconnecter | `TextButton` — identique à « Annuler » |
| `cash:536` / `570` | contester un encaissement / une remise | `TextButton` ×2 |
| `my_fleets:84` | **quitter une entreprise** | `FilledButton` — l'affordance de l'action *recommandée* |

Autrement dit **l'insistance visuelle suivait l'écran où l'on se trouvait, pas
l'enjeu** — même motif que les dix refus affichés comme des confirmations,
corrigés le 31/07 par `showAppOutcome`. Et `AppButtonStyles.destructive*`
existait depuis le 31/07 : employé à **sept endroits dans les pages, zéro dans
les dix dialogues**. La convention s'arrêtait à la frontière du dialogue.

**Décision retenue (vous, 01/08)** : *marquer le ton, garder l'ordre*. Éloigner
l'action destructive du pouce protégerait d'un appui sans regarder, mais
créerait **deux dispositions selon le dialogue** — une nouvelle incohérence, à
l'inverse de la convention Material. Le lot redevient donc à **disposition
constante** : seule la couleur change.

**`AppConfirmDialog` porte trois règles** :

1. **Deux constructeurs nommés, aucun défaut** (`destructive` / `neutral`). Les
   six confirmations du dépôt sont *toutes* destructives — un
   `destructive: false` par défaut ne serait exercé nulle part, et le premier
   dialogue ordinaire ajouté hériterait du rouge. Même raisonnement
   qu'`AppEmptyState.unavailable`.
2. **`false` sur un rejet.** `showDialog` rend `null` quand on tape à côté ; les
   six sites écrivaient ce garde à la main, en **deux orthographes**
   (`confirmed != true`, `confirmed ?? false`). Un `bool` non nullable le retire
   des six.
3. **L'action se nomme** (« Supprimer », « Annuler la livraison »), jamais
   « OK » : sur un dialogue dont le titre est une question, « Oui » oblige à
   relire la question pour savoir ce qu'on approuve.

**Converti — 6 sites.** **Non converti — 4, avec la raison** : `cash:888`
(`_AmountDialog`), `cash:1336` (`_DriverPicker`) et `flotte:537`
(`_NewDriverDialog`) sont des **formulaires**, qui rendent une valeur et non un
booléen ; `addresses:341` (« Remplacer l'adresse ? ») est un **choix entre deux
égaux** — « Garder mon texte » n'est pas un retrait, et peindre « Remplacer » en
rouge dramatiserait un champ réécrit, pas perdu.

⚠️ **Pas de `check_dialogs.dart`, et c'est le critère de la règle 6** : le motif
**porte une règle**, donc un composant qui la porte suffit — et ici c'est le
**compilateur** qui la tient (constructeurs nommés, `bool` non nullable). Les
boutons avaient besoin d'un contrôle parce que le motif n'était qu'un *choix*.
Aucun des autres composants partagés (`AppNotice`, `AppEmptyState`,
`AppErrorBanner`) n'a de contrôle non plus, pour la même raison.

---

## Lot 4 — Le champ de saisie (22 sites)

**Ce que c'est.** 22 `TextField` bruts dans 12 fichiers, chacun redéclarant son
`InputDecoration` : bordure, densité, icône. Le thème en porte déjà une partie
(`inputDecorationTheme`), donc la divergence n'est pas totale — c'est ce qui
reste au-dessus qui diverge.

**À mesurer avant d'écrire** : combien de ces 22 sites diffèrent réellement une
fois le thème retiré. Si la réponse est « deux ou trois », le lot se réduit à
aligner ces trois-là et **le composant ne doit pas être écrit** — envelopper
`TextField` pour n'y rien ajouter serait réécrire l'API de Material, exactement
ce qui a été refusé pour les boutons.

**Ce qui débloque le lot** : cette mesure. Elle peut le clore sans une ligne.

### La mesure a dit l'inverse — et le remède n'était pas un composant

**25 `InputDecoration` dans le dépôt** (22 `TextField`/`TextFormField`, plus
trois champs de formulaire d'un autre type). Les clés employées :

| clé | sites | nature |
|---|---|---|
| **`border`** | **21** | **apparence du cadre** |
| `labelText` | 19 | contenu |
| `prefixIcon` | 16 | contenu |
| `isDense` | 9 | densité |
| `hintText` | 6 | contenu |
| `suffixIcon` | 4 | contenu |
| `helperText` | 3 | contenu |
| `suffixText` | 1 | contenu |

**Les 21 passaient tous un `OutlineInputBorder()` nu**, qui **écrase** celui du
thème. L'application avait donc deux apparences de champ : 21 à contour visible
et coins de 4 px (le défaut Material), 4 remplis sans contour à coins de 8 px.
Et les quatre étaient **tous dans le profil entreprise** — exactement le motif du
lot des boutons : ce profil suit le thème, les deux autres se peignent eux-mêmes.

⚠️ **Mais retirer les 21 aurait uniformisé vers le pire des deux états.** Le
thème posait `borderSide: BorderSide.none` et **rien d'autre** — pas de
`focusedBorder`. Un champ n'avait donc de contour ni au repos **ni au focus** :
le seul signal restant était la couleur du libellé. Les 21 surcharges
compensaient un défaut du thème sans le savoir. C'est le cas où « remettre la
décision au thème » est juste **et** insuffisant : il faut d'abord que le thème
décide correctement.

**Ce qui a été fait, dans cet ordre** : (1) `_inputDecorationTheme(scheme, fill:,
hint:)`, partagé par les deux thèmes — le thème sombre n'avait pas de contour de
focus non plus, et une divergence de plus là n'aurait été vue par personne — avec
les **cinq états posés explicitement** plutôt que laissés au repli de
`InputDecorator`, dont la façon de dériver `focusedBorder` d'un `border` à
`BorderSide.none` n'est pas vérifiable ici ; (2) les 21 surcharges retirées.

**Aucun composant écrit**, et c'est le critère de la règle 6 : le motif **est
déjà un widget**. Envelopper `TextField` demanderait de réexposer `controller`,
`keyboardType`, `maxLines`, `onChanged`, `onSubmitted`, `textInputAction`… pour
n'y rien ajouter — la faute exactement nommée à propos des boutons. Ce qui
manquait n'était pas un composant, c'était une **décision**, plus un contrôle
qui la tienne.

**`tool/check_inputs.dart`** refuse les six clés de bordure hors de `lib/theme/`.
16 cas de `--self-test` dont **8 refus**, et — parce que des cas fabriqués ne
voient que ce qu'on imagine — **une mutation des vrais fichiers** : les onze
versions d'avant sont resignalées, avec le compte exact des surcharges retirées
(2+4+2+1+4+1+1+1+1+1+3 = 21). Il **recense** au passage les 9 `isDense: true`
sans échouer : la divergence est réelle mais la corriger déplacerait des pixels
sur le plus gros formulaire de l'application — décision de design, comme les
littéraux hors barème de `check_spacing`.

⚠️ **Ce que le contrôle ne sait pas voir, et qui est écrit dans son en-tête** :
une bordure passée par une variable (`border: maBordure`). Accepter n'importe
quelle valeur ferait signaler `BoxDecoration(border: Border.all(…))`, légitime
et sans rapport. Aucune forme par variable n'existe aujourd'hui — le dire vaut
mieux que laisser croire à une couverture complète.

---

## Lot 5 — Les indicateurs d'attente (21 sites)

**Ce que c'est.** 21 `CircularProgressIndicator` et 10 `RefreshIndicator`.

**Ce qu'il faut vérifier avant de conclure à une duplication.** Un indicateur
dans un bouton, un autre au centre d'une page, un troisième dans un pied de
liste : ce sont trois choses différentes, et `AppLoadMore` couvre déjà le
troisième. Le lot n'existe peut-être pas.

**Ce qui débloque le lot** : le relevé par contexte. Le résultat attendu est
« rien à faire », et il faut pouvoir le dire avec un chiffre.

### Le relevé — et le résultat attendu était le bon, pour la mauvaise raison

**22 occurrences, dont une dans un commentaire de documentation** (`app_spacing`
cite le motif pour expliquer ce qui *n'est pas* un intervalle) : **21 réelles**,
dans quatre contextes qui ne se ressemblent que de nom.

| contexte | sites | tailles | verdict |
|---|---|---|---|
| **dans un bouton** — remplace le `child:` ou l'`icon:` | 6 | 20 (`child:`) ×4, 18 (`icon:`) ×2, `strokeWidth: 2` partout | mapping **parfaitement cohérent** : rien ne diverge |
| **en ligne, à côté d'un contrôle** — action de ligne, `suffixIcon`, libellé de devis, bascule de présence | 4 | 16, 16, 12, 18 | quatre emplacements différents, quatre tailles dictées par l'emplacement |
| **centré sur une page ou une section** | 10 | par défaut | `Center(child: CircularProgressIndicator())`, non stylé |
| **pied de liste** | 1 | par défaut | c'est déjà `AppLoadMore` |

**Rien à extraire, et le critère le dit.** `Center(child:
CircularProgressIndicator())` ne porte **ni règle ni décision** — c'est le défaut
Material, sans couleur, sans épaisseur, sans taille. L'envelopper dans un
`AppLoading` serait la faute que la règle 6 nomme au sujet des boutons :
réécrire l'API de Material pour n'y rien ajouter. Aucune divergence non plus :
les six formes en bouton s'accordent, et les quatre formes en ligne diffèrent
parce que leurs emplacements diffèrent.

**Mais le relevé a trouvé autre chose**, et c'est la vraie question que ces 21
sites posaient : **quand un indicateur a-t-il le droit de remplacer le
contenu ?** Huit des dix indicateurs « pleine page » sont gardés par une
condition ; trois ne l'étaient pas, et chacun produisait un défaut distinct.

| site | garde | défaut |
|---|---|---|
| `cash_screen:158` | `isLoading && ledger == null` | ✅ |
| `commercant/order_detail:128` | `isLoading && selected == null` | ✅ |
| `driver_map:99` | `positions.isEmpty` puis `loading` | ✅ |
| `flotte_home:148` | `isLoading && orders.isEmpty` | ✅ |
| `my_fleets:135` | `_loading`, **jamais relevé** après le premier chargement | ✅ de fait — soupçonné, vérifié, innocent |
| `transporteur/order_detail:45` | `isLoading` seul | ❌ `OrderState._isLoading` est levé par **toutes** les écritures : accepter, démarrer, refuser, envoyer la preuve. Chaque appui effaçait l'écran entier — adresse, montant à encaisser, position de défilement — et l'envoi d'une photo le laissait vide plusieurs secondes. |
| `favourite_drivers:139` | `_loading` seul | ❌ **tirer pour recharger effaçait la liste** : un second indicateur sous celui que `RefreshIndicator` dessine, et l'enfant cessait d'être défilable au milieu du geste qui en dépend. Sa `ListView` n'avait par ailleurs **pas** d'`AlwaysScrollableScrollPhysics` — seul `RefreshIndicator` du dépôt dans ce cas —, donc sur deux favoris, le cas courant, le geste ne partait pas. |
| `addresses_screen` | **aucune** | ❌ affirmait « aucune adresse enregistrée » pendant tout l'aller-retour, et **définitivement** quand la lecture échouait : `loadAddresses` avale son erreur et laisse le carnet vide. Règle 10, et le troisième site de cette forme après « aucun conducteur rattaché ». |

**Corrigé** : garde sur « rien à montrer » aux trois sites, `_addressesUnavailable`
sur `MerchantOrderState` (même forme que `FleetState.driversUnavailable`, et pour
la même raison), et `AppEmptyState.unavailable` avec sa reprise sur le carnet.
Sur la fiche transporteur, l'attente s'affiche désormais **là où l'action part** —
l'indicateur remplace le bloc de boutons, ce qui est la règle que porte déjà
`AppLoadMore`.

**Corrigé aussi, trouvé en passant** : le commentaire d'en-tête d'`addresses_screen`
affirmait que les filtres de `/orders` et `/drivers` sont « ignorés
silencieusement » — démenti le 29/07/2026, c'étaient des noms de paramètre
inexistants.

---

## Lot 6 — Les enveloppes Fleetbase (7 couples, TypeScript)

**Ce que c'est.** `fleetbase-api.client.ts` répète `try / await callFleetOps /
return response.data / catch → log → throw`. Six couples ≥ 90 %. Plus un
septième dans `commercant.controller.ts` : `getOrderProof` ≈ `getFailureProof`
à 95 %, deux routes qui lisent une image et la renvoient.

**Pourquoi séparément du lot 1.** Ce sont deux fichiers, deux langages, deux
jeux de tests. Les mêler rendrait un échec ambigu.

**Ce qui débloque le lot** : `npx tsc --noEmit`, `npx jest` (85 tests) et
`npm run build` verts — tous exécutables ici, contrairement au Dart.

---

## Lot 7 — Les 335 chaînes en dur

**En dernier, et pour une raison précise** : c'est le seul lot qui ne peut pas
produire de défaut. Une chaîne française dans un écran français ne ment pas ;
elle gêne l'arabophone, et rien d'autre. Les six lots précédents portent des
défauts possibles.

**Découpage proposé**, un écran à la fois, du plus coûteux au moins :

| écran | chaînes | pourquoi ce rang |
|---|---|---|
| `commercant/create_order_screen` | ~60 | c'est là qu'on saisit ce qui engage de l'argent |
| `commercant/order_detail_screen` | ~50 | preuve, échec, annulation : ce qui se conteste |
| `transporteur/order_detail_screen` | ~45 | la porte, la preuve, l'échec |
| `transporteur/dashboard_screen` | ~30 | l'écran qu'un conducteur voit le plus |
| le reste | ~150 | listes, carnets, favoris |

**La méthode est éprouvée** (lot caisse, 31/07) : une table par langue, des
`{variable}` plutôt que des concaténations, et la conversion prouvée par
resubstitution — chaque chaîne retirée doit se retrouver dans la table.

**Ce qui débloque chaque écran** : parité FR/AR par `check_error_codes`, zéro
littéral français visible restant, et toutes les clés employées déclarées.

### Les trois écrans restants, en une passe (01/08/2026)

**Fini : zéro chaîne d'interface en dur dans `lib/screens/` et `lib/widgets/`.**
Le relevé final signale 24 littéraux, **tous vérifiés faux positifs** : formats
monétaires sans mot, clés JSON, URL de tuiles OSM, un `debugPrint`, et vingt
artefacts d'extraction (une quote imbriquée dans `${t('clé')}` coupe le
littéral en deux).

**Six tables, 569 clés, parité stricte partout** — trois existaient, trois sont
nées ici, et **le découpage suit le critère de la règle 5 et non la
commodité** :

| table | clés | domaine |
|---|---|---|
| `order_strings` | 269 | **une livraison** — formulaire, les deux fiches, les deux listes, carnet, favoris, carte, notifications, échec |
| `fleet_strings` | 120 | l'espace entreprise |
| `cash_strings` | 115 | le registre de caisse |
| `driver_strings` | 34 | **l'espace transporteur** — onglets, présence, profil, véhicule |
| `auth_strings` | 18 | connexion et inscription |
| `common_strings` | 13 | l'ossature — « Réessayer », « Annuler », « Retour », photo, langue |

`driver_strings` est séparée d'`order_strings` pour la raison qui a fait
fusionner les deux premières : si un onglet du conducteur change, aucune fiche
de livraison ne bouge. Le critère répond non, donc deux tables.

⚠️ **Une troisième duplication règle 5, dans les composants partagés
eux-mêmes** : **« Réessayer » était écrit trois fois**, en repli de `retryLabel`
dans `AppEmptyState`, `AppErrorBanner` et `AppNotice` — trois copies du même mot
dans les trois widgets dont le rôle est justement d'empêcher ça.

⚠️ **Et l'extracteur lui-même était faux.** Il exigeait une espace, un accent ou
une ponctuation, donc il **ne voyait pas `'Refuser'`, `'Annuler'`,
`'Publier'`** — des mots seuls, sans accent, parfaitement visibles à l'écran.
Réécrit **par exclusion** (on rejette ce qui est reconnaissablement un
identifiant, on accepte le reste), et les deux écrans déjà convertis ont été
**re-mesurés** avec la version corrigée. C'est la règle 8 dans son cas le plus
gênant : le contrôle qui a servi à déclarer deux lots terminés ne voyait pas
tout.

**Trouvé au passage, non traité** : `delivery_failure_screen` était encore **en
anglais** sur quatre libellés (« Report Delivery Failure », « Failure Reason »,
« Additional Notes (Optional) », « Report the reason for delivery failure ») —
reliquat du scaffolding du 27/07, jamais francisé. Ils sont traduits ici, ce qui
explique quatre des sept chaînes « absentes » du contrôle de resubstitution.

**Preuve par resubstitution, dernier lot** : 220 chaînes retirées, **182
retrouvées à l'identique**, **23 à l'apostrophe près** (`'` → `’`), 7 absentes
et toutes expliquées — les 4 anglaises ci-dessus, 2 formats monétaires dont la
devise entre désormais dans la variable `{amount}`, et 1 artefact d'extraction.

⚠️ **50 défauts de `const` et une garde de portée, tous trouvés par les
contrôles.** Cinquante contextes `const` contenant un appel de traduction —
`Text`, `InputDecoration`, `AppEmptyState`, `TabBar`, une liste `const [`, une
map `const _options = {` — dénoués mécaniquement, en **re-constifiant les
enfants littéraux** (`Icon`, `EdgeInsets`, `TextStyle`) pour ne pas remplacer
cinquante erreurs par cinquante `prefer_const_constructors`. Et la garde de
portée par classe, écrite pour l'écran 2, a servi ici sur 26 fichiers ; elle a
d'abord produit **quatorze faux positifs** sur les écrans du profil entreprise,
qui reçoivent leur `t` en champ, en paramètre ou par liaison locale — corrigée,
puis **éprouvée sur une mutation** qui retire un helper d'une classe qui
l'emploie.

⚠️ **L'arabe des trois nouvelles tables est de ma main, non relu par un
locuteur.**

### Écran 2 — `commercant/order_detail_screen` (01/08/2026)

**La table a d'abord été fusionnée.** Sept libellés de la fiche existaient déjà
dans celle du formulaire (`Retrait`, `Livraison`, `Colis`, `Enlèvement`, `Dès que
possible`, `Preuve de livraison`, `Photo à la livraison`). Deux tables les
auraient recopiés — c'est le défaut nommé dans `fleet_strings` (« deux tables
recopiées ont affiché deux textes différents pour la même commande »), et le
critère de la règle 5 tranche : si l'un change, l'autre doit changer.
`order_form_strings.dart` devient donc **`order_strings.dart`**, le vocabulaire
d'une livraison, et les sept clés partagées passent de `order.form.*` à
`order.*` — un nom qui aurait menti sinon. **132 clés**, parité 132 = 132.

⚠️ **Et une duplication règle 5 trouvée en chemin, déjà divergente** : les six
motifs d'échec de livraison existaient **en deux copies**, et **trois libellés
sur six ne s'accordaient plus** —

| code | conducteur déclarait | commerçant lisait |
|---|---|---|
| `colis_refuse` | « Client a refusé le colis » | « Colis refusé par le client » |
| `acces_impossible` | « Accès impossible (site fermé, zone inaccessible) » | « Accès impossible » |
| `autre` | « Autre » | « Autre motif » |

Un seul endroit désormais : `deliveryFailureReasons` (la liste de codes) et
`deliveryFailureLabel()` dans `models/order.dart`, sur le modèle de
`cashDiscrepancyReasons` / `cashDiscrepancyLabel` — **le code part au serveur et
sera compté, le libellé est de la langue** ; les mêler dans une map fait itérer
sur du français pour bâtir un sélecteur. Arbitrage des trois : la formulation du
commerçant l'emporte sur deux (ce sont des constats de ce qui s'est passé), la
parenthèse du conducteur est conservée sur le troisième parce qu'elle informe
dans les deux contextes.

**Conversion prouvée par resubstitution** : 73 chaînes retirées, **59
retrouvées à l'identique**, **8 à l'apostrophe près**, 3 non retrouvées et
toutes expliquées — deux sont un artefact de normalisation (`'Montant demandé : '`
suivi d'un littéral interpolé, dont la devise entre désormais dans la variable
`{amount}`), la troisième est l'un des trois libellés d'échec délibérément
changés.

⚠️ **Dix défauts de `const` et un helper manquant, tous trouvés par les
contrôles et aucun à la lecture.** Sept `const Text(_t(…))`, deux
`const AppNotice.*`, un `const Padding(` — et surtout **`_DriverMapState`
appelait `_t` cinq fois sans le déclarer** : c'est une troisième classe dans le
même fichier, avec son propre `context`. Un contrôle de portée par classe a été
ajouté ; sans lui, la conversion aurait été livrée non compilable.

⚠️ **Trouvé en marge, non traité** : `transporteur/delivery_failure_screen`
contient encore **quatre chaînes en anglais** (« Report Delivery Failure »,
« Failure Reason », « Additional Notes (Optional) », « Report the reason for
delivery failure ») — reliquat du scaffolding du 27/07. Seuls ses motifs
d'échec ont été traités ici, parce qu'ils sont partagés ; le reste de l'écran
relève du lot « le reste ».

### Écran 1 — `commercant/create_order_screen` (01/08/2026)

**69 clés**, `lib/i18n/order_form_strings.dart`, enregistré dans
`check_error_codes.dart` (la liste des tables y est **explicite** et non un
balayage : un fichier renommé doit faire échouer le contrôle, pas passer au
vert). Parité FR/AR 69 = 69, aucun doublon, **69 employées et 69 déclarées** —
ni clé manquante, ni clé morte.

**Conversion prouvée par resubstitution** : 70 chaînes retirées de l'écran,
**63 retrouvées à l'identique** dans la table, **6 retrouvées à l'apostrophe
près** (`'` → `’`, alignement sur `fleet_strings` et `cash_strings`), 1 non
comparable — `'Il manque ${missing.join(', ')}'`, dont la quote imbriquée
arrête l'extracteur ; sa substitution a été vérifiée à la main.

⚠️ **Les 6 apostrophes sont comptées à part, et c'est obligatoire** : le
comparateur les normalise, donc **il ne peut pas les signaler**. Un contrôle qui
ne voit pas une modification ne dit rien d'elle (règle 8). Même relevé que pour
l'écran de caisse le 31/07.

**Zéro littéral français visible restant.** Ce qui subsiste est nommé : les
noms de champs de l'API, une route, et `'Commerce'` — repli de
`pickupContactName`, qui est une **donnée** envoyée au serveur et relue par le
transporteur, pas un libellé. La traduire ferait dépendre le contenu de la base
de la langue du téléphone qui a créé la commande.

⚠️ **Trois défauts de `const` trouvés au second passage, aucun à la lecture** —
et `flutter analyze` les aurait tous vus, ce qui dit exactement ce que vaut ce
bac à sable : 7 `const Text(_t(…))`, 2 `const InputDecoration(…)` et
**2 `const options = {…}`**. Les deux derniers avaient échappé au premier
contrôle, qui ne cherchait que `const <Majuscule>(` — une map constante n'a pas
cette forme. Le contrôle a été élargi aux listes, aux maps et aux déclarations
de variable, **puis éprouvé sur une mutation qui réintroduit chacun des deux
cas** : sans cette exécution, « il ne trouve rien » n'aurait montré que sa
capacité à se taire.

---

## Ordre, et pourquoi celui-là

**1 → 6 → 2 → 5 → 4 → 3 → 7.**

- **1 d'abord** : c'est le plus gros gain, le plus mécanique, et le seul
  entièrement prouvable par inversion.
- **6 juste après** : même nature, et il est **vérifiable ici** (`tsc`, `jest`,
  `build`), donc il ne dépend pas d'un aller-retour.
- **2 puis 5 puis 4** : trois relevés dont deux peuvent se clore sans code. Les
  faire avant le 3 évite d'écrire un composant qu'on n'aurait pas dû écrire.
- **3 avant-dernier** : il demande une décision d'ergonomie de votre part.
- **7 en dernier** : long, sans risque, et interruptible à tout moment.

## Ce que ce plan ne couvre pas, volontairement

- **Les 21 littéraux d'espacement hors barème.** Les glisser vers le jeton
  voisin déplacerait des pixels : c'est une décision de design, pas de
  refactorisation. `check_spacing.dart` en imprime le compte.
- **Les 28 couleurs de `lib/theme/`.** C'est leur place.
- **Le serveur au-delà du lot 6.** Les modules métier ont été passés au
  détecteur : aucun couple ≥ 90 % hors des enveloppes.

## Journal d'avancement

| lot | état | preuve |
|---|---|---|
| 1 — enveloppes HTTP | **fait** (01/08) | inventaire verbe/chemin/query/corps identique HEAD↔courant, 86 appels ; 1620 → 1371 lignes |
| 2 — `Card(` bruts | **fait** (01/08) | 12 sites vers `AppNotice`, 1 vers `AppErrorBanner`, **0** vers `AppSectionCard`, 15 laissés avec leur raison (ci-dessus) ; délimiteurs équilibrés, 0 chaîne visible perdue vs HEAD, 12 sites d'appel vérifiés paramètre par paramètre contre les six constructeurs |
| 3 — dialogue de confirmation | **fait** (01/08) | décision « marquer le ton, garder l'ordre » ; 6 sites convertis, 4 laissés avec leur raison ; l'ordre s'accordait déjà, contrairement à ce que la fiche annonçait |
| 4 — champ de saisie | **fait** (01/08) | 21 des 25 surcharges de bordure retirées, thème corrigé d'abord ; `check_inputs.dart` — 16 cas dont 8 refus, plus mutation des 11 vrais fichiers |
| 5 — indicateurs d'attente | **fait** (01/08) | 21 sites relevés par contexte, **rien à extraire** ; 3 défauts de garde trouvés et corrigés (ci-dessus) |
| 6 — enveloppes Fleetbase | **fait** (01/08) | 18 `try/catch` retirés ; `tsc`, `jest` (85) et `build` verts |
| 7 — 335 chaînes | **fait** (01/08) | **569 clés** sur six tables, parité stricte partout ; **zéro chaîne d'interface en dur** dans `screens/` et `widgets/` ; 220 chaînes du dernier lot prouvées par resubstitution |
