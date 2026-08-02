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

**Fleetbase est la source de vérité** (`docs/architecture_bff_fleetbase.md`). Le BFF ne conserve que ce que Fleetbase ne peut structurellement pas porter, et fait le lien par identifiant. Trois exceptions nommées, et seulement trois : un **cache éphémère** (jetable sans perte), un **curseur** (une date, pas la donnée), une **valeur figée dans une écriture comptable** (`CashCollection.expectedAmount` ne doit pas bouger si un admin corrige la commande demain).

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

**Ordre des écritures** : la plus réversible d'abord. Le registre de caisse s'écrit **avant** la clôture Fleetbase, pour qu'un échec laisse la course reprenable plutôt qu'un encaissement fantôme.

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

- `lib/config/app_rules.dart` — `ServerRules` (copies de règles serveur, chacune nommant son fichier d'origine) et `AppRules` (décisions locales). `dart tool/check_server_rules.dart` **lit les deux fichiers et compare** ; `--self-test` l'éprouve sur 22 cas, dont toutes les formes de divergence qu'il doit refuser.
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
| routes | 95, dont **8 publiques** (7 `auth` + `health`), chacune sous un `@Throttle` plus serré |
| rôle | `@Persona` posé **au niveau de la classe** sur les trois contrôleurs personas |
| révocation | `tokenVersion` comparé au claim `tv`, plus `active`, à **chaque** requête |
| secret | `JWT_SECRET` exigé au démarrage, 32 caractères minimum, **aucun repli** |

**En pratique :**

- **La fermeture est par défaut, l'ouverture est explicite.** Un garde global plus `@Public` pour se retirer, jamais l'inverse : avec un `@UseGuards` par route, la route qu'on oublie est **ouverte**. Ici la route qu'on oublie est fermée, et l'oubli se voit à l'écran au lieu de se taire sur le réseau. Même polarité que la liste d'autorisation des projections (règle M10) — et c'est la même raison.
- **`@Public` est une décision, pas une commodité.** Chaque ajout à ces huit routes se justifie par écrit et porte son `@Throttle` : une route publique est la seule surface qu'un inconnu peut marteler.
- **Un identifiant venu de l'URL passe par un pipe.** Les 41 `@Param('id')` traversent `FleetbaseIdPipe`, parce qu'ils partent **interpolés dans une URL Fleetbase appelée avec le jeton de service**, qui a tous les droits sur l'organisation. Sans lui, un `../../` détourne la requête vers une ressource que le contrôle d'appartenance n'a jamais examinée.

⚠️ **Authentifier n'est pas autoriser, et c'est la confusion qui coûte le plus cher.** Le garde prouve **qui** vous êtes ; il ne prouve pas que la commande, le conducteur ou l'adresse que vous nommez sont à vous. Cette seconde vérification vit **dans chaque service** (`getMerchantWithValidation`, `resolveOrder`, `getDriverOrFail`, `getFleetWithValidation`) — donc dans quatre-vingt-dix endroits, chacun reposant sur le fait que son auteur y a pensé. **Toute route qui accepte un identifiant doit vérifier l'appartenance avant de s'en servir**, et le pire cas doit être « introuvable », jamais « la ressource de quelqu'un d'autre ».

✅ **Les deux refus sont désormais éprouvés** (02/08/2026) : `scripts/test-frontiere-http.sh` constate les trois refus sur les **87** routes protégées, `scripts/test-appartenance.sh` constate le refus de la ressource d'autrui sur **26** routes, sur les trois personas. Les deux sont dans la suite des scénarios, les deux ont été **prouvés par mutation du vrai code**.

⚠️ **La leçon, et elle vaut plus que les bancs** : la première version du banc de refus a **passé la mutation**. Ouvrir une route la faisait quitter l'ensemble testé, et le total tombait de 87 à 86 sans un mot. **Un contrôle qui prend sa cible dans la donnée qu'il examine ne contrôle rien** — d'où l'épinglage des routes ouvertes, chacune étant une décision qui doit s'écrire.

⚠️ **Reste à couvrir** : 10 des 41 routes à identifiant — remises, encaissements et lecture des preuves, qui demandent un décor **comptable ou photographique** ; 5 autres sont exclues parce que l'appartenance n'y est pas la question. Décomposition complète en Prochaines étapes : un total sans sa décomposition ne se vérifie pas.

⚠️ **Et un refus doit sortir avec son code.** `HttpExceptionFilter` est déclaré `@Catch(HttpException)` : une `TypeError` ou une erreur Prisma **ne passe pas par lui**, sort par le gestionnaire par défaut de Nest, donc **sans `code`** — et l'application retombe sur son message générique au moment précis où l'on comprend le moins ce qui s'est passé. C'est la règle 3 percée sur son chemin le plus obscur.

### 13. Toute entrée traverse un DTO décoré — et la règle se nomme une fois

**Le `ValidationPipe` ne valide que les classes décorées.** Un `@Body() dto: { reason?: string }` typé en ligne n'est pas validé du tout : le pipe n'a aucune métadonnée à lire et laisse passer le corps tel quel. Ce n'est pas une hypothèse — une entreprise de transport a pu contester une remise avec un motif de **longueur illimitée** là où les deux autres personas sont bornés à 500 caractères. Le plafond n'était pas contourné : **il n'existait pas sur ce chemin**.

**L'état mesuré le 02/08/2026** : `whitelist` **et** `forbidNonWhitelisted` — un champ inconnu est *refusé*, pas silencieusement retiré ; **134 champs de DTO sur 14 fichiers, zéro sans décorateur** ; tous les `@Query` typés sauf trois chaînes brutes ; corps limité à 10 Mo ; appels Fleetbase bornés à 30 s.

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

⚠️ **Ce qu'il ne faut PAS fusionner** : `Max(5000000)` sur une remise et `Max(500000)` sur un encaissement sont deux nombres pour deux raisons. Les rapprocher « parce que ce sont deux montants » ferait bouger l'un en corrigeant l'autre.

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
./scripts/run-all-scenarios.sh [conducteur]     # 10 scénarios — le BFF en curl
./scripts/test-frontiere-http.sh                # 87 routes × 3 refus (jeton, rôle, révocation)
./scripts/test-appartenance.sh                  # la ressource de A refusée à B
flutter analyze && flutter test                 # 0 problème · 78 tests
dart tool/check_*.dart [--self-test]            # 5 contrôles · 76 cas dont refus
npm run build                                   # ⚠️ PAS seulement tsc --noEmit

# les TROIS personas joués DANS l'application, sur émulateur (02/08/2026)
./scripts/provision-app-parcours.sh [conducteur]   # pose le décor, imprime la commande
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/parcours_trois_personas_test.dart -d <émulateur> --dart-define=…
```

Les dix scénarios couvrent : parcours d'argent (2 et 3 maillons), multi-appartenance, régularisation commerçant, écart à la porte et dette négative, les deux plafonds, les trois sorties d'une course, **le voyage de la wilaya**, et depuis le 02/08/2026 les deux bancs de la **frontière HTTP** — refus (`test-frontiere-http.sh`) et appartenance (`test-appartenance.sh`), motifs en règle 12.

⚠️ **`test-wilaya.sh` porte ses propres témoins, et c'est ce qui le rend utile.** La wilaya décide de ce qu'un transporteur voit ; une course qui ne la transporte pas est **invisible au filtre**, sans erreur ni journal — une liste simplement plus courte. Trois contrôles, chacun avec son cas négatif dans le même passage :

- **le champ est honoré** — une course avec la wilaya, une sans. Fleetbase abandonne un champ inconnu **sans rien dire**, donc `province` accepté-mais-ignoré aurait exactement la même apparence que `province` stocké ;
- **les deux points** — enlèvement `Alger`, livraison `Blida`, délibérément **différentes** : une recopie de l'un sur l'autre passerait un contrôle à valeur unique ;
- **la duplication conserve** — et la copie d'une course *sans* wilaya ne doit en porter aucune, sinon la duplication en fabriquerait une.

**Éprouvé par mutation du vrai fichier** (la livraison recopie la wilaya de l'enlèvement) : il échoue sur « Wilaya de livraison attendue Blida, lue ALGER ».

⚠️ **Et la mutation elle-même se vérifie.** La première tentative écrivait `null` nu dans un littéral à clé calculée — **TS7018**, le piège déjà documenté plus haut : la compilation échouait, l'ancien code restait en service, et le scénario passait. J'aurais pu en conclure qu'il ne vérifiait rien. Le banc dit désormais « la mutation n'a jamais pris effet — l'essai ne prouve RIEN » plutôt que de trancher : *« le contrôle est aveugle »* et *« la mutation n'est pas en service »* sont deux choses, et les confondre accuse le mauvais coupable.

⚠️ **Les scénarios ne touchent jamais l'application, et c'est leur angle mort.** Ils composent leur corps de requête en `curl` : un écran peut être absent, muet ou fautif sans qu'aucun ne passe au rouge. Les parcours joués **dans** l'app ont trouvé **six défauts** qu'aucun des 87 tests Jest ni des 78 tests Flutter ne pouvait voir :

- une création de course **refusée dès que le contenu du colis n'était pas décrit** ;
- une fiche qui restait « Brouillon » après publication, un garde de relecture comparant des identifiants qui ne pouvaient **jamais** être égaux ;
- une course **déjà démarrée** offerte comme réclamable, que Fleetbase refusait aussitôt ;
- une **clé de traduction affichée en clair** sur la fiche transporteur, la fonction étant appelée avec la table du commerçant ;
- une écriture qui **notifie une classe d'état détruite** quand l'utilisateur quitte l'écran avant la réponse ;
- et `GET /commercant/commandes/:id` qui ne répond qu'à l'uuid.

Détail complet, et les cinq défauts trouvés dans les tests eux-mêmes, dans le journal.

⚠️ **Trois choses à savoir avant de le lancer.** Les personas sont **trois comptes** que le décor provisionne (commerçant validé + carnet, entreprise validée, conducteur invité), et il **refuse un conducteur dont l'email porte plusieurs profils** — `/auth/login` répondrait `requiresRoleSelection` et l'écran attendrait un clic. Les plafonds sont **10 inscriptions par heure** et **5 connexions par minute** (`auth.controller.ts`) : la suite des scénarios consomme huit inscriptions, les parcours une ; le compteur étant un état de service, un `docker restart echango_bff_app` vaut l'heure fraîche. Enfin `android/gradle.properties` fait lire à Gradle un magasin **PKCS12 dérivé du magasin de certificats Windows** : sans lui la compilation échoue en `PKIX path building failed`, le JetBrains Runtime d'Android Studio n'embarquant pas SunMSCAPI — motif complet dans le fichier.

### Outils d'exploitation

- `scripts/provision-platform.sh` — désigne le prestataire **plateforme**, ce qui fait passer les courses du pool de deux à trois maillons. `isPlatform` n'a **aucune route**, délibérément.
- `scripts/reset-test-ledger.sh` — remet à zéro le registre d'un conducteur de test. ⚠️ Développement uniquement : une dette constatée se solde par une remise confirmée, elle ne s'efface pas.
- ⚠️ **Le throttle d'inscription (10/h) est la vraie limite de la suite** : elle en consomme huit. Elle passe dans une heure fraîche, pas deux fois de suite.

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

Voir le plan d'action détaillé et priorisé dans `docs/specs_echango_delivery.md` §9. Résumé :


> 📓 **Les travaux achevés vivent dans [`docs/journal_travaux.md`](docs/journal_travaux.md)**
> — 63 entrées, du 26/07 au 01/08/2026, avec les défauts rencontrés et leur motif.
>
> Ce qui reste ici : **ce qui n'est pas fait**. Une case cochée n'a plus rien à
> apprendre à qui écrit du code aujourd'hui ; une case vide, si.

- [x] ✅ **Paginer côté Fleetbase là où c'est possible — fait le 02/08/2026**, et l'énoncé de départ était trop large.

  **Un seul site était déplaçable, pas trois.** `FlotteService.getOrders` découpe désormais côté Fleetbase (`getOrderPage`), avec `facilitator` et `status` passés au serveur et `meta.total` relu. Les autres restent, et c'est justifié : `isClaimable` combine statut, `adhoc`, conducteur et facilitateur, `listOrders` (transporteur) applique ensuite véhicule, refus et **zone** — aucun filtre Fleetbase ne les exprime, il faut tout ramener. Le compte de « sept sites » venait d'un recensement, pas d'un examen de chacun.

  ⚠️ **Ce qui rend l'optimisation sûre est le repli, pas le filtre.** Si `meta.total` manque, la route **reprend le parcours complet** au lieu de deviner : `orders.length` dirait « voilà tout » sur une page pleine, donc une liste tronquée en silence — exactement le défaut que le total servi corrige. Le chemin lent est conservé parce qu'il est **juste** ; l'optimisation ne peut donc pas produire un résultat faux, seulement ne pas s'appliquer.

  ⚠️ **Le contrôle d'appartenance en mémoire reste**, et ce n'est pas un doublon : le filtre serveur allège, il n'autorise pas. Une régression de nom de filtre **vide la page** au lieu de servir les courses d'une autre entreprise.

  **Mesuré, chaque filtre contre un témoin inventé** (422 commandes) : `facilitator` 26 contre 0, `status=created` 37 contre 0, `without_driver` 123 contre 422. Bout en bout : la route rend 26, Fleetbase en compte 26 pour ce vendor, deux pages consécutives ne se recouvrent pas, et `status=created` rend 2 — le compte exact de la base.

  ⚠️ **Mon premier banc comparait le NOMBRE DE LIGNES et non les totaux.** Plafonné à `limit=100`, il rendait 100 des deux côtés et concluait « filtre ignoré » sur un filtre qui marchait. C'est le défaut que ce banc existe pour détecter, commis dans le banc. ⚠️ Et un `0` contre un témoin à `0` ne prouve rien non plus : `status=completed` rendait 0, ce qui pouvait aussi bien dire « filtre cassé » — il a fallu la répartition réelle (24 `dispatched`, 2 `created`) pour savoir que le zéro était vrai.

  ⚠️ **Le reste de l'audit est sain, et le dire évite de le refaire** : les seize tables sont justifiées, y compris les cinq dont je croyais un moment qu'elles ne l'étaient pas — mon filtre cherchait `///` là où elles emploient `//`. Le registre COD est l'exception nommée, `DriverMembership` est une relation n-n que `Driver.vendor_uuid` ne peut pas porter, `AuditLog` enregistre des refus que Fleetbase ne voit jamais, et la décision sur les comptes est tranchée dans `specs_bff.md` v2 (`customer-portal-api` ne couvre que le commerçant, rien n'existe pour la flotte ni pour le conducteur).

- [ ] **Le transporteur choisit ce qu'il voit : wilaya d'abord, rayon autour (décidé ET branché le 02/08/2026 — sauf les notifications)**

  ⚠️ **Décisions prises, à ne plus reposer.** Elles répondent à l'arbitrage laissé ouvert par la revue du 28/07 (« la diffusion est à 15 km mais la liste est à l'échelle de l'organisation »). Ce n'était pas une divergence à corriger : **c'est le transporteur qui choisit sa course**, pas le rayon qui choisit pour lui.

  | question | décision |
  |---|---|
  | qui décide de la course ? | **le transporteur** — la liste ne doit pas trancher à sa place |
  | filtre principal | **la wilaya**, et elle est **obligatoire** |
  | filtre secondaire | un **rayon autour de son point**, pour « chercher autour » |
  | valeur par défaut du rayon | **15 km** — sans quoi il voit les courses de toutes les wilayas |
  | distance mesurée depuis | **sa position**, pas une base déclarée |
  | wilaya d'enlèvement ou de livraison ? | **enlèvement** — c'est là qu'il doit se rendre |
  | le rayon gouverne-t-il les notifications ? | **oui**, pas seulement l'affichage |
  | où vit la préférence ? | **champs personnalisés Fleetbase si `Driver` les supporte** (règle 1), colonne BFF sinon |

  ⚠️ **Ce qui est décidé n'est pas ce qui est branché, et l'écart est mesuré** — c'est la leçon du 01/08 sur `specs_facilitateur.md`, où des décisions consignées se lisaient comme un état livré.

  **Ce qui existe déjà** : le géocodage inverse **extrait la wilaya** (`state`/`region` → `province`, `common/geocoding/geocoding.service.ts`), et le carnet d'adresses la conserve — `SaveAddressDto.province`, `SavedAddress.province`, l'écran d'adresses la saisit.

  ✅ **La wilaya voyage — fait le 02/08/2026.** `CreateOrderDto` porte désormais `pickupProvince` et `dropoffProvince`, `createPlace` les écrit, le formulaire les capture depuis le carnet **et** depuis la carte, et la duplication les restaure (elle les perdait, comme elle avait perdu `podMethod` et la quantité de colis avant). **Vérifié par témoin** : une course créée avec la wilaya rend `payload.pickup.province = "ALGER"`, une créée sans rend `null` — Fleetbase abandonnant un champ inconnu sans rien dire, c'est la seule preuve qui vaille.

  ✅ **La préférence et le filtrage de la liste — faits le 02/08/2026.** `common/orders/driver-zone.ts` porte la décision (`zoneAllows`, 22 tests), `fleetbase/driver-zone.service.ts` la range dans les **champs personnalisés du `Driver`**, `GET`/`PUT /transporteur/zone` l'exposent, et `lib/screens/transporteur/zone_card.dart` la règle depuis l'onglet profil — sans quoi seul un opérateur pourrait le faire depuis la console (règle 9).

  ✅ **`Driver` supporte bien `HasCustomFields`** — vérifié dans le source `fleetops` (ligne 60 du modèle, avec quatorze autres modèles), puis **en réel**. La préférence n'est donc dans aucune colonne BFF : la règle 1 est tenue.

  ⚠️ **Trois pièges Fleetbase mesurés en la branchant**, tous invisibles à la lecture : `PUT /int/v1/drivers` exige un corps **enveloppé** `{driver: {…}}` (sinon 500, `TypeError`) et n'accepte que le `public_id` ; la création d'une définition répond sous la clé `custom_field` et non `custom_field_value` ; et **la chaîne vide est refusée sur tout type de champ**, d'où `ZONE_UNSET = '-'` pour dire « effacé » — un `null` ne pouvant pas être écrit.

  ⚠️ **Le filtre est prouvé dans les deux sens, et c'est la seule preuve qui compte** (règle 8) : un filtre qui ne retire rien est indiscernable d'un filtre absent.

  | préférence du conducteur | courses visibles |
  |---|---|
  | aucune | 2 |
  | wilaya = Alger | 2 |
  | wilaya = Tamanrasset (témoin) | **1** — celle sans wilaya, qui reste montrée |
  | retour à aucune | 2 |

  ⚠️ **Le biais, et il est délibéré : ce qu'on ignore ne cache jamais du travail.** Course sans wilaya, course sans coordonnées, transporteur sans position — chaque absence **laisse passer**. Même raison que les statuts inconnus dans `isOrderClaimable` : une course offerte puis refusée est un désagrément, une course jamais montrée est un manque à gagner que personne ne peut constater. Sept des 22 tests ne vérifient que cela.

  ⚠️ **La hiérarchie wilaya → rayon n'est pas un ordre de lecture, elle bouche un trou** : à rayon seul, un transporteur dont on ignore la position ne verrait **aucune course**. La wilaya est déclarée et ne dépend d'aucun capteur ; le rayon est un raffinement qui peut ne pas s'appliquer, et l'écran le dit quand c'est le cas.

  ⚠️ **`DEFAULT_ZONE_RADIUS_KM = 15` est une valeur d'écran, jamais un filtre implicite.** Elle pré-remplit le champ ; `zoneAllows` ne filtre que sur ce qui est **déclaré**. Les confondre ferait disparaître du travail pour tous ceux qui n'ont jamais ouvert le réglage — et « le choix revient au transporteur » cesserait d'être vrai pour eux.

  ✅ **La sollicitation d'un favori honore la zone — fait le 02/08/2026.** C'est **le seul chemin à nous** qui décide à qui va une course : `pickAvailableFavourite` pose `driver_assigned_uuid`, donc **sort la course du pool**.

  ⚠️ **C'est là que ça compte le plus, et l'argument est celui que le code faisait déjà pour `online`** : confier une course à quelqu'un qui a filtré cette wilaya, c'est la confier à quelqu'un qui ne la regardera pas — et **rien ne la reprend** (le second repli, différé, n'existe pas). Le repli, lui, est sans danger : la course part au pool.

  La règle vit dans `zoneAllowsPickup` et **nulle part ailleurs** : `OrderPickup` existe parce que les deux chemins n'ont pas la même chose en main — la liste tient une commande Fleetbase, la sollicitation se décide **avant que la commande existe**. Un test vérifie que les deux rendent la même réponse, sans quoi un transporteur serait écarté d'une liste **et** assigné d'office à la même course.

  ⚠️ **Prouvé à deux branches en réel**, le même favori, la même course : zone = Tamanrasset (départ à Alger) → **non assignée** ; zone effacée → **assignée**. Un filtre qui n'écarte jamais est indiscernable d'un filtre absent.

  ⚠️ **Et le banc a failli conclure trois fois à tort** : création refusée sur des champs de contact manquants (les deux branches disaient « non assignée »), route de mise en ligne inexistante (un favori hors ligne n'est jamais sollicité, donc même faux vert), et lecture des clés Fleetbase alors que la réponse est la ligne **locale** (`driverAssignedUuid`). Il refuse désormais de conclure quand la course n'a pas été créée.

  **Reste à faire** : **les notifications push**. ⚠️ Rien n'est branché aujourd'hui — le dispatch géospatial est **entièrement celui de Fleetbase** (`adhoc_distance` posé sur la course), et le BFF n'a **aucun chemin de notification vers les conducteurs**. Y ajouter un filtre de zone maintenant créerait du code sans appelant, c'est-à-dire le défaut le plus répété du dépôt (règle 9). À faire **en même temps** que le premier envoi réel, avec `zoneAllowsPickup` déjà prêt — sinon la préférence mentira sur un canal et pas sur l'autre.

  **Un point resté à trancher** : une course qui traverse deux wilayas doit-elle apparaître dans les deux ? Aujourd'hui non — seul l'enlèvement décide.

- [ ] **Responsabilité des espèces — tranché le 02/08/2026 (décision produit, contrat à écrire)**

  | cas | qui répond des espèces |
  |---|---|
  | conducteur rattaché à une **entreprise** | **l'entreprise** |
  | conducteur **indépendant** (pool) | **Echango** |

  **Le code fait déjà cela** : sur une course du pool, Echango est le facilitateur (`isPlatform`), et le registre route la dette de l'indépendant vers Echango. Décision et implémentation s'accordent — pour une fois, il n'y a rien à brancher.

  ⚠️ **Deux conséquences qui changent des points ouverts ailleurs dans ce fichier** :

  - **La commission redevient recouvrable.** `docs/specs_flux_argent_quatre_acteurs.md` la donnait comme perdue, « aucun flux conducteur → Echango sur lequel compenser ». Si Echango est la contrepartie de l'indépendant, **ce flux existe** : la retenue est possible.
  - **Le plafond de dette cesse de protéger le commerçant pour devenir l'exposition d'Echango.** Son montant n'est donc plus un réglage de confort, c'est un appétit au risque — à fixer comme tel.

  **Ce que ça ne règle pas** : la question juridique demeure, mais elle se déplace. Elle n'est plus « qui est responsable » — c'est tranché — mais « le contrat Echango–transporteur suffit-il à couvrir la détention d'espèces pour compte de tiers ». À voir avec les transporteurs et les commerçants.

- [x] ✅ **Devise — fait le 02/08/2026, et la cause n'était pas celle qu'on croyait**

  « 777 USD » à côté de « À encaisser : 2727 DZD ». La ligne d'origine attribuait l'écart à « deux sources qui se contredisent » — c'était vrai, mais la source du `USD` a été trouvée ailleurs, et elle est instructive.

  ⚠️ **`Order` a DÉJÀ une colonne `currency` chez Fleetbase, dont le défaut est `USD` — et notre champ personnalisé porte le même nom.** Sur la **liste**, où les valeurs des champs personnalisés sont absentes (ressource d'index), le repli « à plat » de `readOrderCustomFields` lisait `order.currency` — celle de Fleetbase — et, les champs personnalisés étant fusionnés **en dernier**, cette valeur **l'emportait** sur le `DZD` correct venu de `specMeta`. **Un repli qui gagne contre sa source n'est plus un repli.**

  ⚠️ **Aucune relecture ne pouvait le montrer** : chaque couche prise séparément disait `DZD` — le champ personnalisé, `meta`, `specMeta` — et l'écran disait `USD`. Il a fallu comparer ce que servent **la liste et la fiche pour la même commande** : fiche `DZD`, liste `USD`. Les treize clés du catalogue ont ensuite été comparées aux 37 de la ressource d'index — **une seule collision**, celle-là. À refaire à chaque nouveau champ personnalisé : un nom déjà pris par Fleetbase ne produit aucune erreur, seulement une valeur silencieusement fausse.

  **Deux corrections, parce qu'elles ne traitent pas le même manque** : le repli à plat ignore désormais les clés que Fleetbase sert lui-même (`FLEETBASE_OWNED_ORDER_KEYS`) ; et la devise est décidée **en un seul endroit** (`common/money/currency.ts`, DZD par défaut), que lisent la tarification, le registre de caisse et la projection — sans quoi la même décision resterait écrite trois fois (règle 5).

  ⚠️ **Aucune conversion, et aucune devise sans montant** : « DZD » seul décrirait une somme qui n'existe pas (règle 10). Vérifié en réel — **50 courses servies en USD avant, 0 après** (26 en DZD, 24 sans prix donc sans devise). Éprouvé par mutation : sans la garde et sans la normalisation, 4 des 9 cas échouent.

  **Reste ouvert** : l'Organization Fleetbase a-t-elle un champ devise ? Si oui, c'est de la configuration, et la constante deviendrait un repli au lieu d'une décision.

- [ ] **Robustesse des API — audité le 02/08/2026, rien n'est corrigé** (règles 12 et 13). La mécanique est meilleure que ne le suppose la question qui a lancé l'audit ; ce qui manque, ce sont les **preuves** et six correctifs courts.

  ✅ **(1) Le banc de refus — fait le 02/08/2026** (`scripts/test-frontiere-http.sh`, 9ᵉ scénario). **259 appels, 87 routes protégées, trois refus chacune** : sans jeton (401 `auth.missing_token`), avec un jeton révoqué (401 `auth.session_revoked`), avec le jeton d'un autre rôle (403 `server.persona_forbidden`). Le **code** est vérifié, pas seulement le statut — un 401 sans code est une protection que l'application ne sait pas traduire.

  **Il énumère les routes depuis la source** : une route ajoutée demain est couverte sans que personne y pense. Les identifiants d'URL sont volontairement inexistants, pour qu'un garde tombé ne se traduise pas par une vraie ressource modifiée.

  ⚠️ **Et il a fallu deux versions, parce que la première a passé la mutation.** `@Public` posé sur `GET /commercant/commandes` : le banc est passé **au vert**, de 87 routes à 86 — la route ouverte avait simplement **quitté l'ensemble testé**, en silence. C'était le défaut exact qu'il existe pour attraper, et il l'a laissé passer parce qu'il **prenait sa cible dans la donnée qu'il examinait**. Les huit routes ouvertes sont désormais **épinglées** (`PUBLIC_ROUTES`) : en ouvrir une neuvième fait échouer le banc tant que la décision n'est pas écrite là. Prouvé ensuite dans les deux sens — brèche → refus (sortie 1), correction → 259/259 (sortie 0).

  ✅ **(2) Le banc d'appartenance — fait le 02/08/2026** (`scripts/test-appartenance.sh`, 10ᵉ scénario). **26 routes éprouvées, 26 refus** sur les trois personas. La ressource de A demandée avec le jeton de B rend 403 ou 404, jamais la ressource.

  **Le compte exact des 41 routes à identifiant**, parce qu'un total sans sa décomposition ne se vérifie pas :

  | | routes | |
  |---|---|---|
  | **éprouvées** | **26** | commandes, adresses, favoris, notifications (commerçant) · commandes, adhésions (entreprise) · course assignée, dépôt de preuve, rattachements (transporteur) |
  | exclues, l'appartenance n'y est pas la question | 5 | opportunités (visibles à toute entreprise), prendre une opportunité, inviter un conducteur, accepter/refuser une course libre |
  | décor **comptable** | 8 | `remises/:id/confirmer\|contester` des trois personas et `encaissements/:id/confirmer\|contester` du transporteur — les poser demanderait d'**écrire dans le registre de caisse** |
  | décor **photographique** | 2 | `GET preuves/:id` (commerçant et transporteur) — il faut une preuve existante, donc une livraison achevée avec sa photo |

  ⚠️ **Une route avait été rangée sur son NOM plutôt que sur son besoin.** `POST /transporteur/commandes/:id/preuve` était comptée avec les preuves à décor parce qu'elle en porte le mot — alors qu'elle n'exige **aucune preuve existante** : une photo dans le corps (un PNG d'un pixel suffit) et une course de A, que le banc avait déjà. Le tri paresseux que ce fichier dénonce partout, commis dans son propre inventaire.

  ⚠️ **Chaque épreuve porte son témoin, et c'est ce qui la rend non tautologique** : A doit d'abord obtenir SA ressource (2xx). Un identifiant du **mauvais type** rend 404 partout — un banc naïf y lirait « l'appartenance est vérifiée » et serait vert sans rien prouver. Sans témoin, le persona est déclaré **non couvert**, jamais réussi. Les identifiants sont découverts en listant les ressources de A, jamais écrits en dur.

  Prouvé par mutation du vrai service : `getOrderDetail` privé de son filtre par commerçant → « **SERVIE À B (200)** », sortie 1 ; restauré → 10/10, sortie 0.

  ⚠️ **Trois précautions de conception, chacune née d'un essai qui prouvait moins qu'il n'en avait l'air** :

  - **Le témoin faible est nommé comme tel.** Il n'existe pas de `GET /commercant/adresses/:id` : exercer PUT ou DELETE avec le jeton de A pour prouver que la route répond **détruirait sa donnée**. Le témoin se réduit alors à « l'identifiant vient de la liste de A », et le rapport l'écrit plutôt que de laisser croire à une preuve à deux temps.
  - **Le banc pose son propre décor** quand A n'a pas la ressource (un favori), et le retire. Sans cela il resterait durablement « incomplet », donc rouge — et **un banc durablement rouge finit ignoré**. ⚠️ Le décor exige un **vrai** conducteur : un identifiant inventé est refusé en 400, et la sonde ne prouvait rien.
  - **Les corps des sondes viennent des DTO réels**, pas d'une supposition — `activity` est un objet, `reason` vient d'une liste fermée, `terminer` attend un montant. Un corps invalide fait répondre 400 **avant** l'appartenance : la route ressort « non concluante » et reste non éprouvée sous couvert de refus. Deux routes étaient dans ce cas.

  ⚠️ **Deux décisions de conception ajoutées en complétant la couverture** :

  - **Le banc ne sonde que des identifiants que le pipe accepte.** La liste des encaissements du transporteur mêle des lignes `earning:<uuid>` dont le deux-points est hors du motif de `FleetbaseIdPipe` : les sonder donnait 400 **avant** toute question d'appartenance, et deux routes restaient non éprouvées sous couvert de refus.
  - **Une ressource absente est NOTÉE, pas fatale — et c'est un arbitrage.** Un encaissement n'existe qu'après une livraison payée à la porte ; en poser un demanderait d'écrire dans le registre de caisse, ce qu'un banc de sécurité n'a pas à faire. Mais faire échouer le banc quand la base n'en porte pas le rendrait **durablement rouge, donc ignoré** — et un banc ignoré ne protège rien. Il l'imprime à chaque passage dans son récapitulatif, plutôt que de se taire ou de crier.

  ⚠️ **Trois fois le banc a accusé le mauvais coupable avant d'être juste** : un champ hors DTO refusé par `forbidNonWhitelisted` (ma propre inscription, rejetée par la validation stricte), des comptes créés mais **en attente de validation** (`merchant_pending`), et le **plafond de connexion que le banc épuisait lui-même** (5/min) — il rapportait alors « persona NON COUVERT », un verdict qui accuse l'appartenance pour un problème de débit. Les trois disaient la même chose : *« je n'ai pas pu savoir »* n'est pas *« rien à signaler »*.

  ✅ **(3) L'hygiène de la frontière, tenue par un test — fait le 02/08/2026** : `common/dto-hygiene.spec.ts` refuse un `@Body` typé en ligne, un champ de DTO sans décorateur, un `@Param('id')` sans pipe, et une regex partagée recopiée en clair. Onze cas, dont **six qui doivent échouer**, et une **mutation de deux vrais fichiers** (pipe retiré, motif recopié) qui les fait tomber tous les deux.

  ⚠️ **Un test Jest plutôt qu'un script à part** : il tourne avec `npm test`, donc il ne peut pas être oublié. Et **il protège le code à venir, ce qu'aucun rangement du code présent ne fait** — le dépôt était déjà propre sur ces quatre points ; ce qui manquait, c'est ce qui empêche la prochaine route de rouvrir un des quatre trous.

  ✅ **(4) La copie échappée** de `register.dto.ts` importe désormais `FLEETBASE_ID_PATTERN`.

  ✅ **(5) Les correctifs courts — faits le 02/08/2026, et constatés en service** :

  - **`@Catch()` sans argument** : le filtre attrape désormais **toutes** les exceptions, pas seulement les HTTP. Une `TypeError` ou une erreur Prisma sort avec `server.unexpected` au lieu de sortir sans `code` — la règle 3 était percée sur son chemin le plus obscur. ⚠️ **Le message d'origine ne sort pas** (une erreur Prisma cite des colonnes, une erreur Axios une URL interne) ; il va au journal. Six cas, dont le témoin qui vérifie qu'une `HttpException` garde son propre code — sans lui, un filtre qui écraserait tout en `server.unexpected` passerait les cinq autres.
  - **En-têtes de sécurité, sans `helmet`** : `nosniff`, `DENY`, `no-referrer`, et `X-Powered-By` retiré. ⚠️ Écrits à la main **parce que le BFF sert du JSON à deux applications mobiles** : sur les quinze en-têtes d'`helmet`, la douzaine qui concerne le rendu n'a aucun effet ici. **Cet arbitrage tombe le jour où une page web est servie.**
  - **CORS** : le défaut `FLEET_APP_URL` valait `http://localhost:3001` — **le port du BFF lui-même**.
  - **`driverIds` borné** par un DTO (`DriverPositionsQueryDto`) : il était lu en `@Query('driverIds')`, donc **hors du `ValidationPipe`**. Constaté : liste normale 200, liste énorme **400**, caractères hors motif **400**.
  - **Identifiant de corrélation** : posé sur chaque requête, rendu en `X-Request-Id`, présent dans le journal et dans le corps d'erreur. L'en-tête entrant est **repris** mais **nettoyé** — sinon une chaîne venue du dehors finirait recopiée dans un journal qu'on lit. Constaté : `bad<>;value` → `badvalue`.
  - ⚠️ **Reste ouvert** : le débit est par IP et **en mémoire** — derrière un proxy sans `TRUST_PROXY` correct tout le monde partage un compteur, et à deux instances les compteurs ne s'additionnent pas. À traiter au déploiement VPS.

  ⚠️ **Deux mutations n'ont pas pris effet avant d'être justes**, et c'est à consigner : casser `/health` pour déclencher une erreur non HTTP a laissé la route répondre 200 (essai sans valeur, remplacé par un test unitaire sur le vrai filtre), et désactiver le filet par `if (false)` a **cassé le typage** — la suite ne compilait plus, ce qui n'est pas un refus. *« La mutation n'a jamais pris effet »* et *« le contrôle est aveugle »* sont deux choses.

  **(6) Deux décisions à prendre, pas des correctifs :**

  - **Chaque requête coûte une lecture en base** (`active` + `tokenVersion`). C'est le prix de la révocation immédiate, et il est peut-être juste — mais il fait dépendre l'**authentification** de Postgres : sous lenteur, tout tombe ou traîne. À assumer explicitement ou à mitiger (cache court, révocation différée).
  - **L'idempotence de l'argent est décidée route par route** — `declareCollection` est permissive, `declareRemittance` volontairement pas. Un double appui sur un réseau instable est un cas réel ; la question mérite une réponse d'ensemble plutôt qu'un choix par auteur.

  ⚠️ **Ce que l'audit ne dit pas** : que la validation est faible. Elle ne l'est pas — `whitelist` + `forbidNonWhitelisted`, 134 champs tous décorés, 41 identifiants tous filtrés. Ranger davantage les DTO **ne comble aucune des deux vraies brèches**, qui sont (1) et (2).

  ⚠️ **Et une leçon de méthode, parce qu'elle s'est produite trois fois dans la même journée** : mon scanner de DTO a annoncé **six champs non validés qui l'étaient tous** — il s'arrêtait sur le `})` d'un décorateur multi-ligne. Deux versions ont échoué avant la bonne. **Un outil d'audit se vérifie comme un vérificateur** : sur des cas dont on sait qu'il doit les refuser, et sur des cas dont on sait qu'il doit les accepter.

- [ ] **Priorité 3** : trancher les règles métier non tranchées (tarification, commission, annulations, SLA, onboarding — liste complète dans `docs/specs_echango_delivery.md` §6).
- [x] ✅ **Migrer les données métier de `meta` vers les champs personnalisés — FAIT**, et vérifié dans le code le 02/08/2026 : `createOrder` envoie `custom_field_values`, `meta` ne porte plus que `pricing_inputs`, et `effectiveOrderMeta` sert les trois couches par ordre de durabilité. ⚠️ **Cette ligne est restée cochée « à faire » après coup**, ce qui a fait reposer la question deux jours plus tard.

- [ ] **Le nom `meta` sur le contrat, alors que la source est `custom_field_values` (ouvert le 02/08/2026)** — le BFF sert l'objet fusionné sous le nom `meta`, donc un lecteur croit lire le `meta` de Fleetbase quand il lit surtout des champs personnalisés.

  ⚠️ **`custom` serait faux dans l'autre sens** : la fusion contient aussi le `meta` historique et `specMeta`, pour les commandes d'avant la migration. Le nom juste dirait « les données métier effectives, quelle que soit leur couche » — la fonction s'appelle déjà `effectiveOrderMeta`, c'est le nom **sur le fil** qui ment.

  **Ce que ça coûte** : le champ est lu partout — modèles Flutter des trois personas, projections, scénarios shell. Contenu mais réel. **Ce que ça n'est pas** : un prérequis aux tests humains — aucun testeur ne voit ce JSON.

- [ ] ~~**Ancienne note de migration, conservée pour le motif**~~ (30/07/2026, § Règles §1) : `meta` est remplacé en entier par toute mise à jour qui le mentionne, et la console le fait en affectant un transporteur. `custom_field_values` est la mécanique prévue — table séparée, synchronisée seulement si la requête la porte, `delete_missing` désactivé par défaut. **Ce que ça demande** : déclarer les définitions `CustomField` sur l'`OrderConfig` (une par donnée : prix, montant à encaisser, marchandise, véhicule, préférence de favoris…), les envoyer sous `order.custom_field_values` à la création, et les relire via `with[]=customFieldValues`. **Ce que ça apporte en plus de la sûreté** : un admin peut corriger un prix depuis la console et cette correction est visible — ce que `meta` ne permettait pas de façon fiable. **À vérifier en réel avant de basculer** : le format exact accepté par `syncCustomFieldValues`, le comportement quand une définition manque, et si la console affiche bien ces champs sur la fiche commande. `Order.specMeta` reste jusque-là, et sera retiré ensuite.
- [ ] **Signaler le bug à l'amont** (`fleetbase/fleetops`) : `addon/services/order-actions.js` → `assignDriver()` sauvegarde une commande issue de la ressource d'index sans la recharger, ce qui écrase `meta` avec le drapeau `_index_resource`. Le correctif tient en trois lignes et existe déjà partout ailleurs dans le même dépôt (`place-actions.js`, `driver-actions.js`, `vehicle-actions.js`, route de détail des commandes) : `if (order?.meta?._index_resource) await order.reload();`. `unassignDriver()` fait le même `order.save()` et mérite la même vérification.
- [ ] **Au déploiement VPS — brancher les webhooks Fleetbase (Lot 5)** (`docs/plan_migration_fleetbase.md` §7, journal §25) : reporté le 29/07/2026 parce que **Fleetbase refuse toute URL de webhook non publique** (« The url must be a public HTTP or HTTPS URL » — ni `localhost`, ni `host.docker.internal`), ce qui imposait un tunnel, c'est-à-dire exposer un service sur Internet pour un contrôle de dix minutes. Sur le VPS l'obstacle disparaît : domaine et certificat suffisent. **L'endpoint `POST /webhooks/fleetbase` a été écrit puis retiré le même jour** — une route publique sans vérification de signature qu'on ne rouvrirait qu'au déploiement serait déployée avec le reste ; il est dans l'historique git. `scripts/webhook-listener.js` est conservé, c'est un outil de développement autonome. **Entre-temps `OrderReconcilerService` fait le travail**, avec `Order.status`/`Order.driverAssignedUuid` pour mémoire, et la chaîne est validée en réel (§23.5) — plus lent et plus coûteux qu'un webhook, mais pas un pis-aller. **Ordre au moment de le reprendre** : déclarer le webhook (tous identifiants API, tous évènements — leur vocabulaire réel est inconnu), observer avec l'écouteur pour relever le nom et le format de l'en-tête de signature, la forme du corps (commande entière ou simples identifiants ? cela décide si le réconciliateur peut disparaître), **puis seulement** recréer l'endpoint — signature d'abord, effets ensuite.
- [ ] **Au déploiement VPS — `APP_DEBUG=false` côté Fleetbase** : le 500 du filtre `phone` observé le 29/07/2026 renvoyait une page d'erreur Laravel complète (chemins de fichiers, requêtes SQL).
- [ ] **Au déploiement VPS — reconfigurer le contournement de preuve photo** (journal §7.8, §11.9) : le BFF envoie `disk`/`bucket` dans la requête pour contourner un bug amont Fleetbase, et cette valeur **prend le pas sur la config serveur**. Passer en S3 sans renseigner `FLEETBASE_PROOF_DISK=s3` et `FLEETBASE_PROOF_BUCKET=<bucket>` ferait écrire sur le disque public malgré une config S3 correcte, sans erreur visible. Vérifier au passage si l'amont a corrigé la ligne : si oui, retirer le contournement, qui deviendrait nuisible. **Prérequis en développement** : `FLEETBASE_PROOF_DISK` vaut `public` par défaut et exige `php artisan storage:link` côté Fleetbase — sans ce lien le fichier est écrit mais aucune route ne le sert.
- [ ] **Reste du plan de migration** (`docs/plan_migration_fleetbase.md`) : le **Lot 5 est reporté au VPS**, voir la ligne dédiée ci-dessous. Tous les autres lots sont clos. Anciennes vérifications restantes : les filtres `orders?customer|facilitator|driver` et `drivers?query` par appel réel, **toujours en comparant un filtre valide à un filtre inexistant** ; le comportement du cache Redis après écriture (deux requêtes) ; `$filterParams` sur le modèle `Order` ; le champ de statut du `Vendor` pour la validation commerçant ; l'émission et la politique de relance des **webhooks** `fleetops`, qui remplaceraient le réconciliateur et le miroir de statut.
- [ ] **Trois chantiers de mutualisation, décidés le 31/07/2026** — ils correspondent aux règles 5, 6 et 7, et ils sont écrits ici parce qu'une règle sans chantier est une règle que le code viole en silence. **Ordre recommandé : 3, puis 2, puis 1** — le troisième est le moins risqué et rend les deux autres mécaniques. **Les trois sont faits** (voir chacun ci-dessous pour ce qu'il a trouvé).

  ⚠️ **Aucun `flutter analyze` n'est possible dans ce bac à sable** (pas de toolchain Dart). Les contrôles menés à la place sont mécaniques, nommés, et **chacun a attrapé au moins un défaut réel** : équilibre des délimiteurs par un scanner qui comprend l'interpolation Dart ; portée de chaque `scheme`/`semantic`/`context` aux sites modifiés — c'est lui qui a trouvé un `scheme` employé sans exister ; imports manquants et devenus inutiles ; et **aucune chaîne visible perdue**, comparée à HEAD par un extracteur qui *concatène les littéraux adjacents* (sans quoi un simple ré-enveloppement de ligne passerait pour une modification de texte). Deux lots sont en outre prouvés **par inversion** : resubstituer les jetons d'espacement, ou réécrire chaque `AppSectionCard` en `Card > Padding`, redonne la version précédente au caractère près. Rien de tout cela ne remplace l'analyseur — à passer côté utilisateur.

  ⚠️ **Une erreur de méthode commise deux fois dans ce chantier, à consigner** : remplacer un bloc par une **tranche entre deux ancres** au lieu du bloc entier. Dans `orders_screen.dart` la tranche a avalé le `return` suivant, et la liste non vide s'est retrouvée à rendre l'ancien état vide. Fichier repris depuis git, refait avec des ancres complètes, et le transformateur de cartes de section a ensuite été écrit à parenthèses équilibrées pour cette raison.

  **(1) Mutualisation des fonctions** (règle 5) — **✅ fait le 31/07/2026, en quatre lots.** Six défauts réels en sont sortis, et **aucun n'a été trouvé en relisant**.

  ⚠️ **Le `grep` sur les formules d'aveu (« doit rester identique à ») n'a donné qu'un cas sur quatre.** Les trois autres sont venus d'une **comparaison mécanique des corps de fonction**, normalisés puis appariés par similarité — ce que la prose ne pouvait pas trouver, puisqu'une copie muette ne s'annonce pas. C'est l'outil à reprendre au prochain passage, pas le `grep`.

  **(a) Un test qui recopiait ce qu'il vérifie.** `subscriber-number.spec.ts` portait une copie de `subscriberNumber`/`sameIdentifier` et s'en justifiait par la dépendance à Prisma. **La copie avait déjà divergé** : le service commençait par `if (typeof stored !== 'string' || !stored.trim())`, pas elle — or `email` et `phone` sont facultatifs sur un conducteur, donc `null.trim()` aurait levé au milieu d'un contrôle de doublon. La justification tenait, la conclusion non : il suffisait d'extraire dans un module qui n'importe rien. Un cas ajouté vient d'une **mutation**, pas d'une relecture — assouplir la longueur exigée (`=== 9` en `>= 6`) laissait les cinq autres au vert.

  **(b) Cinq façons d'écrire une date, dont deux fausses.** Le détecteur a trouvé deux fonctions identiques sous deux noms ; le reste est apparu en regardant toutes les dates. **L'écran transporteur affichait « Créée le » en UTC** — une heure trop tôt, juste au-dessus d'une date d'échec que le même écran localisait correctement. Plus un rembourrage manquant (« 5/8 » contre « 05/08 ») et un format ISO isolé. `utils/dates.dart` + un test qui **dit ce qu'il ne peut pas prouver** : recalculer l'attendu avec `toLocal()` serait une tautologie, donc le cas de localisation est neutralisé sur une machine en UTC plutôt que faussement rassurant.

  **(c) Une décision « erreur → message » écrite 34 fois**, en trois vocabulaires et pour six usages du résultat. `messageForError()` la porte ; la plomberie (`_isLoading`, `notifyListeners`, la relecture) reste chez chaque classe — la fusionner aurait demandé un paramètre par variante, soit la duplication déguisée en factorisation. **Quatre trous invisibles site par site** : trois `catch` sans repli du tout, alors que `getMerchantAddresses` et `addFavouriteDriver` n'enveloppent pas leurs erreurs réseau — un `SocketException` remontait **non géré**, écran muet ; et un quatrième affichait « erreur inconnue » sur un code qui a une traduction.

  **(d) Le cas où le critère a dit « ne pas fusionner », et avait raison.** Trois enveloppes HTTP `confirm*Remittance` à 93-96 % : trois routes distinctes, qui ne doivent pas changer ensemble. C'est leur **divergence de surface** qui valait d'être suivie — la variante flotte sérialisait `{'reason': null}` là où les deux autres omettaient la clé. En remontant le fil : **la route flotte n'avait aucun DTO**, seulement un type en ligne `@Body() dto: { reason?: string }`, et le `ValidationPipe` ne valide que les classes décorées. Une entreprise pouvait donc contester avec un motif de **longueur illimitée** là où les deux autres personas sont bornés à 500 caractères. Le plafond n'était pas contourné — il n'existait pas sur ce chemin. Et les deux personas qui l'avaient portaient **chacun leur copie du DTO**.

  ⚠️ **Ce qui a été délibérément laissé, et pourquoi.** Les trois enveloppes d'écriture des classes d'état (`_mutate`, `_addressWrite`, `_mutateOrder`, 93-98 %) ne diffèrent que par la relecture qu'elles déclenchent — mais les fusionner demanderait un `mixin` accédant à des champs privés de quatre classes, pour aucun défaut observable. Le critère prévoit ce cas : l'invariant se tient alors par un contrôle. Ici il tient **par construction** — il ne reste plus un seul `translateErrorCode` dans `lib/state/` hors des codes client levés localement, donc il n'y a plus rien à vérifier. Et la répétition des ~30 enveloppes HTTP a été **contrôlée plutôt que supposée saine** : une seule méthode ne vérifie pas sa réponse (`logout`), et c'est l'exception documentée — sa route n'existe effectivement pas côté BFF, vérifié.

  **(2) Mutualisation des composants graphiques** (règle 6) — **✅ fait le 31/07/2026, en six lots** (composants + un dossier par commit). Les quatre motifs sont dans `lib/widgets/`, et **zéro `Colors.*` ne subsiste dans `lib/screens/`** : la couleur ne se décide plus que dans `theme/`.

  **Trois des quatre extractions ont fermé un défaut réel, et aucun n'avait été trouvé en relisant.** (1) L'onglet Conducteurs affirmait « Aucun conducteur rattaché à votre entreprise » **quand le BFF était injoignable** — `FleetState.load()` avale l'échec en rendant une liste vide, et `driversUnavailable` existait déjà sans que l'écran le lise ; d'où `AppEmptyState.unavailable`, un constructeur distinct qui force la question *« est-ce vide, ou n'ai-je pas pu savoir ? »* à l'écriture. (2) **Dix refus s'affichaient exactement comme des confirmations** — six côté entreprise, quatre côté commerçant : `SnackBar(content: Text(error ?? 'Course prise'))`, un seul message, aucune couleur. `showAppOutcome` déduit le ton de la donnée, il n'y a plus rien à penser à l'appel. (3) `AppEmptyState` rend `hint` **obligatoire**, et cinq écrans n'en avaient aucun — le compilateur tient maintenant ce qu'un commentaire ne tenait pas.

  **Une fusion de la règle 5 trouvée en chemin** : `_getStatusColor` existait **deux fois, identique caractère pour caractère** (commentaire compris), et **les deux oubliaient l'orthographe `cancelled`** — une course annulée sur deux tombait dans le gris. Même forme que `isClaimable`/`isClaimableAdhoc` en juillet : deux copies d'accord entre elles ne prouvent rien. La table du **commerçant** reste séparée, et le critère le dit — `created` est son brouillon (neutre) là où c'est une course qui attend pour le transporteur (avertissement).

  **`AppSemanticColors` était un préalable, pas un extra** : `ColorScheme` a un rôle `error` mais **aucun rôle succès ni avertissement**. Les huit `Colors.green` et douze `Colors.orange` n'étaient pas de la négligence — il n'existait aucun endroit où les mettre. Extension de thème et non constantes, l'application ayant deux thèmes : un vert figé serait illisible sur fond sombre, soit le défaut de la règle 6 sous un nom plus présentable.

  ⚠️ **La carte de section, elle, ne corrige rien** — et le dire importe : elle nomme seulement les deux densités que le code employait sans les distinguer (14 `lg`, 4 `md`, ces dernières toutes dans la caisse). Rôles Material limités à Flutter 3.20, la borne déclarée dans `pubspec.yaml` : ni `surfaceContainerHighest` (3.22) ni `surfaceVariant` (déprécié, donc un `info` que `flutter analyze` remonte). ⚠️ **Correction du 01/08/2026** : cette borne était fausse (réelle : `>=3.24.0`, imposée par la contrainte Dart du même fichier), donc `surfaceContainerHighest` était **disponible** et la limitation invoquée ici n'existait pas. Le refus de `surfaceVariant` tient, lui : il est déprécié, ce qui ne dépend d'aucune borne.

  **(3) Centraliser les valeurs en dur des écrans** (règle 7) — **✅ fait le 31/07/2026, en deux lots.** Détail et vérificateurs en § Règles §7 ; l'essentiel ci-dessous.

  **Lot 1, les valeurs métier** (celles qui peuvent mentir). Quatre miroirs de règles serveur dans `ServerRules`, dont **une divergence réelle trouvée en instruisant le chantier** : l'écran de caisse laissait passer deux caractères là où le serveur en exige trois, donc un refus incompréhensible sur une saisie que l'application venait d'accepter. Une **troisième** valeur dormait dans `lib/validation/validators.dart` — fichier mort, jamais importé, mais parfaitement utilisable, avec un mot de passe à six caractères contre huit côté serveur ; supprimé. Et `maxPhotoBase64Length`, le miroir le plus cher (cinq mégaoctets envoyés avant un 400), qui vivait sous un commentaire « doit rester alignée sur… ».

  **Lot 2, les valeurs d'apparence** : 320 sites vers `AppSpacing`/`AppRadius`, `app_theme.dart` compris. **Vérifié comme un renommage pur** — en resubstituant chaque jeton par sa valeur et en retirant la ligne d'import, chaque fichier redevient sa version précédente au caractère près. C'est la seule preuve qui distingue un renommage d'une modification, et sans elle un lot de cette taille est impossible à relire.

  ⚠️ **Ce qui reste, et qui est un choix** : une vingtaine de littéraux hors barème, laissés parce que les glisser vers le jeton voisin déplacerait des pixels — décision de design, à prendre à l'écran. `check_spacing.dart` les recense, et **imprime leur compte** pour qu'il ne soit plus recopié — le chiffre noté à la main a divergé de la mesure, et sa correction, transcrite depuis une sortie tronquée, était fausse elle aussi. Deux fois la même erreur par le même geste.

  **Pourquoi cet ordre** : les jetons d'apparence sont un remplacement mécanique et vérifiable par l'analyseur ; les composants s'écrivent naturellement avec ces jetons une fois qu'ils existent ; et la revue des invariants de fonctions demande un jugement au cas par cas, donc du temps et de l'attention, qu'il vaut mieux dépenser en dernier. ⚠️ **Aucun des trois n'est vérifiable dans ce bac à sable** (pas de toolchain Flutter) : chacun demande un `flutter analyze` et un passage à l'écran côté utilisateur, par petits lots.

