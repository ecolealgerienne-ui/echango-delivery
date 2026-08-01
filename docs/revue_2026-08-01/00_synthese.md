# Revue croisée du 1er août 2026 — synthèse

Cinq agents spécialisés, en parallèle, en **lecture seule** : métier (règles d'argent),
conformité Fleetbase, sécurité, architecture, application Flutter. Chacun briefé sur les
onze règles de `CLAUDE.md` et sur l'état courant, avec une consigne commune : **vérifier
dans le code, ne rien supposer**, et distinguer ce qui est confirmé de ce qui est probable.

**43 défauts retenus** après dédoublonnage. Ce document les classe par gravité ; le plan
d'exécution est en `01_plan.md`.

---

## Ce que la revue dit du projet

Trois constats se dégagent, et ils sont plus instructifs que le décompte.

**(1) Les invariants écrits en commentaire ont divergé — encore.** Deux agents ont trouvé
*indépendamment* le même défaut : `resolveFacilitatorId` existe en deux exemplaires, et
celui du module transporteur porte le commentaire « le repli est ici et **nulle part
ailleurs** […] le reproduire chez les appelants créerait des chemins qui divergent
(règle 5) » — pendant que la copie du module commerçant fait exactement l'inverse. C'est
la forme exacte d'`isClaimable`/`isClaimableAdhoc` de juillet : la phrase énonce
l'invariant, sa raison et le défaut qu'une divergence produirait, et **un commentaire ne
peut pas échouer**. Trois autres duplications de la même famille figurent au relevé
(plafond de dette écrit trois fois avec deux statuts HTTP, statuts terminaux réénumérés
dans le fichier qui importe la constante, registres de codes d'erreur non comparés).

**(2) Une donnée d'appui fausse ne dort pas dans un commentaire — elle fait conclure.**
C'est la leçon déjà payée sur la borne du `pubspec` le matin même, et elle se rejoue à
l'identique. `getAllOrders` porte un commentaire affirmant que `with[]=customFieldValues`
charge les valeurs « en une fois » ; **mesuré, la ressource d'index n'en sert aucune, et
le paramètre n'y change rien**. Ce commentaire a servi d'argument, textuellement, pour
écrire l'hydratation des listes du profil entreprise — qui ne recompose donc rien. Trois
autres affirmations du dépôt sont fausses de la même façon : le schéma dit que les jetons
push des commerçants « sont bien collectés » (la table est structurellement vide), un test
d'environnement garde une variable que personne ne lit, et un commentaire affirme que la
révocation de session protège d'un jeton volé (aucun déclencheur n'existe).

**(3) Le fil rouge du projet n'a pas changé : le serveur sait, l'application ignore.**
La révocation de session est intégralement câblée et n'a aucun déclencheur ; ni un
transporteur ni une entreprise ne peuvent créer leur compte depuis l'application ; les
jetons push commerçant ne sont jamais envoyés ; `membershipsUnavailable` est calculé et
n'a aucun lecteur. À l'inverse, quatre écrans affirment une absence qu'ils n'ont pas
vérifiée (règle 10) — dont un dans le fichier même où les deux autres listes ont été
corrigées.

---

## Critique — corrige avant tout le reste

### C1. Les deux listes du profil entreprise s'affichent sans aucun montant
`backend/bff/src/flotte/flotte.service.ts:1295` (helper), `:73` et `:118` (appelants)

`withEffectiveMeta()` recompose `meta` depuis `custom_field_values`. Sur une commande
issue d'une **liste**, il n'y a rien à recomposer : la ressource d'index de Fleetbase sert
`meta = {"_index_resource": true}` et **aucune** valeur de champ personnalisé, y compris
avec `with[]=customFieldValues.customField`.

> **Mesuré le 01/08/2026** (`GET /int/v1/orders?limit=2&with[]=customFieldValues.customField`) :
> `meta = {_index_resource: true}`, `custom_field_values` absent, `meta.price = null`.
> La même commande en lecture unitaire : `meta` réel, 8 valeurs de champs personnalisés.

Conséquence : une entreprise décide de prendre une course **sans voir le prix, ni le
montant à encaisser, ni le type de véhicule, ni les consignes** — c'est-à-dire le défaut
D6 (« sur quels critères je dois accepter cette course ? ») que le commentaire du helper
déclare corrigé, en s'appuyant sur l'affirmation démentie ci-dessus. Rien ne le signale :
`pick()` omet les clés `undefined`, la ligne s'affiche, seuls les chiffres manquent.

Les chemins **unitaires** du module (`getOrderWithRelations`) sont corrects, ce qui
explique que `test-parcours-argent-flotte.sh` passe : il n'exerce jamais les deux listes.
Les modules commerçant et transporteur échappent au défaut parce qu'ils hydratent depuis
`Order.specMeta`, le filet local — que le profil entreprise n'a pas.

### C2. Deux résolutions du facilitateur qui divergent sur une course du pool
`backend/bff/src/commercant/commercant.service.ts:391` vs `transporteur.service.ts:1311`

Le module transporteur applique le repli plateforme (`if (!vendorUuid) return
this.platformFacilitator()`), le module commerçant rend `null`. Les deux alimentent le
même registre, et `legScope()` construit une **jambe différente** selon que
`facilitatorId` est nul.

Scénario : deux livraisons du pool identiques, même commerçant, même conducteur. L'une
clôturée par l'application → la dette est portée par **Echango**. L'autre clôturée en
console puis régularisée par le commerçant → la dette est portée par le **conducteur**. Le
commerçant voit deux contreparties pour deux courses identiques ; une remise à Echango
n'éteint pas la seconde, une remise directe n'éteint pas la première. Aucune erreur, les
deux nombres sont plausibles.

### C3. « Aucune course libre » affirmé quand le chargement a échoué
`echango_delivery/lib/state/fleet_state.dart:123`

`getFleetOpportunities()` est enveloppée d'un `.catchError((_) => {})` qui ne pose **aucun**
drapeau — contrairement à `_driversUnavailable` dix lignes plus bas. Une entreprise dont
le BFF renvoie 500 sur cette seule route lit « Aucune course libre pour le moment », sans
bandeau ni bouton de reprise, sur **l'onglet où elle vient chercher du travail**. Elle
conclut que le réseau est vide.

Quatrième occurrence de la règle 10 sous cette forme, **dans le fichier même** où les deux
autres listes ont été traitées.

---

## Majeur — argent

### M1. Le plafond de dette borne une position comptable, pas les espèces détenues
`backend/bff/src/cash/cash.service.ts:223` (`debtBetween`), `:456` (`retained`)

`debtBetween` soustrait `grossAmount` (la rémunération **due**) alors que le conducteur
n'a physiquement retenu que `retainedFromCash` (plafonné au perçu). Tant que perçu ≥
rémunération les deux coïncident ; dès qu'une course est prépayée ou payée en partie, la
dette **sous-estime** les espèces détenues de `gross − retained`.

Dix courses prépayées à 650 donnent une dette de −6500 pour 0 DZD en poche ; le conducteur
peut alors accepter 20 000 encaissés et détenir ~26 500 pour un plafond de 20 000. Le
commentaire de `totalHeldBy` pose pourtant explicitement la règle inverse (« ce qu'on
borne est ce qui est **détenu**, pas une position nette »). **Le seul garde-fou du
paiement à la livraison mesure la mauvaise grandeur.**

### M2. Un commerçant peut imputer un encaissement à n'importe quel conducteur du réseau
`backend/bff/src/commercant/commercant.service.ts:2290`

`const uuid = assignedUuid ?? suppliedUuid;` — la branche `?? suppliedUuid` n'est gardée
par rien. Sur une de ses propres commandes `completed` clôturée en console (donc sans
`driver_assigned_uuid` — cas réel documenté du 30/07), un commerçant poste
`{"collectedAmount": 40000, "fleetbaseDriverUuid": "<un uuid quelconque>"}`, obtenu par
`GET /commercant/transporteurs/recherche`.

La ligne apparaît chez la victime comme une réclamation légitime ; s'il confirme, la dette
devient réelle. Sans confirmation, `fleetbaseOrderUuid` est `@unique` : l'entrée de
registre de cette course est **empoisonnée définitivement**, les deux chemins de
redéclaration refusant.

Le commentaire deux lignes au-dessus dit : « accepter une autre désignation permettrait
d'imputer un encaissement à un tiers ». C'est ce que fait la ligne.

### M3. Sur une course du pool, le plafond par couple vaut toujours 0 à la création
`backend/bff/src/commercant/commercant.service.ts:503`, `cash.service.ts:320` (`legScope`)

`pickAvailableFavourite` interroge `debtBetween(driver, merchant)`, dont `legScope` exige
`facilitatorId: null`. Depuis le repli plateforme, les dettes du pool portent
`facilitatorId = Echango` : la jambe interrogée est **structurellement vide**. Un favori
devant 19 000 se voit confier une course de 5 000, puis `startOrder` la lui refuse — la
course reste assignée à quelqu'un qui ne peut pas la démarrer.

### M4. La reprise idempotente ne distingue pas une déclaration du commerçant
`backend/bff/src/cash/cash.service.ts:644-674`

La branche de reprise ne teste que `driverId`. Une ligne `declaredBy: 'merchant'` la
traverse à l'identique : le conducteur reçoit un succès, `recordEarning` s'exécute, mais
`collectionsBetween` exclut la ligne non confirmée. Dette = 0 − 650 = **−650** : le
commerçant lit « vous devez 650 à ce transporteur » alors que celui-ci détient 1950 de son
argent.

### M5. Une régularisation contestée sort du registre **et** de la liste des trous
`backend/bff/src/cash/cash.service.ts:1564`, `commercant.service.ts:2111`

Une fois `disputedAt` posé : la ligne ne compte dans aucune dette, elle **disparaît** de
`unrecorded` (qui ne filtre ni `confirmedAt` ni `disputedAt`), toute redéclaration est
refusée, et la confirmation aussi. La somme sort du système de façon permanente. Le
message dit « contactez Echango » — aucune route, aucun persona ne peut débloquer la ligne.

### M6. Le détail des encaissements ne se recompose pas en solde
`backend/bff/src/cash/cash.service.ts:1351`, `:1391`

`debtBetween` soustrait `grossAmount`, `net_amount` soustrait `retainedFromCash`, et
`listCollections` n'itère que sur `cashCollection` — les courses prépayées n'y figurent
pas alors qu'elles pèsent sur la dette. Les trois ne décrivent pas le même ensemble. Or la
docstring justifie l'existence de la fonction par « c'est exactement ce qu'il doit
contrôler **avant de confirmer une remise** ».

### M7. La régularisation est conducteur-centrée et aveugle à l'entreprise
`backend/bff/src/commercant/commercant.service.ts:2124`, `:2328` ; route flotte absente

Sur une course facilitée, la contrepartie du commerçant est le `fleet`, mais l'écran ne
sert que `driver_name`/`driver_phone` : il l'envoie appeler le conducteur pendant que sa
caisse affiche une dette due par la société. Pire, si le conducteur n'a pas de compte
Echango, `cash.driver_no_account` **interdit toute régularisation** — alors que le
débiteur réel, l'entreprise, en a un. Et côté flotte, `confirmer`/`contester` n'existent
pas : l'entreprise voit une créance qui la nomme et n'a aucune action dessus.

### M8. Le plafond de dette est écrit trois fois, avec deux statuts HTTP
`transporteur.service.ts:1399` vs `flotte.service.ts:264` et `:1174`

Même squelette ligne pour ligne. `transporteur` lève un **400** avec dette + montant +
plafond ; `flotte` lève un **409** **sans aucun chiffre**, alors que le commentaire du
premier justifie explicitement l'inverse (« "refusé" sans chiffre laisse le transporteur
sans moyen de savoir combien remettre »). Et `flotte:268` lit `order?.meta?.cod_amount`
**brut** : un appelant qui oublie d'hydrater désarme la garde en silence — ce qui est
exactement le défaut C1.

