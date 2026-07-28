# Revue de sécurité — Echango Delivery (BFF + app Flutter), 28/07/2026

*Agent : general-purpose (Opus). Périmètre : `backend/bff/src/**`, `echango_delivery/lib/**`, `scripts/*.sh`, config Docker/env. Revue statique, lecture seule.*

**Modèle de menace retenu** : le BFF détient un token Sanctum de service avec accès complet à l'organisation Fleetbase. Tout le cloisonnement entre utilisateurs est applicatif (§2.8/§6.4 du journal). Une faille dans le BFF ne dégrade donc pas l'isolation : elle la supprime.

## CRITIQUE

### C1 — Secret JWT par défaut en dur, dans trois fichiers, sans validation au démarrage
`backend/bff/src/app.module.ts:24` (`'dev-secret-key-change-in-prod'`), `backend/bff/src/auth/auth.module.ts:13` (`'dev-secret'`), `backend/bff/src/auth/strategies/jwt.strategy.ts:11` (`'dev-secret'`), `backend/bff/docker-compose.yml:42` (`${JWT_SECRET:-dev-secret-key}`).

**Attaque** : si `JWT_SECRET` est absent de l'environnement du VPS (oubli, fichier `.env` non copié, orchestrateur qui n'injecte pas la variable), le service démarre **normalement** avec un secret public présent dans un dépôt Git. N'importe qui forge alors un jeton `{sub:"<id>", type:"merchant"|"transporteur"|"fleet"}` — le script `scripts/test-transporteur-module.sh:170-177` fournit littéralement le code de forgeage en 4 lignes d'`openssl`. Tous les contrôles anti-IDOR sont contournés d'un coup, puisqu'ils reposent tous sur `req.user.id` issu du jeton.

Aggravant : les secrets de signature (`auth.module.ts`, module local) et de vérification (`app.module.ts`, module global utilisé par `JwtAuthGuard`) sont **différents** quand la variable est absente — l'échec est donc silencieux et déroutant en dev, mais parfaitement exploitable dès que la variable est posée d'un seul côté.

**Correction** : supprimer les trois valeurs de repli ; valider `JWT_SECRET` au démarrage (`ConfigModule.forRoot({ validationSchema })` ou un `throw` explicite dans le `useFactory`) avec une longueur minimale de 32 octets ; un seul point de configuration du secret. Retirer le repli `dev-secret-key` du `docker-compose.yml`. **Avant VPS. Bloquant.**

### C2 — `POST /auth/transporteur/register` est public : prise de contrôle d'un compte transporteur
`backend/bff/src/auth/auth.controller.ts:56-60` (`@Public()`), `backend/bff/src/auth/auth.service.ts:350-393`.

L'endpoint lie un compte Echango (email + mot de passe choisis par l'appelant) à un `Driver` Fleetbase désigné par son UUID. La seule vérification est que l'UUID existe et n'est pas déjà lié (`auth.service.ts:364-378`). **Aucune preuve de possession** : ni code d'invitation, ni validation par un opérateur, ni vérification d'email ou de téléphone. Premier arrivé, premier servi.

**Chaîne d'attaque complète, entièrement réalisable** :
1. Un commerçant (inscription libre, cf. E4) crée une commande et la consulte. `commercant.service.ts:65` renvoie **l'objet Fleetbase brut** — dont `driver_assigned_uuid`, dont la présence dans la sortie de `getAllOrders()` est prouvée par son usage en `transporteur.service.ts:247`.
2. Il appelle `POST /auth/transporteur/register` avec cet UUID et ses propres identifiants.
3. Il est désormais **ce transporteur** : il voit ses courses, peut les accepter, les démarrer, les marquer livrées, remonter sa position GPS, basculer sa disponibilité — et il enregistre son jeton push sur le `UserDevice` du driver (`auth.service.ts:584-604`).
4. Le vrai transporteur ne peut plus s'inscrire : l'UUID est marqué comme déjà lié (`auth.service.ts:368`).

