# CLAUDE.md — Echango Delivery

Ce fichier guide Claude Code (et tout contributeur) sur le contexte, les décisions et les questions ouvertes du projet **Echango Delivery**. Écrit dans le même esprit que le `CLAUDE.md` d'`echangoorder` : décisions + justification, pas juste l'état courant.

## Contexte projet

Echango Delivery est le **Produit 2** de l'écosystème Echango : une plateforme B2B qui met en relation des commerçants locaux (boulangerie, pharmacie, fleuriste... et **Echango Order**, premier client en dogfooding) avec un réseau de transporteurs locaux indépendants. Vision complète : `docs/specs_macro_drive_transport.md` dans [`echangoorder`](https://github.com/ecolealgerienne-ui/echangoorder) (§4 pour la partie Delivery spécifiquement).

Positionnement produit (macro doc §1.3) : l'effet réseau est la thèse centrale — **plus de commerçants → plus de transporteurs → plus de valeur**. Ça suppose un pool de transporteurs **mutualisé** entre commerçants, pas une flotte dédiée par commerçant.

## Règles de développement — à respecter sans exception

Treize règles qui gouvernent tout le code de ce dépôt. Chacune est née d'un défaut réel, constaté en test, pas d'une préférence de style : la justification est donnée parce que c'est elle qui permet de reconnaître un cas nouveau relevant de la même règle. Les dix premières portent sur ce qu'on écrit ; la onzième sur **comment on lit le dépôt avant d'écrire** ; les deux dernières sur **la frontière HTTP** — ce qui entre dans le BFF et qui a le droit d'y entrer.

⚠️ **Ce qu'un `tsc` vert vaut dans le sandbox Claude Code — et ce qu'il ne vaut pas (30/07/2026).** Le client Prisma n'y est **jamais généré** (le proxy sortant refuse `binaries.prisma.sh` par politique, y compris avec `--no-engine`), donc `@prisma/client` s'y résout sur un fichier de 4 ko où tout est `any`. Conséquence : **rien de ce qui traverse un type Prisma n'est vérifié ici**, et un `npx tsc --noEmit` vert ne dit rien de ces chemins-là. Constaté : `liveOrderDetailed(merchant.fleetbaseVendorUuid, order)` — arguments inversés — passait ici parce que `merchant` était `any`, et échouait à la compilation chez l'utilisateur, où le client est généré. La vérification a fonctionné, simplement pas de mon côté. À l'écriture : relire à la main toute signature dont un argument vient d'une ligne Prisma, et annoncer un `tsc` vert pour ce qu'il est — une vérification **partielle**.

⚠️ **Et `npx tsc` n'est pas le `tsc` du projet tant que `npm install` n'a pas tourné (01/08/2026).** Le dépôt est cloné neuf à chaque session et `node_modules/` est absent ; `npx` va alors chercher **la dernière version publiée** au lieu de celle qui est épinglée. Constaté au démarrage : `npx tsc --version` → **6.0.2** là où `package.json` épingle `^5.5.4`, avec pour seule sortie une `error TS5101` sur la dépréciation de `baseUrl` — un refus qui ne parle **pas du code** et qui n'existe que parce que le compilateur n'est pas le bon. Après `npm install`, `./node_modules/.bin/tsc` rend 5.9.3 et sort à 0. Deux conséquences à retenir : **lancer `npm install` avant toute vérification TypeScript**, et se méfier d'un `tsc` qui échoue sur `tsconfig.json` plutôt que sur un fichier source — c'est la signature d'une version qui n'est pas celle du projet. Piège jumeau du précédent : là un `tsc` vert ne prouvait pas assez, ici un `tsc` rouge n'accusait pas le bon.

⚠️ **Et `tsc --noEmit` vert ne veut pas dire que `npm run build` passe (01/08/2026).** Les deux ne lisent pas la même configuration — `nest build` applique `tsconfig.build.json`. Constaté : `vehicle_type: null` dans un littéral d'objet passe le premier et fait échouer le second (`TS7018`, *implicitly has an 'any' type*). Un `null` nu n'a pas de type inférable, et le champ perdait au passage sa forme pour l'appelant, qui lit `string | null` sur l'autre branche. **Les deux commandes sont donc à lancer, pas l'une pour l'autre** — et c'est `build` qui fait foi, puisque c'est lui qui produit ce qui tourne.

⚠️ **Le pipe masque le code de sortie.** `npx tsc --noEmit | tail -20 && echo "code $?"` affiche **toujours** `code 0` : `$?` y est celui de `tail`. Écrire dans un fichier puis relever `$?`, ou lire `${PIPESTATUS[0]}`. C'est ainsi que le faux vert ci-dessus a failli passer pour un vrai.

### 1. Le statut Fleetbase fait foi — aucun état parallèle

**Fleetbase est la source de vérité** (`docs/architecture_bff_fleetbase.md`). Le BFF ne conserve que ce que Fleetbase ne peut structurellement pas porter, et fait le lien par identifiant. **Deux** exceptions nommées, et seulement deux : un **cache éphémère** (jetable sans perte) et un **curseur** (une date, pas la donnée).

⚠️ **Il y en avait trois, et la troisième a disparu le 03/08/2026** : une « valeur figée dans une écriture comptable » (`CashCollection.expectedAmount`, qui ne devait pas bouger si un admin corrigeait la commande le lendemain). Elle est partie avec le registre de caisse (`docs/registre_caisse_precis.md`). C'est le genre de simplification qu'on ne cherche pas et qu'on constate : retirer une capacité a **réduit d'un tiers la liste des états parallèles autorisés**.

Corollaire, et c'est celui qu'on oublie : **ne pas dériver un état métier de plusieurs champs amont**. Un drapeau `is_draft` a été calculé côté BFF depuis `adhoc` + `dispatched` + `driver_assigned_uuid`, puis renvoyé à l'app comme un champ à part. Il a divergé au premier échec partiel : une publication dont la première écriture réussit et la seconde échoue laissait une commande **encore `created` chez Fleetbase** mais « déjà publiée » selon la dérivation — ni republiable, ni affichée pareil d'un écran à l'autre. Un seul champ arbitre, des deux côtés.

**En pratique** : si l'information existe déjà dans un champ Fleetbase, on sert ce champ et l'app en déduit ce qu'elle affiche. On n'invente pas un second vocabulaire.

**⚠️ `meta` n'est pas un stockage sûr — et Fleetbase offre mieux (30/07/2026).** Affecter un transporteur depuis la console **écrase le `meta` de la commande** : constaté sur une commande réelle, où il ne restait que `{_index_resource: true}`. Prix, montant à encaisser, colis et précisions d'adresse disparaissent au moment précis où quelqu'un prend la course en charge — pour le transporteur, `cod_amount` effacé veut dire aucun montant annoncé, plafond de dette vérifié contre zéro, et clôture sans encaissement enregistré alors qu'il tient l'argent.

**Cause exacte, trouvée dans le source de `fleetops` (30/07/2026) — c'est un bug amont, et il est localisé.** La liste des commandes est servie par une **ressource allégée**, `Http/Resources/v1/Index/Order.php`, qui pose délibérément `'meta' => ['_index_resource' => true]` : un **drapeau** signalant au client « cet enregistrement est partiel, recharge-le avant de t'en servir ». La console honore ce drapeau presque partout — `place-actions.js`, `driver-actions.js`, `vehicle-actions.js` et la route de détail d'une commande font tous `if (x?.meta?._index_resource) await x.reload()`. Mais `order-actions.js` → `assignDriver()` ne le fait **pas** : il charge le conducteur (`loadDriver()`), ouvre la fenêtre, puis `await order.save()`. Ember sérialise alors tous les attributs, `meta` compris — donc le drapeau — et le `PUT` écrase le vrai `meta`.

**Conséquence pratique immédiate** : affecter un transporteur **depuis le menu « … » de la liste** détruit les données ; le faire **depuis la fiche de la commande** ne les détruit pas, puisque la route de détail recharge le modèle. À dire aux admins tant que l'amont n'est pas corrigé.

**Et pourquoi `meta` reste malgré tout le mauvais endroit** : il est dans le `$fillable` du modèle `Order` et n'a **aucun mutateur**, donc le `$record->update($input)` générique le **remplace en entier**. Le trait `HasMetaAttributes` fournit `setMeta()`/`updateMeta()`, qui fusionnent — mais le chemin de mise à jour de l'API ne les appelle pas. N'importe quel client qui envoie une clé `meta`, par erreur ou non, écrase la nôtre.

**Le bon endroit existe et s'appelle les champs personnalisés.** `Order` utilise `HasCustomFields` : les valeurs vivent dans `custom_field_values`, une table séparée, et `onAfterUpdate()` ne les synchronise **que si la requête les porte** (`if ($customFieldValues)`), sans suppression de ce qui manque par défaut. Une mise à jour qui les ignore les laisse donc intactes — exactement la protection que `meta` n'a pas. C'est là que vont prix, montant à encaisser et options de la course.

✅ **Migration FAITE** — et cette ligne a affirmé le contraire pendant deux jours, ce qui m'a fait hésiter le 02/08/2026 devant une question dont le code avait déjà la réponse. `createOrder` envoie `custom_field_values` et n'écrit plus dans `meta` que ce qui n'a **pas** de champ personnalisé (`pricing_inputs` seul). `effectiveOrderMeta` sert trois couches par ordre de durabilité : champs personnalisés d'abord, `meta` historique ensuite, `Order.specMeta` en dernier recours pour les commandes d'avant la migration.

⚠️ **Une documentation périmée est une donnée d'appui fausse en puissance** — même famille que la borne du `pubspec` et que « ✅ Décision prise » lu comme « fait ». Ici elle a coûté une hésitation ; elle aurait pu coûter une réécriture.