### M9. La commission d'une entreprise est calculée, stockée, et lue par personne
`backend/bff/src/cash/cash.service.ts:367`, `:1000`

`DriverEarning{earnerType:'fleet', commissionAmount}` est écrit à chaque course.
`platformCommissionOwed` filtre sur `earnerType:'driver'`, `balancesFor` ne sert
`platform_commission` qu'aux conducteurs, `fleetBalances` ne l'expose pas, `debtBetween`
l'exclut. Règle 9.

### M10. Supprimer un compte facilitateur réattribue ses dettes au conducteur
`backend/bff/prisma/schema.prisma:742`, `:928`

`onDelete: SetNull` sur `facilitatorId`, alors que c'est la colonne qui **décide de
l'identité du débiteur** dans `legScope`. Les dettes portées par Echango deviendraient des
dettes personnelles du conducteur, sans trace — l'inverse exact de ce que §7.5 promet.
`driverId` et `merchantId` sont, eux, protégés par `Restrict`. Latent (aucune route ne
supprime un `FleetAccount`) mais armé.

### M11. Le refus de plafond annonce « pour ce commerçant » sur un total qui ne l'est pas
`backend/bff/src/transporteur/transporteur.service.ts:1436`

Depuis le repli plateforme, la jambe « couple » est driver ↔ Echango, agrégée sur **tous**
les commerçants. Le message envoie le conducteur voir un commerçant à qui il ne doit rien.