- [ ] **Publier les deux signalements amont** : `docs/signalements_amont.md` — rédigés en anglais, prêts à coller. (1) `fleetbase/fleetops`, `assignDriver()` qui écrase `meta` faute de recharger une ressource d'index — correctif de trois lignes, déjà présent quatre fois ailleurs dans leur dépôt. (2) `Graphify-Labs/graphify`, l'import relatif Dart non résolu qui crée un nœud fantôme au `source_file` vide et fabrique des chemins **plausibles et faux** — avec les mesures (2 % de nœuds fantômes, 3,83 arêtes/nœud en TS contre 1,61 en Dart) et le cas de reproduction.

- [ ] ⚠️ **« Echango est toujours le facilitateur » est une DÉCISION, pas du code (constaté le 01/08/2026)** — et c'est la plus grosse pièce non écrite du projet, celle qui a le plus l'air faite.

  `docs/specs_facilitateur.md` §2.2 et §2.3 sont titrées « ✅ **Décisions prises** le 31/07/2026 ». Elles se lisent comme un état livré. **Le code dit autre chose**, et la vérification tient en deux lignes :

  ```
  resolveFacilitator(order):  if (!order.facilitator_uuid) return null;
  ```

  Les **seuls** écrivains de `facilitator_uuid` sont la prise d'une course par une entreprise (`fleetbase-api.client.ts:1055`) et la remise au pool qui l'efface (`:934`). **Rien ne pose Echango comme facilitateur d'une course du pool.**

  **Deux modèles coexistent donc dans le code, un seul dans la doc** :

  | | chaîne | statut |
  |---|---|---|
  | course confiée à une **entreprise** | 3 maillons, conducteur → entreprise → commerçant | conforme à la doc, **testé** |
  | course du **pool** (cas majoritaire) | **2 maillons**, conducteur → commerçant | modèle d'avant le 31/07 |

  **Ce que cela change concrètement** : sur une course du pool, le conducteur doit 1300 **au commerçant directement**, pas à Echango ; la commission reste **non recouvrable** (aucun flux conducteur → Echango sur lequel compenser) ; et c'est le **commerçant** qui porte le risque, pas nous.

  **Trois autres pièces de la même décision, vérifiées absentes** : les **favoris polymorphes** (`DriverFavourite` seul, clé sur `fleetbaseDriverUuid` — une entreprise ne peut pas être mise en favori) ; le **persona opérateur** (`PartyType = 'driver' | 'fleet' | 'merchant'`, défaut D21) ; et `isPlatform`, qui **existe et fonctionne** mais reste **dormant** — il ne décide de la retenue que si un `FleetAccount` marqué plateforme est facilitateur, ce que rien ne fait automatiquement.

  ⚠️ **La leçon de méthode, et c'est elle qui compte.** J'ai produit un résumé métier depuis les docs alors que **mes propres tests du jour montraient le contraire** — `test-parcours-argent.sh` écrit une dette `driver → merchant` avec `facilitatorId: null`, sous mes yeux. Un titre « ✅ Décision prise » se lit comme « fait » ; il faudrait qu'il se lise comme « à faire ». **Une décision consignée sans son état d'implémentation est une donnée d'appui fausse en puissance** — même famille que la borne du `pubspec` et que le commentaire de `dates.dart`, corrigés le matin même. À l'écriture d'une spec : dire ce qui est décidé **et** ce qui est branché, séparément.