**Correction** : le provisioning est déjà documenté comme manuel — rendre l'inscription cohérente avec cette décision. Soit l'opérateur crée le compte Echango complet (endpoint protégé, réservé à un rôle opérateur), soit il émet un jeton d'invitation à usage unique, à durée de vie courte, stocké côté BFF et exigé par le DTO. Dans les deux cas, retirer `@Public()` ou le conditionner à ce jeton. **Avant VPS. Bloquant.**

## ÉLEVÉ

### E3 — Injection de chemin vers l'API Fleetbase via `subjectId` / `waypointUuid`
`backend/bff/src/fleetbase/fleetbase-api.client.ts:529-531`, alimenté par `backend/bff/src/transporteur/dto/transporteur.dto.ts:104-106` (`subjectId`) et `:81-83` (`waypointUuid`), via `transporteur.service.ts:415-420` et `:462-467`.

```ts
const path = subjectId
  ? `/orders/${orderPublicId}/capture-photo/${subjectId}`
  : `/orders/${orderPublicId}/capture-photo`;
```

`subjectId` est un `@IsString()` non contraint, interpolé tel quel dans le chemin.

**Attaque** : un transporteur légitime, sur **sa propre** commande (tous les contrôles d'appartenance passent), envoie `subjectId = "../../ORDER_X/cancel"`. Le chemin devient `/v1/orders/ORDER_A/capture-photo/../../ORDER_X/cancel`, que le serveur amont normalise en `/v1/orders/ORDER_X/cancel` — exécuté avec le **token de service** qui a les droits sur toute l'organisation. Le contrôle d'appartenance porte sur `orderPublicId`, pas sur la destination réelle de la requête. Toute route `POST /v1/...` devient atteignable : annuler, dispatcher, compléter n'importe quelle commande de n'importe quel commerçant.

**Correction** : valider les deux champs comme UUID (`@IsUUID('4')`) ou, a minima, `@Matches(/^[A-Za-z0-9_-]+$/)` avec `@MaxLength`. Règle générale à appliquer partout : `encodeURIComponent()` sur tout segment de chemin construit à partir d'une entrée client. **Avant VPS.**

### E4 — `CommerçantController` est le seul des trois à ne pas vérifier `req.user.type`
`backend/bff/src/commercant/commercant.controller.ts:10-43` (les 7 routes passent `req.user.id` sans filtre), et `backend/bff/src/auth/auth.controller.ts:42-45` (`POST /auth/device-token`).

`FlotteController` (`flotte.controller.ts:46-51`) et `TransporteurController` (`transporteur.controller.ts:33-38`) refusent explicitement les jetons du mauvais persona. Le module commerçant, non — alors que le journal §6.4 pose ce contrôle comme le « troisième garde » du modèle.

**Attaque** : aujourd'hui l'exploitation directe est bloquée par hasard — les identifiants sont des `cuid` distincts par table, donc `getMerchantWithValidation(driverId)` échoue en 404. La protection tient à une propriété non documentée du schéma, pas à un contrôle. Elle tombe dès que quoi que ce soit change : identifiants dérivés d'une source commune, migration vers un compte unifié multi-profils, import de comptes.

**Correction** : ajouter le helper `merchantId(req)` sur le modèle exact des deux autres contrôleurs, et le contrôle de type sur `POST /auth/device-token`. Mieux : un décorateur `@Persona('merchant')` + un guard, pour que l'oubli ne soit plus possible sur une route future. **Avant VPS** (coût : quelques lignes).

### E5 — Aucune limitation de débit, aucun verrouillage de compte
`backend/bff/src/main.ts:5-27` (pas de `ThrottlerModule`), `backend/bff/package.json:27-42` (`@nestjs/throttler` absent), `backend/bff/src/auth/auth.controller.ts` (6 endpoints d'authentification publics).

**Attaque** : bruteforce en ligne illimité sur `/auth/login` et les cinq endpoints par persona. La politique de mot de passe est `@MinLength(8)` sans autre contrainte — un dictionnaire de 10 000 mots de passe courants suffit. Second usage : `/auth/merchant/register` et `/auth/flotte/register` créent chacun un `Vendor` Fleetbase (`auth.service.ts:44`, `:243`) ; un script les appelle en boucle et pollue durablement l'organisation. Troisième : `bcrypt` à 10 tours × 3 comparaisons par appel à `loginUnified` fait de cet endpoint un amplificateur CPU.

**Correction** : `@nestjs/throttler` en global, avec un plafond serré et spécifique sur `/auth/*` (ex. 5 tentatives / 15 min par IP **et** par email) ; verrouillage temporaire après N échecs sur un compte ; reverse-proxy avec `limit_req` en défense complémentaire. **Avant VPS.**

### E6 — Inscription commerçant/flotte ouverte à tous, email jamais vérifié
`backend/bff/src/auth/auth.controller.ts:18-40` (`@Public()`), `backend/bff/src/auth/auth.service.ts:83` (`emailVerified: true, // TODO: Email verification in v2`).

**Attaque** : n'importe qui sur Internet crée un compte commerçant avec un email qu'il ne contrôle pas, obtient un `Vendor` Fleetbase et un jeton valide, puis injecte des commandes dans le pool de dispatch mutualisé. Le broadcast géospatial envoie alors de vrais transporteurs à de fausses adresses — atteinte directe à la ressource la plus coûteuse de la plateforme et à la confiance du réseau, qui est la thèse produit. `emailVerified: true` codé en dur neutralise au passage le seul contrôle prévu (`auth.service.ts:193-195`).

**Correction** : pour une plateforme B2B à onboarding manuel, l'inscription libre n'est pas le bon modèle — passer par une validation opérateur (compte créé `active: false`, activé après vérification) ou par invitation. Au minimum, implémenter la vérification d'email et repasser `emailVerified` à `false` par défaut. **Avant VPS** — c'est une décision produit autant que technique, mais elle doit être tranchée avant l'exposition publique.

## MOYEN

### M7 — Énumération de comptes : par code de retour, par message, et par temps de réponse
`auth.service.ts:38` / `:238` / `:361` (409 « Email already registered »), `:193-199` (« Email not verified » / « Account is inactive » vs « Invalid email or password »), `:130-152` (`loginUnified`).

Trois oracles indépendants. (1) L'inscription répond 409 sur un email connu, 400/201 sinon. (2) `loginMerchant` distingue trois messages là où `loginUnified` prétend n'en avoir qu'un — un attaquant qui vise `/auth/merchant/login` apprend qu'un compte existe. (3) **Timing** : `loginUnified` n'appelle `bcrypt.compare` que si la ligne existe. Email inconnu partout = 3 requêtes SQL, quelques millisecondes. Email connu = un `bcrypt` à 10 tours, ~100 ms. L'écart est d'un ordre de grandeur, mesurable de façon fiable même à travers Internet, et le commentaire ligne 155-156 (« ne pas révéler quels emails existent ») ne décrit donc pas le comportement réel.

**Correction** : comparer systématiquement contre un hash factice précalculé quand aucune ligne n'est trouvée (chemin à coût constant) ; message unique pour tous les échecs d'authentification, y compris « non vérifié » et « inactif » ; réponse identique à l'inscription, avec notification par email au titulaire en cas de doublon. **Avant VPS** pour le timing et les messages ; l'inscription suit la décision E6.

### M8 — Injection de chemin `orderId` dans le module flotte
`backend/bff/src/flotte/flotte.service.ts:75` → `fleetbase-api.client.ts:301` : `GET /int/v1/orders/${orderId}`, `orderId` venant directement de `@Param('id')` (`flotte.controller.ts:16`) sans aucune validation.

Même mécanisme que E3, en lecture. L'impact est plus faible — le contrôle `facilitator_uuid` en ligne 82 rejette la plupart des réponses détournées — mais un gestionnaire de flotte peut néanmoins faire émettre des `GET` arbitraires sur `int/v1` avec le token de service, et distinguer les ressources existantes des autres par les codes/latences.

**Correction** : `@IsUUID()` sur le paramètre (pipe de validation dédié) et `encodeURIComponent()` côté client HTTP. **Avant VPS** — corrigé en même temps que E3.

### M9 — Toutes les commandes adhoc de l'organisation sont exposées à tout transporteur authentifié
`backend/bff/src/transporteur/transporteur.service.ts:246-248` et `:252`.

Aucun filtre de proximité, aucune vérification que ce transporteur a effectivement été « pingé » par le dispatch géospatial. Tout compte transporteur valide obtient donc, à la demande, **l'intégralité des livraisons en attente de tous les commerçants** : adresses d'enlèvement et de livraison, noms et téléphones de contact, instructions. C'est un flux de renseignement concurrentiel en continu sur l'activité de chaque commerçant, et une base de données de PII clients. Le commentaire ligne 243-245 explique que « Fleetbase décide qui est pingé » — mais cette décision n'est jamais consultée ici.

**Correction** : restreindre la liste adhoc aux commandes réellement diffusées à ce driver (`OrderPing` / la table de dispatch côté Fleetbase), ou à défaut appliquer un filtre de rayon autour de sa dernière position connue ; et ne renvoyer, avant acceptation, qu'un aperçu (distance, zone approximative, rémunération) — l'adresse exacte et les coordonnées du client n'ont pas à être connues avant la prise en charge. **Avant VPS** pour la restriction des champs ; le filtre de diffusion peut suivre.

### M10 — Les objets Fleetbase bruts sont renvoyés aux clients sans projection
`commercant.service.ts:65`, `transporteur.service.ts:154-167` / `:291`, `flotte.service.ts:86` / `:108` / `:150`.

Les trois modules relaient l'objet Fleetbase intégral. Ce qui est exposé n'est donc pas décidé par le BFF mais par Fleetbase, et changera silencieusement à chaque mise à jour de l'amont. C'est ce qui rend E4/C2 exploitables (fuite de `driver_assigned_uuid`) et M9 aussi grave. `include: { commissions: true }` (`commercant.service.ts:115`, `:130`) expose au passage les données de commission au client.

**Correction** : une fonction de projection explicite par persona, en liste d'autorisation. C'est le correctif structurel qui referme plusieurs constats à la fois. **Après VPS acceptable si M9/C2 sont traités**, mais c'est la bonne dette à payer tôt.

### M11 — Photos base64 sans borne de taille, et pas de limite de corps de requête explicite
`backend/bff/src/transporteur/dto/transporteur.dto.ts:93-97` (`photos: string[]`, `@ArrayMinSize(1)` sans `@ArrayMaxSize` ni `@MaxLength`), `:88-90` (`photo?: string`), `backend/bff/src/main.ts:5-27` (aucune configuration de `bodyParser`).

Le plafond effectif est aujourd'hui le défaut d'Express (100 ko) — ce qui signifie deux choses : la fonctionnalité de preuve photo est probablement cassée pour une vraie photo de téléphone (une image de 300 ko en base64 fait ~400 ko → 413), et le jour où quelqu'un relèvera la limite pour corriger ça, plus rien ne bornera la charge.

**Correction** : fixer explicitement la limite (`app.use(json({ limit: '8mb' }))`) **et** borner le DTO (`@ArrayMaxSize(5)`, `@MaxLength(~7_000_000)` par photo), afin que les deux bornes soient cohérentes et intentionnelles. **Avant VPS** (c'est aussi une correction fonctionnelle).

### M12 — Aucune révocation de session
`auth.service.ts:661-674` (`generateToken`), aucun endpoint de déconnexion côté serveur, aucune liste de révocation.

Un jeton volé reste valide 24 h. Changer son mot de passe n'invalide rien. La désactivation d'un compte est en revanche bien prise en compte immédiatement (`getDriverOrFail`, `getMerchantWithValidation`, `getFleetWithValidation` relisent `active` à chaque requête) — c'est le bon réflexe, il manque juste son pendant sur les jetons.

**Correction** : un champ `tokenVersion` (ou `passwordChangedAt`) par compte, embarqué dans le jeton et comparé à chaque requête — le contrôle en base existe déjà, il suffit d'y ajouter une comparaison. **Après VPS** acceptable si E5 est en place.

## FAIBLE

### F13 — Détails d'erreur Fleetbase renvoyés au client quand `NODE_ENV=development`
`auth.service.ts:102-107` / `:283-288` / `:426-431`, `commercant.service.ts:181-186`, `flotte.service.ts:184-189` — et `backend/bff/docker-compose.yml:37` qui pose `NODE_ENV: development` en dur.

Le garde-fou est correct, mais le seul fichier de déploiement du dépôt force la valeur qui l'ouvre. **Avant VPS** — vérification de déploiement, pas de code.

### F14 — Le modèle `AuditLog` existe mais n'est jamais écrit
`backend/bff/prisma/schema.prisma:261-288`. Les refus anti-IDOR ne laissent qu'un `logger.warn` — non structuré, non requêtable, perdu à la rotation. Sur un système dont toute l'isolation est applicative, l'absence de piste d'audit signifie qu'une exploitation réussie ne serait ni détectée ni reconstituable. **Après VPS**, mais avant l'ouverture B2B.

### F15 — Résidus et incohérences de configuration d'authentification
- `jwt.strategy.ts` est du **code mort** : `JwtAuthGuard` surcharge `canActivate` et n'appelle jamais `super.canActivate()`. Une modification faite dans la stratégie en croyant durcir l'authentification n'aurait aucun effet. Le supprimer.
- `jwtService.verify()` (`jwt-auth.guard.ts:38`) ne fixe ni `algorithms`, ni `issuer`, ni `audience`. Expliciter `{ algorithms: ['HS256'] }` coûte une ligne.
- `schema.prisma:28` annote `fleetbaseSanctumToken` « encrypted at rest » — aucun chiffrement n'existe. Corriger le commentaire ou implémenter avant usage.
- Politique de mot de passe limitée à 8 caractères, sans blocage des mots de passe courants.

**Après VPS**, hors la ligne `algorithms`.

## Points vérifiés — conformes

- **Aucun secret en dur dans un fichier versionné.** Les scripts lisent `JWT_SECRET` depuis `.env`, non versionné. `.env.example` ne contient que des valeurs de remplacement.
- **Stockage du jeton côté app** : `flutter_secure_storage`, jamais `SharedPreferences`. Les prefs ne contiennent que rôle/email/id/nom d'affichage, non sensibles — le serveur retranche le type à chaque requête.
- **Comptes de test** : verrouillés sur `kDebugMode` ET `--dart-define` — rien de versionné, rien en release.
- **Journalisation** : ni jeton, ni mot de passe, ni en-tête Authorization dans les logs. Réserve : `fleetbase-api.client.ts:27` journalise les payloads d'erreur Fleetbase complets — à filtrer si les logs sont centralisés.
- **Filtrage anti-IDOR** : appliqué avec rigueur et homogénéité dans les trois modules ; le module `flotte`, soupçonné d'être moins rigoureux, est au niveau des deux autres (seule faiblesse propre : M8). `transporteur.getOrder` répond 404 et non 403 — bon choix.
- **`ValidationPipe`** global avec `whitelist` + `forbidNonWhitelisted` : injections de masse fermées.

*Note de fiabilité (pas une faille)* : `getAllOrders()` avec `limit=100` par défaut → passé 100 commandes dans l'organisation, des commandes légitimes deviennent invisibles. Panne silencieuse programmée ; seul `flotte.fetchAllOrders` pagine.

## Les 3 corrections prioritaires avant mise en ligne

1. **C1 — Supprimer les trois secrets JWT par défaut et valider `JWT_SECRET` au démarrage.**
2. **C2 — Fermer `POST /auth/transporteur/register` (et, dans la foulée, E6)** — invitation à usage unique émise par un opérateur.
3. **E3 + M8 — Valider tout identifiant interpolé dans une URL Fleetbase.**

Juste derrière, et peu coûteux : **E4** (garde de type sur le contrôleur commerçant) et **E5** (limitation de débit sur `/auth/*`).