---

## Majeur — Fleetbase

### F1. `getOwnedPlaces()` n'envoie ni `page` ni `limit`
`backend/bff/src/fleetbase/fleetbase-api.client.ts:562`

Fleetbase pagine à **30** par défaut (mesuré). Au 31ᵉ lieu d'un commerçant : le carnet
affiche 30 adresses sans le dire ; `assertOwnsPlace()` refuse `PUT`/`DELETE` sur une
adresse **qui existe et lui appartient**, avec un message qui l'envoie chercher une faute
de saisie ; et `clearOtherDefaults()` laisse deux « adresse principale » coexister.
Fail-closed, donc pas de fuite — mais la panne est invisible et arrive par le simple usage.

### F2. `findUserDeviceByToken()` lit 30 lignes pour y chercher un jeton
`backend/bff/src/fleetbase/fleetbase-api.client.ts:1495`

Repli appelé lors d'une rotation de jeton Firebase. Au-delà de 30 `UserDevice` dans
l'organisation, le jeton cherché est hors page 1, la fonction rend `null` avec un simple
`warn`. Le `UserDevice` périmé reste, et `routeNotificationForFcm()` renvoyant **tous** les
devices, les `OrderPing` partent indéfiniment vers un jeton mort. Strictement silencieux.

### F3. Quatre champs de la liste d'autorisation n'existent pas dans la ressource d'index
`backend/bff/src/common/projections/order.projection.ts:221-222`