⚠️ **Ce qui subsiste et porte à confusion** : le BFF sert cet objet fusionné sous le nom **`meta`**. Un lecteur du contrat croit donc lire le `meta` de Fleetbase alors qu'il lit surtout des champs personnalisés. Le renommer `custom` serait faux dans l'autre sens — la fusion contient aussi l'historique. Point ouvert, voir Prochaines étapes.

**`Order.specMeta` est le filet posé en attendant** : il conserve ce qui a été demandé, figé à la création — une spécification, pas un état —, et `effectiveMeta()` le fait passer **derrière** Fleetbase, clé par clé, pour qu'une valeur corrigée en amont reste autoritaire et que seul l'effacement soit réparé. Il disparaîtra quand les champs personnalisés seront en place.

### 2. Aucune transaction entre systèmes — compenser explicitement

Il n'y a **aucun `$transaction` dans le BFF, et c'est inévitable** : Fleetbase est joint en HTTP avec sa propre base MySQL, un `$transaction` Prisma ne couvre que notre Postgres et ne peut rien y annuler. Toute opération qui écrit dans les deux systèmes, ou deux fois chez Fleetbase, est donc **non atomique par construction**.

Conséquence obligatoire : **toute écriture multiple doit nommer sa fenêtre d'échec et la compenser**, ou expliquer par écrit pourquoi elle ne le fait pas.

- **Compenser** quand l'échec partiel a un effet visible de l'extérieur. `createOrderCache()` annule la commande Fleetbase si l'écriture locale échoue (une commande orpheline est pire qu'une commande non créée). `publishOrder()` retire la course de la diffusion si le dispatch échoue — sans quoi `adhoc: true` la rend **réclamable par un transporteur alors que le commerçant la croit en brouillon**.
- **Ne pas bloquer** quand l'écriture qui échoue est un cache et que l'opération amont a réussi. Lever ferait réessayer l'utilisateur sur une opération déjà faite ; `OrderReconcilerService` remet le cache d'aplomb.
- **Dire ce qui n'est pas garanti.** Une compensation est best-effort : si elle échoue à son tour, un log en `error` doit nommer la ressource à reprendre à la main. Le filet réduit la fenêtre, il ne la ferme pas.

**Ordre des écritures** : la plus réversible d'abord. La déclaration d'encaissement s'écrit **avant** la clôture Fleetbase, pour qu'un échec laisse la course reprenable plutôt qu'une livraison close dont l'argent n'est nulle part.

### 3. Gestion d'erreur centralisée — un code, jamais un message nu

Tout refus passe par les cinq fonctions de `backend/bff/src/common/errors/http-errors.ts` (`badRequest`, `unauthorized`, `forbidden`, `notFound`, `conflict`), dont le paramètre `code` est typé sur le registre unique `common/errors/error-codes.ts`. **Un `throw new BadRequestException('texte')` direct est un défaut** : le message part sans `code`, et l'app n'a rien à distinguer pour choisir sa traduction. Un code absent du registre est un refus de compiler, pas un bug de recette.

Trois pièges rencontrés, à ne pas refaire :

- **Ne jamais lever un refus métier à l'intérieur d'un `try` dont le `catch` réemballe.** Le `catch` l'attrape et le remplace par un message générique, perdant le code. Résoudre et refuser **avant** le `try`. Pire variante : le filet d'erreur du Lot 4 appelait `rollbackVendor()` et supprimait le commerçant qu'on venait d'enregistrer.
- **Laisser passer les `HttpException`** dans les `catch` génériques (`if (error instanceof HttpException) throw error;`), sinon un refus délibéré ressort en « opération impossible ».
- **Relayer le message amont de Fleetbase quand il existe** (`error.response?.data?.errors?.[0] || .error || .message`). Ses refus sont explicites et actionnables — « Order has already been dispatched! » a permis un diagnostic qu'une phrase générique aurait rendu impossible.

### 4. Aucune chaîne en dur — traduction par code

Langues cibles : **français + arabe (RTL)**. Le serveur renvoie un **code** stable, l'**app traduit** — jamais l'inverse, et jamais le message serveur affiché tel quel (il est en français, y compris pour un utilisateur arabophone).

- `echango_delivery/lib/errors/app_error.dart` miroite le registre serveur, plus des codes client-only documentés (réseau, permissions, capture photo).
- `echango_delivery/lib/errors/error_translator.dart` traduit chaque code en FR et AR. **Les trois ensembles de clés — `AppError`, table FR, table AR — doivent rester strictement identiques** : `dart tool/check_error_codes.dart` le vérifie, doublons compris. Un code sans traduction retombe sur un message générique **dans la langue courante**, jamais sur du français brut. ⚠️ Le vérificateur doit reconnaître **toute** clé de map, sans présumer de sa forme : la version improvisée du 30/07/2026 filtrait sur `domaine.motif` et ne voyait donc pas `not_found` ; elle a signalé un manque inexistant, l'entrée ajoutée a fait un doublon, et c'est `dart analyze` qui l'a rattrapé. Un vérificateur qui ne voit pas tout ne rassure pas, il déplace l'erreur.
- Aucun `e.message` ni chaîne française en dur dans un gestionnaire d'erreur. Les classes d'état passent par `translateErrorCode(e.code, locale)`.
- Un libellé métier partagé par plusieurs écrans vit **à un seul endroit** (ex. `MerchantOrder.statusLabel`) : deux tables recopiées ont affiché deux textes différents pour la même commande.

⚠️ **Dette connue** : ~575 chaînes d'interface (labels, boutons, textes d'aide) restent en français en dur dans `lib/screens/` et `lib/widgets/`. Décision explicite de ne pas les traiter dans le lot i18n initial — détail et mesure dans `docs/audit_i18n_erreurs.md`. Tout **nouvel** écran doit néanmoins éviter d'en ajouter.

### 5. Un invariant s'applique, il ne se documente pas

**Dès qu'un commentaire dit « doit rester identique à X », « le pendant exact de X », « même règle que X » — c'est le signal qu'il faut extraire, pas commenter.** La phrase est l'aveu que rien ne tient l'invariant à notre place, et **un commentaire ne peut pas échouer**.

Le cas fondateur (31/07/2026) : `isClaimable` (entreprise) et `isClaimableAdhoc` (transporteur) étaient identiques caractère pour caractère, chacun portant un commentaire affirmant que les deux devaient le rester. J'avais donc **vu** le couplage, je l'avais **écrit**, et je ne l'avais pas appliqué. Les deux copies excluaient `canceled` sans exclure `completed` : une course **livrée** s'est affichée dans « Courses libres », avec un bouton « Prendre cette course ». Personne ne l'avait vu parce qu'on avait vérifié que les deux copies **s'accordaient entre elles**, pas qu'elles avaient raison — **deux copies d'accord ne prouvent rien**.

En cherchant, cinq endroits nommaient « statut terminal » et trois divergeaient : deux oubliaient `completed`, un oubliait l'orthographe `cancelled` (Fleetbase émet les deux). Chacun produisait son propre défaut.

**Le critère, parce qu'il ne s'agit pas de tout fusionner** : la question n'est pas *« ces deux bouts se ressemblent-ils »* mais **« si l'un change, l'autre doit-il changer ? »**.
- **Oui ⇒ un seul endroit.** Les deux prédicats de disponibilité : les deux populations réclament les mêmes courses, une divergence n'est pas une variante, c'est un défaut.
- **Non ⇒ deux endroits, et un commentaire qui dit pourquoi.** `orderStatusLabel` (commerçant) et `fleetOrderStateKey` (entreprise) se ressemblent beaucoup et répondent à deux questions différentes : où en est ma livraison / qu'est-ce que je dois en faire.
- **Quand la fusion coûte plus qu'elle ne rapporte**, l'invariant se tient par un **contrôle exécuté**, jamais par une phrase : `projectOrderForDriver` et `projectOrderForFleet` restent séparées, et un test vérifie qu'elles servent le même niveau de détail.

⚠️ **Deux thèmes sont deux copies, et personne ne les compare.** Le thème sombre n'avait **aucun style de bouton ni d'onglet** : rayon, rembourrage et couleurs n'étaient écrits que dans le thème clair, donc le même écran affichait des coins arrondis en clair et des pilules Material 3 en sombre. La couleur de marque, elle, était écrite **trois fois** — une par thème, plus un littéral dans le thème des onglets. Rien de tout ça ne se voit en relisant un thème : il faut les mettre côte à côte, ce que personne ne fait. Tout ce qui est décidé dans l'un doit l'être dans l'autre, donc être extrait.

⚠️ **Un test qui recopie ce qu'il vérifie ne vérifie que lui-même.** Le premier test de ce prédicat en contenait une **troisième** copie, « reproduction fidèle » pour contourner une dépendance à Prisma. Il serait resté vert pendant que les deux vrais prédicats divergeaient. Un test importe ce que le code exécute, ou il ne sert à rien.

### 6. Des composants graphiques réutilisables — l'homogénéité ne se maintient pas à la main

**Un motif d'interface qui apparaît deux fois devient un widget partagé dans `lib/widgets/`.** C'est la règle 5 appliquée à l'écran, et elle a la même justification : recopier une mise en page, c'est s'engager à la corriger partout, ce que personne ne fait.

**Mesuré le 31/07/2026, et c'est ce qui a rendu la règle nécessaire** — le thème *est* unique et partagé (`theme/app_theme.dart`, un seul `theme:` dans `main.dart`), mais les écrans ne s'en servent pas également :