- [ ] **Flux d'argent à quatre acteurs — décisions produit à prendre avant tout code** : `docs/specs_flux_argent_quatre_acteurs.md` (30/07/2026). ⚠️ **Partiellement remplacé par `docs/specs_facilitateur.md`** (ci-dessus), qui tranche ses questions ouvertes et corrige son §3.4 : la base de commission est **déjà** ce que le commerçant paie (`recordEarning` reçoit `meta.price`) — le défaut porte sur le destinataire, pas sur la valeur. L'entreprise de transport qui gère sa propre flotte est le **seul acteur sans place dans le registre de caisse**, bâti sur un couple `driverId`/`merchantId`. Quatre défauts en découlent, dont deux graves : le **plafond de dette borne la mauvaise exposition** (une entreprise de dix conducteurs accumule dix fois le plafond chez le même commerçant sans qu'aucune garde ne se déclenche), et la **commission est assise sur la rémunération du conducteur**, un montant interne à l'entreprise que nous n'aurons jamais — la base doit être ce que le commerçant paie. Antérieur à tout ça : **le commerçant ne pose jamais `facilitator`**, donc une entreprise ne peut recevoir que ce qu'un opérateur lui rattache à la main en console. Recommandation centrale : **la contrepartie financière est l'entreprise quand il y en a une, le transporteur sinon** — ce qui demande de généraliser les trois tables du registre à un couple de parties typées, sans toucher à une seule règle métier, et rend le cas indépendant et le cas entreprise identiques au lieu d'ajouter une branche partout où il est question d'argent. **Trois décisions prises le 30/07/2026, qui ouvrent le développement** : (1) le commerçant choisit **une entreprise ou un transporteur du pool**, au même endroit — donc les **favoris doivent devenir polymorphes** eux aussi, et confier une course à une société ne doit PAS nommer son conducteur à sa place ; (2) une entreprise peut **prendre une course diffusée** et l'attribuer en interne — il faut lui donner l'équivalent d'`acceptOrder()`, et gérer les deux populations qui réclament la même course ; (3) **l'entreprise répond de ses conducteurs**, ce qui rend le modèle tenable : la perte d'un conducteur ne change rien au solde que voit le commerçant, elle bascule sur la chaîne interne où l'entreprise a des moyens que nous n'avons pas. Le client final reste hors plateforme. Restent ouvertes trois questions qui ne bloquent rien, sauf une : **un conducteur peut-il travailler pour deux entreprises** — elle décide si un simple couple de parties suffit.
- [ ] **Paiement à la livraison — reste à trancher** : les points du §9 de `docs/specs_paiement_livraison.md` que l'implémentation n'a délibérément pas préemptés — qui supporte la perte, le montant réel du plafond, le retrait en agence, et la **vérification juridique** sur la détention de fonds pour compte de tiers (la Voie B est conçue pour l'éviter, cela reste à confirmer). : `docs/specs_paiement_livraison.md`. Le sujet n'est pas un champ « montant » mais une **chaîne de garde d'espèces** qui court à contresens du colis, par quelqu'un qui n'est ni l'expéditeur ni le destinataire. Trois modèles observés : transporteur intégré à agences (Yalidine, ZR, Noest en Algérie ; Bosta, Mylerz en Égypte — reversement en 3 à 7 jours, rapprochement manuel à 3-5 % d'erreurs et 15 % de trésorerie en suspens), plateforme à solde coursier (DoorDash — le coursier garde le liquide, déduit de ses gains, plus de courses encaissées si le solde passe négatif), et agrégateur qui ne touche jamais l'argent. **Notre position n'est aucune des trois** : ni agences ni dépôts, transporteurs indépendants, et pas encore de versement sur lequel compenser — mais nous avons les favoris, une relation répétée qui change le profil de risque et fournit l'occasion naturelle de la remise. **Recommandation : Voie B** — le transporteur conserve les espèces, l'application tient le registre de sa dette par commerçant, la remise se fait au prochain enlèvement et se confirme des deux côtés ; Echango ne touche jamais l'argent. Garde-fous logiciels : plafond de dette, courses encaissées réservées aux favoris au démarrage, trace horodatée. **L'apport de l'app** est entièrement informationnel : le bon montant au bon moment, « livré » et « encaissé X » en une seule déclaration prouvée, l'écart constaté à la porte et non cinq jours plus tard au dépôt, la réponse à « combien me doit-on et depuis quand », et le plafond de dette — seul instrument de contrôle disponible sans dépôt physique. **Rien n'est implémenté volontairement** : une mise en œuvre partielle serait pire que l'absence, un commerçant confierait de l'argent réel à une capacité qui n'existe pas. Six points à trancher (§9), dont qui supporte la perte et une **vérification juridique** sur la détention de fonds pour compte de tiers.
- [ ] **P1 restant — relu et corrigé le 31/07/2026** (`docs/rapports_revue_2026-07-28/00_synthese.md`). ⚠️ **Trois des quatre points étaient périmés, et deux étaient devenus faux** — les laisser écrits aurait fait « corriger » ce qui l'est déjà, ce qui est la même faute que décrire une protection qu'on n'a pas. Vérifié point par point dans le code, pas de mémoire :

  - ~~**prix et délai affichés**~~ — **faux depuis longtemps** : `price`, `currency`, `price_source` et `cod_amount` sont dans `META_FIELDS` de `projectOrderForDriver`, chacun sous un commentaire disant explicitement que le transporteur doit les avoir pour décider ; `scheduled_at` est dans `ORDER_FIELDS`.
  - ~~**coordonnées par défaut d'Alger**~~ — **faux depuis le lot carte du 30/07** : `CreateOrderDto` **exige** les quatre coordonnées, le formulaire refuse de soumettre sans les deux points, et une adresse du carnet sans position rend `null` plutôt que `(0,0)`. `_algiers` ne subsiste que comme **position initiale de la caméra** du sélecteur, avec le libellé de l'adresse résolu et affiché avant toute confirmation.
  - ~~**rayon de diffusion**~~ — **arbitré le 02/08/2026, voir la ligne « Le transporteur choisit ce qu'il voit » ci-dessus.** Le constat technique reste juste : `adhoc_distance` (15 km, `ADHOC_RADIUS_METRES`) gouverne les **pings**, tandis que `listOrders` sert les courses libres à l'échelle de l'organisation. Ce que j'appelais un désaccord n'en était pas un : **c'est le transporteur qui choisit sa course**, et la liste n'a pas à trancher à sa place. La suite n'est donc pas d'aligner la liste sur le rayon, mais de donner au transporteur **sa** wilaya et **son** rayon.
  - **mode de dispatch** — toujours ouvert, mais **partiellement tranché** par le mode brouillon/publier du 30/07 : c'est le commerçant qui décide du moment. Reste la question de l'opérateur outillé.

- [ ] Revenir documenter les réponses **avant** de concevoir le connecteur Odoo → Fleetbase (qui vivra dans `echangoorder/backend/addons/echango_order/`, pas dans ce repo).
- [ ] Rouvrir la question de la licence AGPL avec un juriste avant la Phase 3 B2B.

## Repo lié

- [`echangoorder`](https://github.com/ecolealgerienne-ui/echangoorder) — Echango Order (Produit 1). `docs/specs_macro_drive_transport.md` pour la vision macro complète des deux produits.