Mesuré : `pod_required`, `pod_method`, `notes` et `distance` sont **absents** de
`GET /orders` et présents en lecture unitaire. Toutes les listes les perdent en silence
(`pick()` omet les `undefined`) : une commande exigeant une preuve de livraison est
indiscernable d'une commande sans preuve tant qu'on ne l'ouvre pas.
`estimated_duration` n'existe dans aucune des deux — champ mort.

### F4. `without_driver` est un filtre à présence, pas un booléen
`backend/bff/src/fleetbase/fleetbase-api.client.ts:36`

Mesuré : `?without_driver=true` → 53, `?without_driver=false` → **178** (la totalité). Le
type `boolean` invite à passer une variable ; un `false` n'exclut pas, il **élargit**.
C'est le mode de panne que ces interfaces fermées existent pour empêcher.

### F5. `getOrder()` sans `with[]` rend `driver_assigned: null` même sur une course assignée
`backend/bff/src/flotte/flotte.service.ts:206`

Contre-intuitif : la **liste** hydrate la relation, la lecture **unitaire** nue ne
l'hydrate pas. Sans effet aujourd'hui (le seul appelant lit une course sans conducteur),
armé pour le prochain.

### F6. `listCustomFields()` demande `limit: 200`, plafonné à 100 sans le dire
`backend/bff/src/fleetbase/fleetbase-api.client.ts:579`

Treize champs aujourd'hui, marge confortable — mais la valeur `200` donne l'impression que
la borne est traitée alors qu'elle est ignorée.

### F7. `getAllPositions()` n'a plus d'appelant et lit une page de 30
`backend/bff/src/fleetbase/fleetbase-api.client.ts:1525`

Le prochain qui la reprendra pour un historique croira lire tout et lira les 30 dernières
positions de la compagnie, tous conducteurs confondus. Soit paginer, soit supprimer.

### F8. Le repli de `getVendorByUuid()` n'est plus exercé
`backend/bff/src/fleetbase/fleetbase-api.client.ts:239-280`

Mesuré sur 0.7.52 : `GET /vendors/{uuid}` honore bien son paramètre de chemin (test durci
« dernier et non premier »). Les 60 lignes de `findVendorAcrossPages()` sont du code mort
dont on croit qu'il protège quelque chose, et la note de `getDriverByPublicId()` justifie
un détour sur une prémisse qui n'a plus cours.

---

## Majeur — sécurité