| dossier | couleurs en dur | via le thème |
|---|---|---|
| `screens/flotte/` | 3 | 17 |
| `screens/commercant/` | 54 | 39 |
| `screens/transporteur/` | 48 | 41 |
| `screens/cash/` | 24 | 16 |

Les écrans du profil entreprise sont **six à huit fois plus pilotés par le thème** que les autres, qui peignent leurs propres couleurs. D'où la remarque de l'utilisateur : « le thème entre le commerçant et le facilitateur est différent ». Il ne l'est pas — c'est son application qui l'est.

Et il n'existe **que trois widgets partagés** (`language_selector`, `photo_field`, `proof_image`) pour dix-neuf fichiers d'écran, alors que les mêmes motifs sont réécrits partout : bandeau d'erreur (8 fois, 7 fichiers), message d'absence (13 fois, 10 fichiers), carte de section (69 fois, 14 fichiers), SnackBar (43 fois, 13 fichiers).

**En pratique :**

- **`Colors.*` et `Color(0x…)` sont interdits dans un écran.** La couleur vient de `Theme.of(context).colorScheme` — sans quoi un changement de thème ne traverse pas l'application, et deux écrans du même produit ne se ressemblent plus.
- **Un motif répété se nomme.** Bandeau d'erreur, état vide avec sa consigne, carte de section, ligne libellé/valeur : ce sont des widgets, pas des copies.
- **Un composant partagé porte sa règle métier avec lui.** `_Empty` accompagne toujours l'absence d'une consigne, parce qu'une liste vide sans explication se lit comme une panne (défaut corrigé deux fois) ; le bandeau d'erreur se pose **au-dessus** du contenu et ne le remplace pas, parce qu'un rechargement raté ne doit pas effacer ce qui était lisible. Recopier la mise en page sans la règle, c'est reproduire le défaut qu'elle corrige.
- **Les nouveaux écrans n'ont aucune excuse** — comme pour la règle 4, la dette existante est assumée (`docs/audit_i18n_erreurs.md`), mais elle ne grandit pas.

⚠️ **Extraire un widget, ou poser un contrôle — les deux réponses ne traitent pas le même manque (31/07/2026).** Mesuré sur les boutons : 15 `ElevatedButton` côté transporteur contre 5 `FilledButton` côté entreprise, soit **Material 2 d'un côté et Material 3 de l'autre, dans la même application** — et, dans un seul écran, l'action principale d'une ligne servie en bouton plein dans un onglet et en lien dans l'autre. La tentation était d'écrire un `AppButton`. C'eût été une faute : le motif **est déjà un widget**, et l'envelopper aurait demandé de réexposer `icon`/`label`/`style`/`onLongPress` pour n'y rien ajouter — réécrire l'API de Material.

  Ce qui manquait n'était pas un composant, c'était **une décision**. Le critère : **le motif porte-t-il une règle, ou seulement un choix ?** Une règle ⇒ un widget qui la porte (`AppEmptyState` exige sa consigne, `AppLoadMore` ne s'affiche que s'il reste vraiment quelque chose). Un choix ⇒ le nommer une fois (`theme/app_buttons.dart`) et le faire tenir par un contrôle exécuté (`tool/check_buttons.dart`), parce qu'un commentaire ne peut pas échouer.

⚠️ **Dette connue** : les ~130 couleurs en dur de `screens/commercant/`, `screens/transporteur/` et `screens/cash/`, et les quatre motifs ci-dessus non extraits. Non traité au 31/07/2026 — à faire avant le pilote, c'est ce que voit l'utilisateur en premier.

### 7. Aucune valeur en dur — une valeur qui porte une décision se nomme

**Un littéral qui exprime un choix vit dans un fichier partagé, pas au milieu d'un écran.** C'est la règle 5 appliquée aux valeurs : recopier un nombre, c'est s'engager à le corriger partout.

Le critère n'est pas « est-ce un littéral » — `maxLines: 1` décrit la nature du widget, pas une décision. Le critère est : **est-ce que quelqu'un pourrait vouloir en changer, et faudrait-il alors le changer ailleurs aussi ?**

**Mesuré le 31/07/2026** sur `lib/screens/` et `lib/widgets/` :

| catégorie | occurrences | gravité |
|---|---|---|
| espacement, marge, rayon (`EdgeInsets`, `SizedBox`, `borderRadius`) | 316 | cosmétique |
| taille (`size:`, `fontSize:`, `elevation:`) | 51 | cosmétique |
| **règle métier (comparaison, limite, plafond)** | **19** | **grave** |

**Les deux catégories n'appellent pas le même remède, et il ne faut pas les confondre.**

**Les valeurs d'apparence** produisent une incohérence visuelle : trois écrans avec trois marges différentes, et rien pour les rattraper le jour où l'on change l'échelle. Remède : des jetons nommés dans `theme/` (`AppSpacing.md`, `AppRadius.card`), comme les couleurs viennent déjà de `colorScheme`. C'est laid, pas faux.

**Les valeurs métier sont d'une autre nature : elles recopient une règle qui vit ailleurs, et elles la recopient en silence.** `memberships_tab.dart` contient `if (query.length < 3)` — c'est une copie de `@MinLength(3)` du `DriverSearchDto` côté serveur. Le jour où le serveur passe à quatre, l'écran continue d'envoyer des requêtes de trois caractères et affiche un refus que l'utilisateur ne comprend pas. Personne ne pense à chercher dans un écran la règle qu'on vient de changer dans un DTO.

**En pratique :**

- **Une valeur métier vient du serveur, ou d'une constante partagée qui nomme explicitement sa source.** Si elle doit être reproduite côté app pour éviter un aller-retour, le commentaire dit **de quelle règle serveur elle est la copie** — et la règle 5 s'applique : si les deux doivent changer ensemble, il faut un mécanisme, pas une phrase.
- **Une valeur d'apparence vient d'un jeton nommé.** `AppSpacing.md` plutôt que `16`.
- **Ce qui décrit la nature d'un widget reste littéral.** `maxLines: 1`, `shrinkWrap: true` : rien à centraliser, ce ne sont pas des décisions.
- **Les nouveaux écrans n'ont aucune excuse**, comme pour les règles 4 et 6.

✅ **Traité le 31/07/2026, et tenu par deux vérificateurs exécutés** — parce qu'un chantier de centralisation sans garde n'est pas un chantier, c'est un instantané : il suffit d'un `EdgeInsets.all(16)` dans le prochain écran pour rouvrir la divergence que 308 remplacements viennent de fermer.

