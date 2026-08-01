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

---

## Lot 5 — Les indicateurs d'attente (21 sites)

**Ce que c'est.** 21 `CircularProgressIndicator` et 10 `RefreshIndicator`.

**Ce qu'il faut vérifier avant de conclure à une duplication.** Un indicateur
dans un bouton, un autre au centre d'une page, un troisième dans un pied de
liste : ce sont trois choses différentes, et `AppLoadMore` couvre déjà le
troisième. Le lot n'existe peut-être pas.

**Ce qui débloque le lot** : le relevé par contexte. Le résultat attendu est
« rien à faire », et il faut pouvoir le dire avec un chiffre.

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
| 1 — enveloppes HTTP | à faire | |
| 2 — `Card(` bruts | à faire | |
| 3 — dialogue de confirmation | à faire, **décision attendue** | |
| 4 — champ de saisie | à mesurer | |
| 5 — indicateurs d'attente | à mesurer | |
| 6 — enveloppes Fleetbase | à faire | |
| 7 — 335 chaînes | à faire, par écran | |