### S1. Aucun moyen de couper une session
`common/guards/jwt-auth.guard.ts:93`, `auth.service.ts:262`

`assertVendorApproved()` n'est appelée qu'à la **connexion**. Le garde par requête ne teste
que `account.active`, qui n'est **écrit nulle part** dans tout `src/`. Suspendre un
commerçant en console n'a donc aucun effet avant 24 h ; un conducteur ne peut être coupé
par aucune interface. `POST /auth/revoquer-sessions` exige le jeton de la victime. Le seul
levier réel est un `UPDATE` SQL à la main.

### S2. Derrière un proxy, les plafonds de débit deviennent globaux
`backend/bff/src/main.ts:8` — `app.set('trust proxy')` absent

`ThrottlerGuard` clef sur `req.ip`, qu'Express ne renseigne depuis `X-Forwarded-For` que si
`trust proxy` est activé. Derrière nginx, six requêtes coupent l'authentification de
**toute la plateforme**. Piège jumeau à ne pas rater : `trust proxy: true` sans liste de
confiance rend l'en-tête falsifiable et supprime purement le plafond anti-force-brute.

### S3. `limit` et `page` ne sont bornés ni en haut ni en bas
`commercant/dto/create-order.dto.ts:279`, `flotte/dto/order.dto.ts:16`

`?limit=1000000` → `take: 1000000` puis projection de chaque ligne. `?limit=-1` fait
basculer Prisma en « les N derniers ». Amplification depuis un compte valide.

### S4. La garde « pas de clôture sans encaissement » est accrochée à un littéral
`backend/bff/src/transporteur/transporteur.service.ts:1450`

`activity?.code === 'completed'`, là où la source de vérité est le `flow` de
l'`OrderConfig` — modifiable depuis la console, et choisie par
`configs.find(key === 'transport') || configs[0]`. Le jour où l'activité terminale porte un
autre code, une livraison encaissée se clôt sans `settleCashIfDue()`. Exactement le mode
d'échec du §16 (« la garde était décorative »).

---

## Majeur — architecture et couture app ↔ serveur

### A1. Ni un transporteur ni une entreprise ne peuvent créer leur compte
`bff_api_client.dart:271`, `auth.controller.ts:56`, `navigation/app_router.dart:61`

`registerDriverWithInvitation` est écrit côté client et **n'a aucun appelant** ;
`POST /auth/flotte/register` n'a aucun appelant Dart ; le routeur ne déclare qu'un
`/register`, réservé au commerçant. Au pilote, un opérateur remet un jeton d'invitation à
un transporteur qui n'a aucun écran pour s'en servir, et une entreprise ne peut pas
s'inscrire du tout — avec cinq lots d'écrans construits derrière.

### A2. La révocation de session n'a aucun déclencheur
`auth.controller.ts:99`, `auth.service.ts:1207`, `jwt-auth.guard.ts:97`

`revokeAllSessions()` est le seul écrivain de `tokenVersion`, et sa route n'est appelée ni
par `lib/` ni par `scripts/`. Il n'existe par ailleurs aucune route de changement de mot
de passe. Le commentaire du schéma annonce pourtant le remède au jeton volé. Téléphone
perdu : 24 h, et rien dans le produit ne permet de couper.

### A3. Les jetons push des commerçants ne sont jamais collectés
`auth.controller.ts:71`, `schema.prisma` (`MerchantNotification`)

`POST /auth/device-token` (variante commerçant) n'a **aucun appelant** — l'app n'appelle
que la variante transporteur. La table `DeviceToken` est structurellement vide, alors que
le schéma **et** `CLAUDE.md` affirment « les jetons sont bien collectés : il ne manque que
l'expéditeur ». Le jour où le credential Firebase arrive, on branchera un expéditeur sur
une table vide et on cherchera le défaut du côté de Firebase.

### A4. `ALLOW_DEV_ERRORS` garde une variable que personne ne lit
`backend/bff/src/config/env.validation.ts:61`

La vraie vanne est `NODE_ENV === 'development'`, recopiée six fois. Le test ne se déclenche
que sous `NODE_ENV=production`, c'est-à-dire quand la fuite est déjà impossible : inerte
dans les deux sens. Un VPS démarré avec `NODE_ENV=development` renvoie au client les
identifiants internes et la structure de l'organisation Fleetbase, sans un mot.