- `lib/config/app_rules.dart` — `ServerRules` (copies de règles serveur, chacune nommant son fichier d'origine) et `AppRules` (décisions locales). `dart tool/check_server_rules.dart` **lit les deux fichiers et compare** ; `--self-test` l'éprouve sur 25 cas, dont toutes les formes de divergence qu'il doit refuser. ⚠️ Il lit les **bornes numériques** sous `@MinLength`, `@Min` et `@Max` (le décorateur est paramétré) — dont `CreateOrderDto.price`/`codAmount`, gardées côté formulaire depuis l'audit du 04/08/2026.
- **Les listes fermées de codes** (motifs de refus, d'échec de livraison, d'écart d'encaissement) sont recopiées des deux côtés — le serveur les applique (`@IsIn`, `assertCollectedAmount`), l'app les propose. `dart tool/check_closed_lists.dart` **lit les six fichiers et compare les ENSEMBLES** (l'ordre est cosmétique) : un code en trop côté app est refusé en 400 par le serveur, un code manquant n'est jamais proposé — les deux sont des pannes silencieuses. `--self-test` sur 10 cas, **et prouvé par mutation du vrai fichier** (un code bidon ajouté → refusé). Trouvé par l'audit des écrans du 04/08/2026, seul garde qui manquait à ces trois listes.
- `lib/theme/app_spacing.dart` — `AppSpacing`/`AppRadius`, barème sorti de la mesure et non d'une convention (six valeurs portaient 91 % des 339 occurrences). `dart tool/check_spacing.dart` **refuse** un littéral du barème et **recense** ceux qui n'en font pas partie, sans échouer : les faire converger déplacerait des pixels, c'est une décision de design.

⚠️ **Ce que ces deux scripts ont appris, et qui vaut plus que le lot** : les deux se sont trompés, et **aucune des erreurs n'a été trouvée en les relisant**. `check_server_rules` concluait à l'accord quand la déclaration d'un champ ne matchait pas (`readonly password:`, `password!:`) — un `@MinLength(12)` serveur passait pour un 8 — et acceptait un décorateur mis en commentaire ; `check_spacing` lisait `5` dans `EdgeInsets.all(16.5)`. Toutes trouvées en **faisant tourner le vérificateur sur des mutations**. Un vérificateur au vert n'a montré que sa capacité à dire oui ; il doit prouver qu'il sait dire non, et `--self-test` est là pour ça.

⚠️ **Dette restante** : les littéraux hors barème (1, 2, 6, 10, 14, 20, 36, 48 — une vingtaine, `check_spacing.dart` en imprime le compte exact plutôt que de le faire recopier) et les valeurs métier laissées délibérément littérales — bornes serveur sans copie côté app (`@Max(500000)` sur les prix, `@MaxLength(60)` sur les recherches). L'absence ne ment pas, contrairement à une copie divergente ; c'est un choix, pas un oubli.

### 8. Un contrôle doit prouver qu'il sait refuser

**Un vérificateur au vert n'a montré qu'une chose : sa capacité à dire oui.** Tant qu'on ne l'a pas vu refuser, on ne sait pas s'il regarde. C'est la leçon la plus répétée du dépôt, et elle a coûté quatre fois.

**Les quatre cas, parce que c'est leur diversité qui rend la règle reconnaissable** :

- `check_server_rules` concluait à l'accord quand la déclaration d'un champ ne matchait pas (`readonly password:`) — un `@MinLength(12)` serveur passait pour un 8 ;
- `check_spacing` lisait `5` dans `EdgeInsets.all(16.5)` ;
- `check_error_codes` ancrait sur `'… _ar'`, qui matche **`_arabe`** : renommer la table faisait repartir le contrôle en silence sur une table qui ne porte plus le nom attendu — exactement le fichier restructuré qu'il est censé refuser ;
- le banc de `require_free_driver` exécutait tout dans un sous-shell, et masquait donc le défaut qu'il devait attraper.

**Aucune de ces quatre erreurs n'a été trouvée en relisant.** Toutes l'ont été en faisant tourner le contrôle sur des **mutations** — du code volontairement cassé, dont on sait qu'il doit être refusé.

**En pratique** :

- **Un `--self-test`**, avec autant de cas qui doivent échouer que de cas qui doivent passer. `check_error_codes` en a 14 dont 9 refus, `check_buttons` 12 dont 6.
- **Et une mutation du VRAI fichier**, pas seulement des cas fabriqués : c'est elle qui a trouvé le défaut de `_arabe`, que les treize cas fabriqués laissaient passer.
- ⚠️ **Une vérification qui partage un composant avec ce qu'elle vérifie ne dit rien de ce composant.** Le contrôle par inversion des cartes de section réutilisait la fonction fautive : l'erreur s'annulait elle-même. Et le vérificateur du lot de traduction **normalisait les apostrophes**, donc il ne pouvait pas signaler les trente qui avaient changé — elles ont été comptées à part, à la main.

**Ce que la règle ne dit pas** : que tout doit être vérifié par script. Elle dit que **ce qui est vérifié par script doit l'être pour de bon**, sans quoi le contrôle ne déplace pas l'erreur, il l'enterre.

### 9. Ce que le serveur sert doit avoir un appelant

**Le fil rouge de ce projet, et de loin le défaut le plus répété : le serveur savait, l'app ignorait.** Ce n'est jamais une panne — c'est une capacité écrite, testée, documentée, et appelée nulle part. Elle ne produit aucune erreur : elle produit une fonctionnalité absente que personne ne cherche, puisque le code existe.

**Le relevé, parce qu'il est accablant** : `photoUploaded`, `online`, le jeton FCM, la position GPS, le suivi en tâche de fond, la capture photo — tous validés côté BFF par test réel et branchés nulle part (28/07). Le module `flotte` entier, six routes, pendant que l'app affichait « Espace non disponible ». `GET /flotte/drivers/positions`, écrite le 28/07, appelée le 31/07 — alors que la vision produit définit ce persona par « commandes entrantes, assignation, **position des conducteurs** ». Le total de pagination, servi et **jeté**, donc deux listes tronquées en silence. `driversUnavailable`, qui existait pendant que l'écran affirmait « aucun conducteur ».

**En pratique** :

- **Une route neuve n'est pas finie tant qu'un écran ne l'appelle pas.** Le contrat serveur n'est pas le livrable ; ce que l'utilisateur voit l'est.
- **Une réponse serveur se lit en entier.** Un champ servi et non lu est soit un manque côté app, soit un champ à retirer du serveur — jamais « pas grave ».
- **Réciproquement : ce qui n'a plus d'appelant se supprime.** Quatre colonnes mortes d'`Order` laissaient croire à une synchronisation inexistante.

### 10. Un défaut n'a pas de valeur par défaut

**Une valeur de repli détruit l'information d'absence**, et l'absence est presque toujours l'information qui compte.

**Les cas fondateurs, tous constatés** : `data_get($this, 'online', false)` chez Fleetbase — un conducteur dont l'état est inconnu passait pour hors ligne ; des coordonnées manquantes valant `0`, soit un point au large du golfe de Guinée ; `[0,0]` lu comme une position alors que c'est une absence ; `photo_url: null` posé en dur ; un `catchError` rendant une liste vide, donc l'écran affirmant « aucun conducteur rattaché » à une entreprise dont le BFF était injoignable ; un script de test annonçant « Commerçant créé » sans l'avoir obtenu ; et le repli d'un titre de ligne sur `public_id`, qui affichait `order_1sn4fzn6e2` là où il fallait dire qu'on ne savait pas.

**Le critère** : *si cette valeur est fausse, est-ce que quelque chose le dira ?* Si non, il ne faut pas de valeur.

**En pratique** :

- **`null` plutôt qu'un zéro, un `false` ou une chaîne vide**, quand la donnée peut manquer. `CashLedger.totalOn` rend `null` et non `0` : « vous devez 0 » à qui ne doit rien est une phrase fausse.
- **Deux absences, deux messages.** Vide et illisible ne se disent pas pareil — `AppEmptyState.unavailable` existe pour forcer la question à l'écriture plutôt qu'à la relecture.
- **Un repli qui affiche un identifiant technique est un repli qui ment poliment.** Dire « — » est plus honnête que dire `order_1sn4fzn6e2`.
- ⚠️ **Le pire endroit pour un repli est un test.** Il y produit ce qu'on redoute le plus : un contrôle qui rassure.

⚠️ **Cinq défauts en une session, tous une ABSENCE et jamais une erreur (03/08/2026).**
Le chantier « rien sur le BFF » en a produit cinq, de cinq formes différentes.
Aucun n'a levé, aucun n'a été journalisé, aucun n'a été trouvé en relisant :

| ce que j'ai écrit | ce que ça a produit |
|---|---|
| `(f: any)` sur un objet dont les champs avaient été renommés | une liste de lignes toutes à `undefined`, **HTTP 200** |
| `specMeta` retiré après avoir prouvé le stockage | prix et montants absents — la **liste** Fleetbase ne sert pas les champs personnalisés |
| cinq champs laissés dans deux `create()` Prisma | `tsc` **vert** — le client n'était pas régénéré |
| `limit=30` recopié d'un contexte où il valait 11 | une intersection **vide** au lieu de « moins de résultats » |
| `extractCollection(response)` au lieu de `response.data` | une liste **vide**, sans un mot |

**Ce qu'il faut en retenir n'est pas la liste, c'est la forme commune** : une
donnée mal câblée ne casse presque jamais — elle **disparaît**. Et une
disparition n'a pas de trace, donc pas de pile d'appels, donc rien à lire.
C'est pour ça que ce dépôt vérifie par des bancs qui **comparent à un témoin**
plutôt que par des tests qui vérifient qu'on n'a pas planté.

⚠️ **Et une valeur juste dans un contexte devient fausse dans un autre.**
`limit=30` était `take: 11` sur un ensemble déjà filtré ; « 535 commandes sur
535 complètes » était vrai du stockage et faux de la lecture. Le nombre voyage,
le contexte non — c'est la même faute que la borne du `pubspec` (règle 10) et
que « le graphe ne sert à rien » (règle 11).

⚠️ **Une API n'existe pas parce qu'on s'en souvient — la borne du `pubspec` fait foi. Mais la borne elle-même est une donnée, pas un oracle : elle se vérifie aussi (corrigé le 01/08/2026).**

La règle est née d'un vrai défaut : `CameraFit` et `Color.withValues` ont été écartés parce qu'une API ne s'emploie pas de mémoire, et c'était juste. Son **exemple fondateur était faux**, lui, et il a tenu deux jours : `surfaceContainerHighest` (Flutter 3.22) était présenté comme indisponible parce que le projet déclarait `flutter: '>=3.20.0'`. Or cette borne mentait deux fois — la ligne `sdk: '>=3.5.0'` du **même fichier** exigeait déjà Dart 3.5, donc Flutter ≥ 3.24 (c'est elle que `pub` applique), et **Flutter 3.20 n'a jamais existé en stable**, le canal passant de 3.19 à 3.22. L'API était disponible depuis le début. Borne portée à `>=3.24.0`, **déduite** de la contrainte Dart et non choisie.

**Ce qui rend le cas instructif n'est pas l'erreur, c'est sa propagation.** Une borne fausse ne dort pas dans un coin du `pubspec` : **elle se cite**. Cinq passages du dépôt s'en servaient pour écarter une API — **deux commentaires de code et trois de documentation** —, dont un qui se donnait explicitement en leçon de méthode (« la contrainte est dans le dépôt, pas dans ma mémoire »). Et le même chiffre a fait consigner comme « contradiction du code » le fait que `surfaceContainerHighest` soit employé à deux endroits et refusé à un troisième — la contradiction était réelle, le coupable désigné ne l'était pas. **Une borne fausse est pire qu'une borne absente : l'absence fait vérifier, la fausseté fait conclure.**

**En pratique** : toute API employée se vérifie contre la version épinglée — et quand c'est la version épinglée qui sert d'argument pour **refuser** quelque chose, elle se vérifie à son tour. Deux contrôles qui coûtent une minute : la contrainte citée est-elle celle que l'outil applique réellement (ici `sdk:` domine `flutter:`), et la version nommée a-t-elle seulement existé ?

### 11. Une question de structure se pose au graphe, pas au `grep`

**Avant de chercher « qui appelle ceci », « qu'est-ce que ceci appelle », « qu'est-ce qui casse si je touche à ceci » dans `backend/bff/`, interroger Graphify.** C'est obligatoire, et ce n'est pas une préférence d'outillage : les deux ont été comparés sur la même question, et le graphe gagne.

**La mesure qui fonde la règle (01/08/2026).** Question : *qui appelle `canTakeCashOrder` ?*

| | ce qu'on obtient |
|---|---|
| `grep` | quatre `fichier:ligne` |
| `graphify explain` | les **mêmes quatre**, avec la **fonction englobante** de chacun (`assertDriverCashCeiling`, `assertCashCeiling`, `pickAvailableFavourite`, `assertFleetCeiling`), **le sens** de chaque arête, et ce que la fonction appelle **en aval** |

Le `grep` dit *où le nom apparaît*. Le graphe dit *ce qui dépend de quoi*. Sur une modification qui touche à de l'argent, c'est la seconde question qui compte — et c'est elle qui a permis de voir, en un appel, que le facilitateur de pool se branchait en **un seul point** parce que tout converge vers `driverCounterparty()`.

**En pratique :**

```
python -m graphify explain "nomDeLaFonction"     # voisinage, dans les deux sens
python -m graphify path "A" "B"                  # comment A atteint B
python -m graphify update .                      # après un gros lot (11 s)
```

⚠️ **Et la limite, qui est mesurée elle aussi : ne pas croire le graphe sur `echango_delivery/` (Dart).** L'extraction y est faite par expressions régulières, pas par tree-sitter. `formatRelative` y a un **degré de 1** — ses trois appelants réels sont absents —, les imports relatifs créent **64 nœuds fantômes** (2 %) au `source_file` vide, et une requête de chemin passe par eux pour rendre un détour de six sauts **qui a l'air d'une réponse**. Densité : **3,83 arêtes par nœud en TypeScript contre 1,61 en Dart**. Sur du Dart, le `grep` reste l'outil.

⚠️ **La faute qui a retardé l'adoption, et elle vaut d'être nommée** : j'avais mesuré le Dart, conclu « l'outil ne sert à rien », et je ne l'ai pas ouvert de la journée — alors qu'il était juste sur tout le TypeScript, c'est-à-dire sur la moitié du dépôt où se trouve l'argent. **Mesure exacte, portée de conclusion fausse.** C'est le même défaut que la borne du `pubspec` et que le commentaire de `dates.dart` : ce n'est pas la mesure qui trompe, c'est ce qu'on lui fait dire.

⚠️ **Et cette règle a d'abord eu la faiblesse que ce dépôt dénonce partout : elle ne pouvait pas échouer.** Les dix autres sont tenues par des vérificateurs qui *refusent* ; celle-ci ne s'adressait qu'au jugement — et le jugement a dérapé **le jour même où elle a été écrite**, un `grep -A 12` répondant à une question de structure quelques minutes plus tard. Une règle non contrôlée ajoutée à une liste de règles contrôlées les dilue.

**Elle est donc tenue par un hook** : `scripts/hooks/graphify-first.py`, branché en `PreToolUse` sur `Grep`. Il **refuse** un motif qui ressemble à un identifiant nu dans `backend/bff/`, avec le message qui dit quoi faire.

```json
"hooks": { "PreToolUse": [ { "matcher": "Grep", "hooks": [
  { "type": "command", "command": "python <repo>/scripts/hooks/graphify-first.py" } ] } ] }
```

Le branchement vit dans `.claude/settings.local.json`, **gitignoré** — chacun l'active chez lui ; le script, lui, est versionné.

**Ce qu'il laisse passer, et c'est le plus important** : un hook trop large devient une gêne quotidienne, et une gêne quotidienne se désactive. Passent sans un mot les motifs à métacaractères (recherche textuelle), `echango_delivery/` (le graphe y répond faux), l'absence de chemin, les identifiants de moins de quatre caractères, et **le même motif relancé une seconde fois** — un refus définitif rendrait le travail impossible le jour où le graphe ne sait pas répondre. Il installe une habitude, il ne prend pas le contrôle.

⚠️ **Écrit en Python et non en `jq`** : `jq` n'existe que dans WSL sur ce poste, et les hooks tournent côté Windows. Un hook qui échoue à lire son entrée **laisse passer**, délibérément — bloquer parce qu'on n'a pas compris casserait l'outil qu'on voulait améliorer, et le défaut serait mis sur le compte du `Grep`. Éprouvé sur **neuf cas au tuyau, dont deux refus**, puis en session : refus → requête au graphe → second `Grep` identique accepté.

### 12. Une frontière d'accès se ferme par défaut, et son refus se prouve

**Un contrôle d'accès qu'on n'a jamais vu refuser n'est pas un contrôle, c'est une intention.** C'est la règle 8 appliquée à la sécurité, et elle mérite son propre numéro parce que l'enjeu n'y est pas un affichage faux mais une donnée servie à quelqu'un qui n'y a pas droit.

**L'état mesuré le 02/08/2026**, parce qu'il fonde ce qui suit — la mécanique est saine, c'est sa preuve qui manque :

| | |
|---|---|
| `@UseGuards` dans le dépôt | **aucun** — l'authentification est un `APP_GUARD` **global** |
| routes | 74, dont **8 publiques** (7 `auth` + `health`), chacune sous un `@Throttle` plus serré |
| rôle | `@Persona` posé **au niveau de la classe** sur les trois contrôleurs personas |
| révocation | `tokenVersion` comparé au claim `tv`, plus `active`, à **chaque** requête |
| secret | `JWT_SECRET` exigé au démarrage, 32 caractères minimum, **aucun repli** |

**En pratique :**

- **La fermeture est par défaut, l'ouverture est explicite.** Un garde global plus `@Public` pour se retirer, jamais l'inverse : avec un `@UseGuards` par route, la route qu'on oublie est **ouverte**. Ici la route qu'on oublie est fermée, et l'oubli se voit à l'écran au lieu de se taire sur le réseau. Même polarité que la liste d'autorisation des projections (règle M10) — et c'est la même raison.
- **`@Public` est une décision, pas une commodité.** Chaque ajout à ces huit routes se justifie par écrit et porte son `@Throttle` : une route publique est la seule surface qu'un inconnu peut marteler.
- **Un identifiant venu de l'URL passe par un pipe.** Les 32 `@Param('id')` traversent `FleetbaseIdPipe`, parce qu'ils partent **interpolés dans une URL Fleetbase appelée avec le jeton de service**, qui a tous les droits sur l'organisation. Sans lui, un `../../` détourne la requête vers une ressource que le contrôle d'appartenance n'a jamais examinée.

⚠️ **Authentifier n'est pas autoriser, et c'est la confusion qui coûte le plus cher.** Le garde prouve **qui** vous êtes ; il ne prouve pas que la commande, le conducteur ou l'adresse que vous nommez sont à vous. Cette seconde vérification vit **dans chaque service** (`getMerchantWithValidation`, `resolveOrder`, `getDriverOrFail`, `getFleetWithValidation`) — donc dans quatre-vingt-dix endroits, chacun reposant sur le fait que son auteur y a pensé. **Toute route qui accepte un identifiant doit vérifier l'appartenance avant de s'en servir**, et le pire cas doit être « introuvable », jamais « la ressource de quelqu'un d'autre ».

✅ **Les deux refus sont désormais éprouvés** (02/08/2026, recomptés le 03/08) : `scripts/test-frontiere-http.sh` constate les trois refus sur les **66** routes protégées, `scripts/test-appartenance.sh` constate le refus de la ressource d'autrui sur **25** routes, sur les trois personas. Les deux sont dans la suite des scénarios, les deux ont été **prouvés par mutation du vrai code**.

⚠️ **La leçon, et elle vaut plus que les bancs** : la première version du banc de refus a **passé la mutation**. Ouvrir une route la faisait quitter l'ensemble testé, et le total tombait sans un mot. **Un contrôle qui prend sa cible dans la donnée qu'il examine ne contrôle rien** — d'où l'épinglage des routes ouvertes, chacune étant une décision qui doit s'écrire.

⚠️ **Reste à couvrir** : **2 des 32** routes à identifiant — la lecture des preuves, qui demande un décor **photographique** ; 5 autres sont exclues parce que l'appartenance n'y est pas la question. Décomposition complète en Prochaines étapes : un total sans sa décomposition ne se vérifie pas.

⚠️ **Et un refus doit sortir avec son code.** `HttpExceptionFilter` est déclaré `@Catch(HttpException)` : une `TypeError` ou une erreur Prisma **ne passe pas par lui**, sort par le gestionnaire par défaut de Nest, donc **sans `code`** — et l'application retombe sur son message générique au moment précis où l'on comprend le moins ce qui s'est passé. C'est la règle 3 percée sur son chemin le plus obscur.

### 13. Toute entrée traverse un DTO décoré — et la règle se nomme une fois

**Le `ValidationPipe` ne valide que les classes décorées.** Un `@Body() dto: { reason?: string }` typé en ligne n'est pas validé du tout : le pipe n'a aucune métadonnée à lire et laisse passer le corps tel quel. Ce n'est pas une hypothèse — une entreprise de transport a pu contester une remise avec un motif de **longueur illimitée** là où les deux autres personas sont bornés à 500 caractères. Le plafond n'était pas contourné : **il n'existait pas sur ce chemin**.

**L'état mesuré le 02/08/2026** : `whitelist` **et** `forbidNonWhitelisted` — un champ inconnu est *refusé*, pas silencieusement retiré ; **tous les champs de DTO décorés, aucun sans** ; tous les `@Query` typés sauf trois chaînes brutes ; corps limité à 10 Mo ; appels Fleetbase bornés à 30 s.

**En pratique :**

- **Un `@Body`, un `@Query` : une classe décorée.** Jamais un type en ligne, jamais `any`, jamais un primitif.
- **Un champ sans décorateur est un champ non validé**, même si son type TypeScript paraît le contraindre : le type disparaît à la compilation, la validation est à l'exécution.
- **Une borne métier se nomme une fois** (`FLEETBASE_ID_PATTERN`, `VEHICLE_TYPES`, `MAX_PHOTO_BASE64_LENGTH`, `COLLECTION_DISCREPANCY_REASONS`). ⚠️ **Une copie a déjà échappé** : `auth/dto/register.dto.ts:128` réécrit `/^[A-Za-z0-9_-]{1,64}$/` en clair au lieu d'importer le motif partagé, employé six fois ailleurs. Identique aujourd'hui, libre de diverger demain — et c'est le motif qui protège les identifiants interpolés dans une URL Fleetbase.
- **Trente et une règles sont recopiées d'un fichier à l'autre** (même champ, même contrainte) : `amount`, `collectedAmount`, `page`/`limit`, `q`, `notes`, les coordonnées. Le critère de la règle 5 tranche : *si l'une change, l'autre doit-elle changer ?*

⚠️ **Centraliser oui, écrire un validateur non.** La tentation est une fonction maison qui « vérifie les types et les regex » — ce serait réimplémenter `class-validator` et perdre l'intégration au pipe, exactement la faute évitée pour `AppButton` (règle 6). La forme juste est un **décorateur composé** (`applyDecorators`), qui *nomme* la règle sans refaire le moteur :

```ts
export const IsFleetbaseId = (label: string) =>
  applyDecorators(IsString(), Matches(FLEETBASE_ID_PATTERN, { message: `${label} invalide` }));
```

⚠️ **Ce qu'il ne faut PAS fusionner** : deux bornes qui se ressemblent peuvent être deux nombres pour deux raisons. Les rapprocher « parce que ce sont deux montants » ferait bouger l'un en corrigeant l'autre. *(L'exemple d'origine — `Max(5000000)` sur une remise contre `Max(500000)` sur un encaissement — a disparu avec le registre de caisse le 03/08/2026 ; la règle, elle, tient.)*

⚠️ **Et le piège qui rend ce chantier dangereux, à connaître avant d'y toucher** : `echango_delivery/tool/check_server_rules.dart` lit les DTO serveur **textuellement** (`RegExp(r'@MinLength\(\s*(\d+)')`). C'est le seul mécanisme qui empêche l'application et le serveur de diverger sur ces bornes. Remplacer `@MinLength(8)` par un `@IsPassword()` composé le rendrait **aveugle** — et son mode de panne documenté est de **conclure à l'accord** quand il ne reconnaît pas une déclaration. On refermerait une duplication en cassant le garde qui en surveille une autre, **sans que rien ne passe au rouge**. Si l'on compose, le vérificateur se met à jour dans le même lot et s'éprouve sur une mutation.

## Pourquoi un repo séparé (décision produit, 2026-07-26)

Echango Delivery est backé par **Fleetbase** (self-hosted, AGPL-3.0) — un logiciel tiers, pas notre code. Le vendoriser dans `echangoorder` mélangerait les licences (AGPL vs le code propriétaire d'Echango Order) et une stack complètement différente (Node.js/MySQL/Redis/SocketCluster vs Odoo/Postgres). Ce repo contient **nos** scripts de déploiement, notre config, et nos notes de décision — **pas le code source de Fleetbase lui-même**, cloné à part en local (voir § Installation locale). On ne fork pas Fleetbase pour l'instant : pas nécessaire tant qu'on ne modifie pas son code (voir § Licence).

## État courant (01/08/2026)

⚠️ Cette section remplace un « phase d'exploration, rien de déployé » qui datait du 26/07 et qui était **faux depuis des jours**. Un état périmé est pire qu'aucun état : il fait conclure.

### L'environnement, tel qu'il est sur ce poste

| | |
|---|---|
| **Mobile** `echango_delivery/` | Flutter 3.35.7 · Dart 3.9.2, côté **Windows** |
| **BFF** (source) | `backend/bff/`, TypeScript 5.9.3 |
| **BFF** (exécution) | conteneur `echango_bff_app`, **port 3001** — pas 3000 |
| **Fleetbase** | 8 conteneurs, API `:8000`, console `:4200` |
| **Docker** | **natif dans WSL Ubuntu**, pas Docker Desktop (qui est arrêté) |

⚠️ **Il y a DEUX copies du dépôt, et c'est structurant.** `C:\…\Desktop\shope\echango-delivery` — où l'on édite, commite, et où tourne Flutter — et **`/home/amar/projects/echango-delivery`**, d'où tournent réellement Fleetbase et le BFF, et **la seule qui porte `backend/bff/.env`**. Les scripts d'intégration ne s'exécutent que depuis celle-là, et les deux divergent dès qu'on commite d'un côté sans tirer de l'autre.

### Ce qui est vérifié, et par quoi

```
./scripts/run-all-scenarios.sh [conducteur]     # 23 scénarios — le BFF en curl
./scripts/test-frontiere-http.sh                # 66 routes × 3 refus (jeton, rôle, révocation)
./scripts/test-appartenance.sh                  # la ressource de A refusée à B
./scripts/test-frontiere-projection.sh          # aucune commande Fleetbase brute ne sort
flutter analyze && flutter test                 # 0 problème · 60 tests
dart tool/check_*.dart [--self-test]            # 6 contrôles · 89 cas dont refus
npm run build                                   # ⚠️ PAS seulement tsc --noEmit

# les TROIS personas joués DANS l'application, sur émulateur (02/08/2026)
./scripts/provision-app-parcours.sh [conducteur]   # pose le décor, imprime la commande
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/parcours_trois_personas_test.dart -d <émulateur> --dart-define=…
# l'audit des écrans, isolé et rapide (04/08/2026) — mêmes --dart-define
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/audit_ecrans_test.dart -d <émulateur> --dart-define=…
```

Les vingt-trois scénarios couvrent : multi-appartenance, le **filtre wilaya côté conducteur** (`test-filtre-wilaya.sh` : une course hors-wilaya est cachée au conducteur, la bonne visible, dans les deux sens — le filtre, pas seulement la persistance), les trois sorties d'une course, **le voyage de la wilaya**, les deux bancs de la **frontière HTTP** — refus (`test-frontiere-http.sh`) et appartenance (`test-appartenance.sh`), motifs en règle 12 —, la **frontière de projection**, le **ciblage d'un favori nommé** (`test-visibilite-ciblage.sh` : ciblé = invisible aux autres, redirection réversible, témoin positif à chaque pas), le **ciblage d'un favori ENTREPRISE** (`test-ciblage-entreprise.sh` : la branche `facilitator` jamais jouée e2e — l'entreprise voit la course confiée, le pool non, elle affecte son conducteur ; quatre témoins), le **pool mutualisé** (`test-pool-mutualise.sh` : un conducteur sert deux commerçants — la thèse produit), le **filtre véhicule** isolé (`test-filtre-vehicule.sh` : moto ne voit pas « utilitaire », témoin positif à l'appui), la **concurrence d'acceptation** (`test-concurrence-acceptation.sh` : deux acceptations simultanées, un seul gagnant), les **fenêtres de perte d'écriture** (`test-concurrence-fenetres.sh` : N ajouts // ⇒ N survivants — garde du verrou par ressource sur favoris et declines ; avant lui, 2/6 et 1/2, mesuré), les **bords de l'argent à la porte** (`test-bords-argent.sh` : les trois refus du tiroir, puis la livrée muette), l'**immuabilité de l'encaissement** (`test-double-cloture.sh` : une seconde clôture ne réécrit pas le montant d'une livraison close — a trouvé un vrai défaut, un 2000 réécrit à 0 en 2xx), la **tarification vue par le conducteur** (`test-tarification-conducteur.sh` : `cod_amount` = marchandise + course en VALEUR, pas seulement présent ; refus sans prix), la **preuve de livraison** (`test-preuve-livraison.sh` : propriétaire au relais, intrus bloqué à l'accès — les deux dernières routes à identifiant de la règle 12), le **cycle de vie de l'appartenance** (`test-cycle-appartenance.sh` : le départ coupe les courses à venir, jamais celle déjà confiée) le **refus d'un favori sollicité** (`test-refus-favori-pool.sh` : la course confiée repart au pool + `order.released`, la vraie remplaçante de `pickAvailableFavourite`), la **durabilité des montants** (`test-durabilite-meta.sh` : la console écrase `meta`, prix et COD survivent depuis les champs personnalisés — le bug fondateur du 30/07 prouvé e2e), la **chaîne réconciliateur→notification** (`test-reconciliateur-notif.sh` : une prise en charge hors BFF remonte au commerçant en `order.assigned`), la **compensation de publication** (`test-compensation-publication.sh` : dispatch échoué → l'étape 1 rétractée, la course ne circule pas — échec injecté de façon déterministe) et la **résilience dégradée** (`test-resilience-degradee.sh` : Fleetbase à terre → le BFF sert un état, il ne plante pas ; `/health` rapporte la dépendance sans échouer ; un refus amont sort en 503, pas en 400).

⚠️ **`test-frontiere-projection.sh` répond à une question qu'aucun autre ne posait (03/08/2026) : la route APPELLE-t-elle la projection ?** Les tests Jest prouvent que la liste d'autorisation retire ; ils accordaient le catalogue et l'autorisation — **deux listes cohérentes** — pendant que deux chemins sautaient les deux, et `GET /transporteur/commandes/:id` a servi la commande Fleetbase **entière** une journée durant, `meta.declines[]` compris (uuid, motif et **prix offert** de chaque concurrent). Le banc lit la même commande **deux fois**, chez Fleetbase et par le BFF, et **refuse de conclure** si la version Fleetbase ne porte pas ce qu'on cherche à ne pas voir. Éprouvé par mutation du vrai code.

⚠️ **Cinq et non dix depuis le 03/08/2026** : les scénarios d'argent — parcours à 2 et 3 maillons, régularisation, écart à la porte et dette négative, les deux plafonds — sont partis avec le registre de caisse qu'ils éprouvaient (`docs/registre_caisse_precis.md`). Ce qui reste du sujet — la déclaration à la porte et son refus sans motif — est éprouvé **dans l'application**, par les parcours joués à l'écran, qui est le seul endroit d'où ce geste part réellement.

⚠️ **`test-wilaya.sh` porte ses propres témoins, et c'est ce qui le rend utile.** La wilaya décide de ce qu'un transporteur voit ; une course qui ne la transporte pas est **invisible au filtre**, sans erreur ni journal — une liste simplement plus courte. Trois contrôles, chacun avec son cas négatif dans le même passage :

- **le champ est honoré** — une course avec la wilaya, une sans. Fleetbase abandonne un champ inconnu **sans rien dire**, donc `province` accepté-mais-ignoré aurait exactement la même apparence que `province` stocké ;
- **les deux points** — enlèvement `Alger`, livraison `Blida`, délibérément **différentes** : une recopie de l'un sur l'autre passerait un contrôle à valeur unique ;
- **la duplication conserve** — et la copie d'une course *sans* wilaya ne doit en porter aucune, sinon la duplication en fabriquerait une.

**Éprouvé par mutation du vrai fichier** (la livraison recopie la wilaya de l'enlèvement) : il échoue sur « Wilaya de livraison attendue Blida, lue ALGER ».

⚠️ **Et la mutation elle-même se vérifie.** La première tentative écrivait `null` nu dans un littéral à clé calculée — **TS7018**, le piège déjà documenté plus haut : la compilation échouait, l'ancien code restait en service, et le scénario passait. J'aurais pu en conclure qu'il ne vérifiait rien. Le banc dit désormais « la mutation n'a jamais pris effet — l'essai ne prouve RIEN » plutôt que de trancher : *« le contrôle est aveugle »* et *« la mutation n'est pas en service »* sont deux choses, et les confondre accuse le mauvais coupable.

⚠️ **Les scénarios ne touchent jamais l'application, et c'est leur angle mort.** Ils composent leur corps de requête en `curl` : un écran peut être absent, muet ou fautif sans qu'aucun ne passe au rouge. Les parcours joués **dans** l'app ont trouvé **six défauts** qu'aucun test Jest ni Flutter ne pouvait voir :

- une création de course **refusée dès que le contenu du colis n'était pas décrit** ;
- une fiche qui restait « Brouillon » après publication, un garde de relecture comparant des identifiants qui ne pouvaient **jamais** être égaux ;
- une course **déjà démarrée** offerte comme réclamable, que Fleetbase refusait aussitôt ;
- une **clé de traduction affichée en clair** sur la fiche transporteur, la fonction étant appelée avec la table du commerçant ;
- une écriture qui **notifie une classe d'état détruite** quand l'utilisateur quitte l'écran avant la réponse ;
- et `GET /commercant/commandes/:id` qui ne répond qu'à l'uuid.

Détail complet, et les cinq défauts trouvés dans les tests eux-mêmes, dans le journal.

⚠️ **`audit_ecrans_test.dart` — premier scénario d'audit, et deux défauts d'outillage trouvés en le faisant passer (04/08/2026).** Le scénario : le conducteur ouvre une opportunité à encaisser et la fiche montre **deux montants distincts** — ce qu'il encaisse à la porte (`cod_amount`) et sa rémunération (`price`) —, ce qu'un `curl` ne peut pas voir. Aucun des deux défauts n'était dans le produit : **(1)** `provision-app-parcours.sh` reconnaissait la course encaissée à son **prix** et réutilisait une course héritée d'un run précédent **sans vérifier son `cod_amount`**, puis imprimait la valeur canned `1950` alors que la course portait `2727` — le contrat mentait sur le décor (règle 10) ; il relit désormais le cod réel. **(2)** Le test attendait la ligne cherchée par `pumpUntil` **avant** de défiler ; or elle est plus bas dans la liste, et un `ListView.builder` ne construit que ce qui est à l'écran — la ligne n'existait pas dans l'arbre, `pumpUntil` expirait toujours. **On attend la liste (une carte rendue), jamais la ligne hors-écran, puis on défile** — le piège que la doc de `scrollUntilFound` nommait déjà. Diagnostic mené par instrumentation (`DBG` jetables) : BFF sert 9 → app parse 9 → l'onglet **construit 9 cartes** ; c'est le finder du test qui ne trouvait pas la 8ᵉ.

⚠️ **Trois choses à savoir avant de le lancer.** Les personas sont **trois comptes** que le décor provisionne (commerçant validé + carnet, entreprise validée, conducteur invité), et il **refuse un conducteur dont l'email porte plusieurs profils** — `/auth/login` répondrait `requiresRoleSelection` et l'écran attendrait un clic. Les plafonds sont **10 inscriptions par heure** et **5 connexions par minute** (`auth.controller.ts`) : la suite des scénarios consomme huit inscriptions, les parcours une ; le compteur étant un état de service, un `docker restart echango_bff_app` vaut l'heure fraîche. Enfin `android/gradle.properties` fait lire à Gradle un magasin **PKCS12 dérivé du magasin de certificats Windows** : sans lui la compilation échoue en `PKIX path building failed`, le JetBrains Runtime d'Android Studio n'embarquant pas SunMSCAPI — motif complet dans le fichier.

### Outils d'exploitation

⚠️ **Les deux outils de registre ont disparu le 03/08/2026** avec le registre lui-même (`docs/registre_caisse_precis.md`) : `provision-platform.sh`, qui désignait le prestataire plateforme, et `reset-test-ledger.sh`, qui soldait la dette d'un conducteur de test. Le second existait parce que chaque passage de la suite ajoutait ~2 800 à l'encours et finissait par buter sur le plafond ; la déclaration s'écrivant désormais **sur la commande**, rien ne s'accumule et il n'y a plus rien à remettre à zéro.

- ⚠️ **Le throttle d'inscription (10/h) reste la vraie limite de la suite.** Elle passe dans une heure fraîche, pas deux fois de suite.

## Architecture envisagée (hypothèse de travail — à valider en testant, pas encore tranchée)

- **Une seule Organization Fleetbase "Echango Delivery"**, pas une par commerçant. Les "Organizations" Fleetbase sont un mécanisme d'isolation totale (drivers, commandes, utilisateurs, clés API — rien ne traverse). Une Organization par commerçant cloisonnerait leurs transporteurs respectifs et casserait l'effet réseau visé. Modèle cohérent avec le doc macro §2 : "Opérateur plateforme gère le réseau transporteurs via back-office Fleetbase" — un seul opérateur, un seul réseau.
- Les commerçants n'ont pas forcément de système/site web à eux : ils doivent pouvoir commander un transporteur via **une interface fournie par Echango** (décision produit explicite, pas une intégration API obligatoire côté commerçant). **Tranché par observation manuelle de la console (2026-07-26)** : ce ne sera pas la console Fleetbase elle-même, même avec un rôle restreint (question ouverte #1 toujours à tester, mais déjà écarté sur le principe) — la console (navigation à onglets Fleet-Ops/Storefront/Developers/Ledger/IAM, gestion d'extensions, etc.) est conçue pour un opérateur/dispatcher, pas pour un petit commerçant qui veut juste déclarer une livraison. Il faut une **interface custom Echango, légère, construite par-dessus l'API Fleetbase** (essentiellement : formulaire de commande + suivi) — cohérent avec le choix déjà fait côté Echango Order de construire une app préparateur custom plutôt que de forcer l'UI Odoo sur ce public.
- **Deuxième persona identifié (2026-07-26)** : une **organisation qui gère elle-même une petite flotte de transporteurs** (ni Echango l'opérateur réseau, ni un simple commerçant) a aussi besoin d'une interface simple — pas la console Fleetbase complète (trop lourde pour ce cas d'usage non plus), mais plus qu'un simple formulaire : une vue dispatch minimaliste (commandes entrantes, assignation à un driver disponible, position des drivers). Hypothèse de travail, **pas encore scopée** : une deuxième interface custom légère, distincte de celle des commerçants, construite sur la même API Fleetbase.
- **Recommandation découlant des deux points ci-dessus** (réflexion, pas encore un plan de dev) : ça dessine une architecture à 3 niveaux d'interface, toutes par-dessus la même API Fleetbase et la même Organization unique — (1) console Fleetbase = réservée à l'opérateur Echango (accès complet, existant) ; (2) interface custom légère "commerçant" = commande + suivi ; (3) interface custom légère "gestionnaire de petite flotte" = dispatch minimaliste. Aucune des deux interfaces custom (2) et (3) n'est développée à ce stade — périmètre, écrans et priorité à discuter avant d'écrire la moindre ligne de code.
- **Confirmé par test manuel (2026-07-26)** : l'isolation entre Organizations est totale au niveau data, pas seulement au niveau permissions — un driver (et plus largement un user) créé dans l'Organization A n'est ni visible ni réutilisable depuis l'Organization B ; en recréer un "identique" dans B génère un enregistrement entièrement distinct (ID différent), sans aucun lien natif entre les deux. Conséquence directe pour l'hypothèse multi-Organization évoquée ci-dessus (une organisation avec sa propre flotte dédiée = sa propre Organization Fleetbase) : un driver de cette flotte dédiée ne peut PAS nativement aussi piocher dans le pool mutualisé "Echango Delivery" — il faudrait une double saisie manuelle, sans synchronisation (statut, position, historique dupliqués et désynchronisés). Si cette flexibilité est un objectif produit réel, ça n'est pas fourni nativement par Fleetbase : il faudra construire nous-mêmes une couche d'identité driver par-dessus l'API, qui référence plusieurs IDs Fleetbase pour une même personne réelle.
- Extension **FleetOps** nécessaire (dispatch/commandes/flotte). Extension **Storefront** (marketplace e-commerce Fleetbase) **pas nécessaire** — Echango Order a déjà son propre frontal (app Flutter), pas besoin de la vitrine intégrée de Fleetbase.
- App conducteur : **décision (27/07/2026) — on reste sur Navigator** (app officielle Fleetbase, React Native, open source, AGPL) plutôt que de construire une app transporteur custom from scratch. Le doc macro d'Echango Order avait écarté Navigator ("remplacé par l'app transporteur custom") sans justification documentée ; construire une app custom voudrait dire refaire nous-mêmes géolocalisation en tâche de fond, notifications push, capture photo pour la preuve de livraison et résilience hors-ligne — un chantier bien plus lourd que les deux interfaces custom commerçant/petite flotte. **Pas encore testée en pratique** (question ouverte #3).
- Interfaces custom (commerçant + petite flotte) : **décision (27/07/2026) — Flutter pur, pas FlutterFlow.** FlutterFlow avait été envisagé un temps pour son éditeur visuel, mais cet argument ne tient pas dès lors que c'est Claude Code qui écrit le code (pas un développeur humain à qui l'éditeur glisser-déposer ferait gagner du temps) — un agent IA n'a pas de moyen efficace de piloter une interface web visuelle pensée pour un humain. Écrire directement du code Dart/Flutter est plus rapide, reste dans le repo git comme le reste du projet, sans dépendance à un outil externe. Détail : `docs/specs_echango_delivery.md` §8.

## Questions ouvertes à trancher en testant en local

1. **Granularité des permissions à l'intérieur d'une Organization** — **✅ tranchée (26/07/2026)** : la console/API classique ne fournit aucune isolation en dessous du niveau Organization (confirmé par test manuel + code). MAIS le package officiel `fleetbase/customer-portal-api` fournit une vraie isolation par compte, **validée par test réel de bout en bout** (compte `Contact` rattaché à un `Vendor`, login, `GET orders` correctement scopé). Détail complet : `docs/specs_echango_delivery.md` §3.1.
2. Un driver Navigator peut-il recevoir des courses de **plusieurs commerçants différents** au sein d'une même Organization (modèle pool partagé), ou le broadcast ad hoc est-il pensé pour une seule entreprise ? **Partiellement répondu** : le pipeline serveur du dispatch adhoc (broadcast géospatial par proximité) est validé de bout en bout par test réel (26/07/2026, `docs/specs_echango_delivery.md` §3.2) ; l'assignation ciblée d'un driver précis à une commande est aussi confirmée possible. Reste à tester : la réception réelle par un driver, qui nécessite l'app Navigator installée (question #3 ci-dessous).
3. Navigator est-il réellement adaptable (rebrand, configuration) pour servir d'app transporteur Echango ? **❌ Révision de décision (27/07/2026)** : test d'installation et compilation mené côté utilisateur (Windows, Android). Obstacles sérieux identifiés et confirmés par recherche GitHub :
   - **Erreurs de codegen systémiques** : `react-native-camera-roll` incompatible avec React Native 0.86 (même sur branche "legacy" 0.76) — `UnionTypeAnnotation` non supportée par le générateur de code Fleetbase
   - **Crash au startup même après build réussi** : Hermes engine error, documenté dans issue #101 du repo Navigator (aussi reproductible sur d'autres OS comme Arch Linux)
   - **Documentation incomplète** : tokens Facebook/Transistor non mentionnés, mais requis pour fonctionner
   - **Workarounds nécessaires** : patches manuels sur dependencies, upgrades forcées, configurations non documentées
   - **Support/maintenance incertain** : 9 issues actives liées à build/compilation, pas de pattern clair de fermeture
   
   **Conclusion** : Navigator a des frictions d'installation trop sérieuses pour être un MVP fiable sans fork/patching massif. Coût de maintenance à long terme élevé et non maîtrisé.
   
   **Prochaines étapes** : 
   - **Option A (recommandée)** : construire une app transporteur custom en **Flutter pur** (cohérent avec stack Echango Order, contrôle complet, maintenance claire)
   - **Option B** : forker + patcher Navigator (maintenance plus lourde, dépendance à upstream instable)
   - **Option C** : utiliser console Fleetbase pour les transporteurs (rejeté avant, trop complexe)

## Licence — position actuelle (à rouvrir avant l'ouverture B2B réelle)

**AGPL-3.0 self-hosted retenu par défaut pour l'instant** (gratuit ; obligation de publier nos modifications si le service est exposé en réseau à des tiers — clause "network use"). La licence commerciale Fleetbase (FCL, qui lève cette obligation) est écartée pour l'instant — montant trouvé en recherche non fiable/contradictoire, **jamais vérifié officiellement**, à ne pas utiliser comme base de décision budgétaire. Ce point est explicitement différé : il ne bloque pas la phase d'exploration actuelle, mais devra être retranché avant la Phase 3 du roadmap macro (ouverture B2B à des commerçants tiers, `docs/specs_macro_drive_transport.md` §8.3).

## Installation locale — **faite**, et comment elle a été faite

Prérequis (vérifiés contre la doc officielle Fleetbase, pas supposés) : Docker + Docker Compose, Node.js v22, Git.

Deux méthodes officielles :

```bash
# Méthode 1 — CLI Fleetbase (recommandée par l'éditeur)
npm install -g @fleetbase/cli
flb install-fleetbase

# Méthode 2 — clone + script manuel (celle utilisée par scripts/setup-local.sh de ce repo)
git clone https://github.com/fleetbase/fleetbase.git
cd fleetbase && ./scripts/docker-install.sh
```

Extension FleetOps (dispatch/commandes/flotte, nécessaire pour nous — pas installée par défaut) :

```bash
flb install fleetbase/fleetops
```

Ports par défaut (doc officielle) : Console `http://localhost:4200`, API `http://localhost:8000`, SocketCluster `38000`.

⚠️ **Ce paragraphe disait « non vérifié ici — aucun daemon Docker dans le sandbox ». C'est faux depuis le 01/08/2026** : Docker tourne nativement dans WSL Ubuntu, Fleetbase et le BFF y sont en service, et tout ce qui était listé comme invérifiable — comportement de FleetOps, granularité des rôles, format du `docker-compose` — a été éprouvé par des tests réels depuis. Voir § État courant pour ce qui tourne, et `docs/journal_travaux.md` pour la façon dont chaque point a été tranché.

La procédure ci-dessus reste juste : c'est celle qui a servi. Ce qui a changé est **qui peut la vérifier** — plus seulement l'utilisateur.

## Specs consolidées (26 juillet 2026)

Après la phase d'exploration ci-dessus, une revue croisée par 5 agents spécialisés (sécurité, architecture, métier, logistique, validation technique Fleetbase) a été menée sur ce fichier et `docs/journal_exploration_fleetbase.md`, avec vérification systématique contre le code source public et la documentation officielle de Fleetbase. Résultat : **`docs/specs_echango_delivery.md`** — synthèse priorisée, avec un plan d'action concret avant tout développement, et une liste de contradictions entre agents à vérifier en premier (rapports complets dans `docs/rapports_specs/`).

**Découvertes majeures à retenir** : un package officiel `fleetbase/customer-portal` (jamais repéré avant cette revue) fournit déjà une isolation par compte native pour le persona commerçant, potentiellement en remplacement d'une bonne partie du BFF prévu à construire nous-mêmes. Le calcul d'itinéraire n'est pas self-hosted par défaut malgré le narratif du projet. Un auto-dispatch par proximité existe nativement. Le doc macro (`docs/specs_macro_drive_transport.md`) contient plusieurs affirmations obsolètes à corriger.

**✅ Spikes validés par tests réels (26/07/2026)** : `customer-portal-api` installé et testé de bout en bout (compte de test créé, rattaché à un Vendor, commande visible via l'API scopée — un bug de format Fleetbase trouvé et documenté au passage) ; dispatch adhoc testé de bout en bout côté serveur (broadcast géospatial déclenché sans erreur). **Priorités 1 et 2 du plan d'action closes** — voir `docs/specs_echango_delivery.md` §9 pour le détail complet des tests et §3 pour toutes les découvertes. Étape en cours : scoper le BFF (Priorité 4).

## Prochaines étapes

➡️ **Elles vivent désormais dans [`docs/status_v1.md`](docs/status_v1.md).**

⚠️ **Pourquoi ailleurs, et pourquoi il ne faut PAS les réécrire ici** : elles
occupaient 542 lignes sur 1020 d'un fichier dont le rôle est de porter des
**règles**. Une règle et un état d'avancement n'ont ni la même durée de vie ni
le même lecteur — la première se lit avant d'écrire du code, le second avant de
choisir quoi faire. Les mélanger fait relire mille lignes pour trouver ce qui
reste, et fait passer une case cochée pour une règle.

**Une seule liste, ailleurs.** En recopier un extrait ici recréerait deux
sources qui divergent — le défaut que ce fichier dénonce à chaque page.

Ce qui reste ici : les treize règles, leur justification, et l'état de
l'environnement.

> 🗺️ **Où vit quoi** — [`docs/ou_vit_quoi.md`](docs/ou_vit_quoi.md) : pour une
> donnée, où elle est rangée et pourquoi là, plus les **huit pièges Fleetbase
> mesurés**. À lire avant d'ajouter une colonne ou un champ personnalisé.
>
> 📓 **Les travaux achevés** — [`docs/journal_travaux.md`](docs/journal_travaux.md),
> avec les défauts rencontrés et leur motif.


## Repo lié

- [`echangoorder`](https://github.com/ecolealgerienne-ui/echangoorder) — Echango Order (Produit 1). `docs/specs_macro_drive_transport.md` pour la vision macro complète des deux produits.