### A5. Le réconciliateur réénumère les statuts terminaux qu'il importe
`backend/bff/src/notifications/order-reconciler.service.ts:200-206`

Le fichier importe `TERMINAL_ORDER_STATUSES` et s'en sert deux fois, puis écrit
`status === 'canceled' || status === 'cancelled'` à la main dix lignes plus bas. Une
quatrième graphie ajoutée à la constante — son motif d'existence même — filtrerait
correctement en ligne 109 et **cesserait de notifier** en ligne 203.

### A6. Rien ne relie le registre de codes du client à celui du serveur
`echango_delivery/tool/check_error_codes.dart`, `common/errors/error-codes.ts:20-26`

Le vérificateur ne compare que les trois tables Dart **entre elles**. Les 115 codes serveur
sont tous présents aujourd'hui — c'est donc une divergence latente, exactement la situation
d'`isClaimable`. Le prochain code ajouté au serveur passera la compilation, passera le
vérificateur, et l'utilisateur recevra un message générique dans la situation précise où le
code avait été inventé pour lui dire quoi faire. Le remède est déjà bâti :
`check_server_rules.dart` lit un fichier TypeScript et un fichier Dart et les compare.

### A7. Quatre colonnes mortes ou en écriture seule
`schema.prisma` (`Order.failureReason`, `Order.failureNotes`, `Order.lastSyncedAt`,
`AuditLog.ipAddress`)

`failureReason`/`failureNotes` : **zéro occurrence**, la donnée vit dans `DeliveryFailure`.
`lastSyncedAt` : écrite deux fois par minute et par commande, **lue nulle part**, sous un
commentaire promettant de « distinguer *rien n'a bougé* de *personne ne regarde* » —
question que personne ne pose. `AuditLog.ipAddress` : jamais écrite, sur une piste d'audit
dont le schéma dit qu'elle existe pour qu'une exploitation soit « reconstituable ».

### A8. `JWT_EXPIRATION` a son défaut écrit deux fois
`app.module.ts:39` (signe le jeton) et `auth.service.ts:1241` (annonce `expires_in`)

Les modifier séparément fait mentir l'API sur l'expiration de son propre jeton.

---

## Majeur — application Flutter

### D1. Le journal du commerçant affiche le texte serveur en français
`screens/commercant/notifications_screen.dart:135`, `:146`

`title` et `body` viennent de `order-reconciler.service.ts:183-205`, écrits en français
**dans le code serveur**. Un commerçant arabophone ouvre son unique canal d'évènements (le
push n'est pas branché) et lit une liste entièrement en français sous un titre arabe. Le
`type` est pourtant servi et déjà exploité juste au-dessus pour choisir l'icône : la clé
existe côté données, seule la table manque. Règle 4.

### D2. Le transporteur est le seul à lire le statut Fleetbase brut
`screens/transporteur/dashboard_screen.dart:400`, `order_detail_screen.dart:106`

« Statut : dispatched », « Statut : enroute » — en arabe, une phrase arabe terminée par un
mot anglais. `orderStatusLabel()` existe et sert le commerçant et la caisse ;
`fleetOrderStateKey()` sert l'entreprise, dont le commentaire se félicite explicitement
d'avoir supprimé ce même défaut. La correction s'est arrêtée à un profil sur trois.

### D3. Fragilité, quantité et poids jetés en silence si le contenu n'est pas décrit
`screens/commercant/create_order_screen.dart:386`

Le bloc `items` est gardé par `if (_itemDescription.isNotEmpty)`, et la description est
**facultative**. Un commerçant qui coche « fragile », saisit 3 colis et 12 kg mais ne
décrit pas le contenu envoie une commande **sans aucun item**. La case reste cochée à
l'écran. Le transporteur découvre trois cartons lourds devant la porte — le scénario que le
commentaire des lignes 380-395 dit avoir corrigé.

### D4. Une quantité illisible retombe sur 1 sous un commentaire qui dit l'inverse
`screens/commercant/create_order_screen.dart:399`

`int.tryParse(...) ?? 1` sur un champ sans validateur ni `inputFormatters`. « 3 colis »,
« 2,5 », ou le champ vidé pour retaper → **1** envoyé. Le serveur ne peut rien refuser :
il reçoit une valeur valide. Le commentaire au-dessus dit « aucune borne, délibérément :
l'absence ne ment pas (règle 7) » — mais le code ne laisse pas d'absence, il **fabrique
une valeur**.

### D5. Le seul écran qui interpole l'exception brute dans un message visible
`screens/commercant/favourite_drivers_screen.dart:97`, `:141`

`_t('order.fav.load.failed', {'error': '$e'})` affiche soit le **message serveur
français**, soit le code nu, soit `SocketException: Failed host lookup…`. Tous les autres
sites passent par `messageForError()`.

### D6. « Aucun favori » affirmé alors que la lecture a échoué
`state/merchant_order_state.dart:164` → `favourite_drivers_screen.dart:274`

`catch (_)` muet, sans drapeau. Le commerçant lit « Aucun favori. Vos livraisons sont
proposées à tout le réseau » — une phrase qui **décrit une politique de diffusion**, donc
une affirmation forte et fausse. `addressesUnavailable` et `driversUnavailable` existent
pour ce cas.

### D7. « Aucune notification » affirmé alors que le relevé a échoué
`screens/commercant/notifications_screen.dart:65`

Même mécanisme, sur l'écran qui sert de substitut au push non branché.

### D8. `membershipsUnavailable` est calculé et n'a aucun lecteur
`state/fleet_state.dart:98`, `screens/flotte/memberships_tab.dart:158`

Ses deux jumeaux en ont un. L'erreur n'est visible que par `_errorMessage`, remis à `null`
au premier tirer-pour-rafraîchir : après ce geste, l'entreprise lit « Aucun rattachement »
sans bandeau. Soit l'onglet le lit, soit le champ se supprime — pas à mi-chemin.

### D9. Deux onglets voisins affichent le même montant dans deux formats
`screens/flotte/flotte_home_screen.dart:756` vs `:660`

« Prix : 650 — À encaisser : 1950 » d'un côté, « Prix : 650 DZD · À encaisser : 1950 DZD »
de l'autre. Une entreprise qui prend une course voit la ligne **perdre sa devise** en
changeant d'onglet. Les deux fonctions divergent aussi sur le test de nullité.

---

## Vérifié et **non** retenu

Ce qui suit a été examiné et jugé correct — le dire évite de « corriger » ce qui l'est déjà,
faute déjà commise ce matin sur le compte des couleurs en dur.

- **Aucun IDOR exploitable.** Tous les `@Param` passent par `FleetbaseIdPipe`, toutes les
  lectures croisées portent l'identité de l'appelant (`resolveOwnedOrder`,
  `assertOwnsPlace`, `assertOrderVisible`, `loadRemittanceFor`, `legScope`,
  `fleetMayUseDriver`), les `updateMany`/`deleteMany` portent le propriétaire dans le
  `where`. Aucune SQL brute, aucune interpolation de chemin non encodée.
- **Le masquage d'identité sur une course non réclamée est correct**, y compris le piège de
  l'accesseur `Place.address` (recomposé depuis les seules colonnes structurées).
- **Les filtres Fleetbase sont tous honorés** — `orders?customer|driver|without_driver`,
  `drivers?vendor|query`, `places?owner_uuid`, `custom-field-values?subject_uuid` — chacun
  vérifié **avec son témoin à uuid inventé**. `?vendor_uuid=` et `?owner=` rendent bien la
  collection entière, ce qui confirme que le mode de panne « paramètre inconnu abandonné en
  silence » est intact.
- **Le registre de caisse est sain sur ses fondations** : orientation canonique des couples,
  aucun solde stocké, `orient()` rend le même signe aux deux bouts, `declareRemittance`
  déduit le sens de la dette et non du déclarant, `loadRemittanceFor` ferme D13.
- **Les compensations** de `createOrderCache`, `publishOrder` et `claimOrder`, et l'ordre
  registre-avant-clôture, sont corrects.
- **L'auto-déclaration `isPlatform` est impossible** (absente du DTO, `whitelist: true` +
  `forbidNonWhitelisted`), la confirmation d'une remise par son propre déclarant aussi, et
  le rattachement `active` sans consentement est fermé dans les deux sens depuis le 31/07.

## Hors périmètre — arbitrages produit, pas des défauts

- `payload.pickup` sort en entier (enseigne, téléphone du commerçant) sur une course non
  réclamée : question laissée explicitement ouverte, `specs_facilitateur.md` §D7.
- `meta.dropoff_notes` et `instructions` restent du texte libre que le masquage structuré
  ne peut pas couvrir — la projection le dit elle-même.
