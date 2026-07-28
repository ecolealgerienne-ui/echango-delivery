# Journal d'implémentation BFF — 27-28 juillet 2026

Ce document trace en détail la session d'implémentation Docker + debugging réel du BFF (Backend For Frontend) des 27-28 juillet 2026 : scaffolding Week 1-2 (auth, commandes commerçant), mise en place Docker, et surtout la découverte par test réel de plusieurs écarts entre les hypothèses de `docs/specs_bff.md` et le comportement effectif de l'API Fleetbase. Le `CLAUDE.md` à la racine reste la source de vérité condensée ; ce journal sert de trace détaillée pour ne rien perdre de ce qui a été testé et pourquoi, dans le même esprit que `docs/journal_exploration_fleetbase.md`.

Contexte général : voir `CLAUDE.md` et `docs/specs_bff.md`.

---

## 1. Mise en place Docker

### 1.1 Décision : développement 100% Docker

Sur demande explicite de l'utilisateur ("je dois travailler directement en Docker"), le `Dockerfile` a été restructuré en 3 stages nommés :
- **`development`** : toutes les dépendances (y compris `@nestjs/cli`, une devDependency), utilisé par `docker-compose.yml` avec le code source monté en volume pour le live-reload (`npm run start:dev`, watch mode)
- **`builder`** : compile le TypeScript pour produire l'image de production
- **`production`** : dépendances de prod uniquement, copie le `dist/` compilé du builder

**Bug rencontré** : `docker-compose` lançait `npm run start:dev` (= `nest start --watch`) contre le stage runtime qui n'installait que les dépendances de production (`npm install --omit=dev`). Comme `@nestjs/cli` est une devDependency, la commande `nest` était introuvable (`sh: nest: not found`). Résolu par la séparation en stages ci-dessus.

### 1.2 Bug rencontré — Prisma incompatible avec OpenSSL sur Alpine

```
PrismaClientInitializationError: Unable to require libquery_engine-linux-musl.so.node
Error loading shared library libssl.so.1.1: No such file or directory
```

**Cause** : `node:20-alpine` récent embarque OpenSSL 3.x, mais le moteur Prisma `linux-musl` par défaut est compilé contre OpenSSL 1.1 (`libssl.so.1.1`), absent des images Alpine récentes.

**Fix** :
- `prisma/schema.prisma` : ajout de `binaryTargets = ["native", "linux-musl-openssl-3.0.x"]` dans le générateur, pour que Prisma génère/télécharge le moteur compatible OpenSSL 3.0
- `Dockerfile` : ajout du paquet `openssl` (fournit `libssl.so.3`) dans les 3 stages

### 1.3 Bug rencontré — `host.docker.internal` introuvable

```
Error: getaddrinfo ENOTFOUND host.docker.internal
```

**Cause** : `host.docker.internal` est une commodité de Docker Desktop (Mac/Windows), absente par défaut sur Docker Engine natif Linux (l'environnement réel de l'utilisateur, confirmé par les noms de containers `fleetbase-src-*` tournant sur le même hôte).

**Fix** : ajout de `extra_hosts: ["host.docker.internal:host-gateway"]` au service `bff` dans `docker-compose.yml` — solution standard supportée depuis Docker 20.10.

### 1.4 Conflits de ports

Le port 5432 (Postgres) était déjà utilisé par un autre projet (`ro_postgres`) sur la machine de l'utilisateur, et même le port de repli 5433 était pris (`echangopromo-postgres-1`). Résolu en mappant le Postgres du BFF sur le port hôte **5434** (le port interne au réseau Docker reste 5432, inchangé).

---

## 2. Découverte majeure — l'API Fleetbase réelle diffère du scoping initial

C'est le cœur de cette session : `docs/specs_bff.md` avait scopé le BFF sur des hypothèses raisonnables mais jamais testées contre une vraie instance. Plusieurs hypothèses se sont révélées fausses, chacune découverte par test direct (`curl`) contre l'instance Fleetbase locale, jamais par supposition.

### 2.1 Pas de préfixe `/api`

**Hypothèse initiale (fausse)** : `FLEETBASE_API_URL=http://host.docker.internal:8000/api`, avec les routes internes appelées en `/api/int/v1/...`.

**Réalité, confirmée deux fois** :
- Chaque appel avec le préfixe `/api` retournait `{"errors":["There is nothing to see here."]}` avec un code 400 — **quel que soit le token envoyé** (clé invalide, clé plateforme réelle, token Sanctum réel), ce qui aurait dû alerter plus tôt : ce n'est pas un message d'erreur d'authentification.
- Lecture du code : ce message vient de `Handler.php` (package `core-api`), `case 'NotFoundHttpException': return response()->error('There is nothing to see here.')` — un `NotFoundHttpException` Laravel générique (route non trouvée), **pas** une erreur d'auth (qui a son propre message `"Unauthenticated."`).
- Confirmation définitive : `php artisan tinker --execute="echo route('vendors.createRecord...');"` retourne littéralement `http://localhost:8000/int/v1/vendors` — sans `/api`.

**Correction** : `FLEETBASE_API_URL` sans `/api` (ni dans `docker-compose.yml`, ni dans `.env.example`, ni dans le fallback par défaut de `fleetbase-api.client.ts`).

**Leçon retenue** : un message d'erreur identique sur des payloads/tokens complètement différents est un signal fort qu'il ne s'agit pas de l'erreur qu'on croit — creuser le message lui-même (ici, dans le code source de l'exception handler) plutôt que de continuer à varier les tokens.

### 2.2 La clé « API Key » du Developer Console ne sert (presque) à rien pour nous

**Hypothèse initiale (fausse)** : la clé API (`flb_live_...`/`flb_test_...`, générée dans Console → Developers → API Keys) suffit comme credential de service-account pour le BFF, envoyée en `Authorization: Bearer flb_live_...`.

**Réalité, confirmée par lecture de code** :
- Les routes `int/v1/vendors`, `int/v1/customers`, `int/v1/orders`, etc. tournent sous le groupe de middleware `fleetbase.protected`, qui inclut `auth:sanctum` — une authentification Sanctum complète (session ou personal access token d'un vrai `User`), **pas** un simple en-tête API key.
- La clé `flb_live_.../flb_test_...` est validée par un mécanisme entièrement différent (`AuthenticatePlatformApiToken` / `PlatformApi::validateToken()`), sous le groupe `fleetbase.platform-api`, qui ne protège que **deux routes précises** : `v1/organizations` (liste) et `v1/orders/{id}/update-activity` (mise à jour de statut, pensé pour des systèmes externes/webhooks). Aucune route de création vendor/customer/order n'est accessible avec cette clé.
- Vérifié en pratique : `flb_live_...` sur `int/v1/vendors` → `401 Unauthenticated.` (une fois l'URL corrigée). Un token Sanctum personal access token (`$user->createToken('bff-service-account')->plainTextToken`, format `id|token`) sur la même route → `201 Created`, vendor réellement créé.

**Correction** : `FLEETBASE_API_KEY` doit contenir un **token Sanctum personal access** d'un `User` Fleetbase dédié (compte de service), pas la clé du Developer Console. `.env.example` documente maintenant explicitement cette distinction.

**Reste ouvert** : pour la prod, il faudra provisionner un vrai `User` "service account BFF" dédié (rôle/permissions minimales), pas réutiliser le compte admin de test (`bengharbi@hotmail.com`) utilisé pendant cette session de debug.

### 2.3 Création du "customer" — pas de route `POST /customers`

**Hypothèse initiale (fausse)** : `POST /customers` avec `{vendor_uuid, email, first_name, last_name, type: 'customer'}`.

**Réalité** : cette route n'existe pas en écriture (`int/v1/customers` n'a que `GET|HEAD`). Le mécanisme réel, confirmé par lecture de `VendorController::addVendorPersonnel()`, est `POST /vendors/{vendorId}/personnels` avec `{email, name, type}` — qui :
- crée/rattache un `Contact` comme personnel du `Vendor` (exactement le pattern déjà découvert manuellement dans `docs/specs_echango_delivery.md` §3.1 : "Contact rattaché comme personnel du Vendor")
- auto-provisionne un `User` Fleetbase lié, avec le rôle **"Fleet-Ops Customer"** (`create_login` vaut `true` par défaut) — ce `User` est créé avec `status: "pending"`, `email_verified_at: null`, ce qui semble normal pour un compte fraîchement créé et ne bloque pas le flux BFF actuel (le BFF gère son propre JWT et son propre flag `emailVerified`, indépendamment de l'état Fleetbase).

**Correction** : `FleetbaseApiClient.createCustomer()` appelle maintenant `POST /vendors/{vendorUuid}/personnels`, et `auth.service.ts` parse `personnel.contact_uuid` (pas `data.uuid`).

### 2.4 Forme réelle des réponses — pas de wrapper `.data`

Plusieurs bugs de parsing venaient d'une hypothèse implicite fausse : que les réponses Fleetbase auraient une forme `{data: {...}}`. En réalité chaque endpoint wrappe sa ressource sous une clé **singulière nommée d'après le modèle** :
- `POST /vendors` → `{"vendor": {"uuid": ..., ...}}`
- `POST /vendors/{id}/personnels` → `{"personnel": {"contact_uuid": ..., "contact": {"uuid": ..., "user": {...}}}}`
- `POST /places` → `{"place": {"uuid": ..., ...}}`
- `GET /order-configs` → `{"order_configs": [...]}` (pluriel pour une liste)

`auth.service.ts` et `fleetbase-api.client.ts` ont été corrigés pour lire ces clés directement (`vendorResponse.vendor.uuid`, etc.) plutôt que `.data.uuid`.

### 2.5 Création de commande — payload imbriqué + Places pré-créées obligatoires

**Hypothèse initiale (fausse)** : un payload plat avec `pickup`/`dropoff` inline (nom + lat/lng) suffit.

**Réalité, découverte via un crash PHP explicite** :
```
Illuminate\Validation\Factory::make(): Argument #1 ($data) must be of type array, null given
```
en lisant `OrderController::createRecord()` : `Validator::make($request->input('order'), $rules)`. Le contrôleur Fleetbase attend **tout le payload imbriqué sous une clé racine `order`** — un payload plat (sans cette enveloppe) rend `$request->input('order')` `null`, d'où le crash PHP (pas une erreur de validation propre : c'est un bug de robustesse côté Fleetbase, un payload malformé plante au lieu de renvoyer une erreur 422 lisible).

Lecture de `CreateOrderRequest::rules()` (le fichier réel des règles de validation) a confirmé :
- `order_config_uuid` : **`required`**, aucun fallback avant la validation (le fallback vers une config par défaut existe dans le code, mais s'exécute *après* la validation, dans le closure passé à `createRecordFromRequest`)
- `payload.pickup_uuid` / `payload.dropoff_uuid` : requis, **sauf** si un tableau `payload.waypoints` (2+ entrées) est fourni à la place — donc pas de lat/lng inline : il faut des UUID de `Place` déjà créées
- `customer` : optionnel, mais doit référencer un UUID existant dans `vendors` OU `contacts` (`ExistsInAny`) — le `Vendor` du commerçant convient

**Correction, implémentée dans `fleetbase-api.client.ts` + `commercant.service.ts`** :
1. `createPlace(name, lat, lng)` → `POST /places` avec `{name, location: {type: 'Point', coordinates: [lng, lat]}}` (ordre GeoJSON : longitude puis latitude), retourne `{place: {uuid, ...}}` — vérifié par test réel (`201`, place créée)
2. `getDefaultOrderConfigUuid()` → `GET /order-configs`, sélectionne la config avec `key === 'transport'` — vérifié : deux configs système existent déjà (`Transport`, `Storefront`), créées automatiquement par Fleetbase
3. `createOrder(order)` → `POST /orders` avec `{order: {...}}` (l'enveloppe correcte), `customer: merchant.fleetbaseVendorUuid`, `payload: {pickup_uuid, dropoff_uuid}`

**✅ Vérifié par test réel de bout en bout** : la commande complète (BFF → Places → order-config → `POST /orders`) a abouti à une vraie commande Fleetbase créée dès le premier essai après ce fix (`uuid` réel, statut "Order Dispatched", numéro de suivi `ECH0224895987SG`, QR code, code-barres, URL de suivi public générée automatiquement). La forme de réponse `{"order": {...}}` est confirmée, cohérente avec le pattern §2.4.

**Sous-bug découvert dans la foulée** : `tracking_number` dans la réponse n'est **pas** une chaîne mais l'objet `TrackingNumber` complet (`{uuid, tracking_number: "ECH...", qr_code, barcode, url, status, ...}`) — la colonne Prisma `Order.trackingNumber` (`String?`) attend `fleetbaseOrder.tracking_number.tracking_number`, pas l'objet entier. Encore un exemple du pattern §2.4 (ne jamais supposer la forme d'une réponse sans la vérifier).

### 2.6 Annulation de commande — pas de route `POST /orders/{id}/cancel`

**Hypothèse initiale (fausse)** : un endpoint REST classique `POST /orders/{id}/cancel`.

**Réalité, confirmée en lisant `OrderController::cancel()`** : la route réelle est `PATCH /orders/cancel` (pas de `{id}` dans le chemin) — l'UUID de la commande est passé dans le corps de la requête, sous la clé `order` : `{"order": "<uuid>"}`.

**Correction** : `cancelOrder(orderUuid)` dans `fleetbase-api.client.ts` appelle `PATCH /orders/cancel` avec `{order: orderUuid}`. Vérifié par test réel (commande passée en statut `cancelled`).

### 2.7 Carnet d'adresses — pas de route `/addresses`, réutilisation de `Place.owner_uuid`

**Question ouverte du projet, tranchée ici par test empirique** (pas de doc officielle trouvée sur le sujet) : `route:list` ne montre aucune route `/addresses` sous `int/v1`. Hypothèse retenue : réutiliser le modèle `Place` existant (déjà utilisé pour pickup/dropoff, §2.5) comme carnet d'adresses, scopé via ses colonnes `owner_uuid`/`owner_type`.

**Vérifié par test réel avant d'implémenter côté BFF** (point important : contrairement à `facilitator_uuid`/`vendor_uuid` sur `/orders`/`/drivers`, voir §2.8 ci-dessous) : `GET /places?owner_uuid=<uuid-sans-place>` renvoie bien une liste vide, et `GET /places?owner_uuid=<uuid-du-vendor-du-commerçant>` renvoie uniquement ses propres `Place`, pas les ~7+ places de la compagnie. `owner_uuid` sur `/places` est donc un filtre serveur réel — contrairement à `facilitator_uuid`/`vendor_uuid`, ce n'est **pas** un cas générique de filtre ignoré, à vérifier au cas par cas par colonne/endpoint.

**Correction** : `createOwnedPlace()` / `getOwnedPlaces()` dans `fleetbase-api.client.ts`, utilisés par `commercant.service.ts` pour `getAddresses`/`saveAddress`, avec `owner_type: 'fleet-ops:vendor'`.

### 2.8 ⚠️ CRITIQUE — les filtres `facilitator_uuid` (`/orders`) et `vendor_uuid` (`/drivers`) sont ignorés côté serveur

**Ne pas confondre avec §2.7** : tous les filtres de query string ne se valent pas — certains fonctionnent réellement (`owner_uuid` sur `/places`, vérifié), d'autres non. Chaque filtre doit être vérifié individuellement, jamais supposé par analogie.

**Hypothèse du document de scoping initial** (`docs/specs_bff.md` §5.2) : le module `flotte` (petite flotte, persona 2) pourrait scoper ses appels à Fleetbase en passant `facilitator_uuid=<vendor_uuid_du_gestionnaire>` sur `GET /orders`, et `vendor_uuid=<vendor_uuid>` sur `GET /drivers`, en confiant à Fleetbase le filtrage côté serveur — ce qui aurait permis d'éviter tout filtrage applicatif côté BFF.

**Réalité, découverte par deux tests empiriques directs, indépendants** :
1. `GET /orders?facilitator_uuid=<uuid réel>` puis `GET /orders?facilitator_uuid=<uuid inexistant/aléatoire>` renvoient **exactement le même jeu de résultats** — les 7 commandes de la compagnie, avec des `facilitator_uuid` variés (voire `null`), indépendamment de la valeur du paramètre.
2. Même constat sur `GET /drivers?vendor_uuid=<uuid inexistant>` : les 2 drivers de la compagnie sont renvoyés intégralement, alors qu'aucun des deux n'appartient au vendor inventé passé en filtre.

**Conclusion — implication de sécurité directe** : ces deux paramètres de query string sont acceptés par l'API (aucune erreur renvoyée) mais **n'ont aucun effet de filtrage réel**. Un BFF qui ferait confiance à ces paramètres pour scoper les données d'un gestionnaire de petite flotte exposerait silencieusement les commandes et les drivers de **toute la compagnie**, y compris ceux des autres commerçants/flottes — un IDOR (Insecure Direct Object Reference) de la pire espèce : la vulnérabilité est invisible en test si on ne compare pas explicitement les résultats avec un filtre valide vs un filtre invalide (une simple requête filtrée qui "a l'air" de fonctionner ne suffit pas à la détecter, car les données réelles du gestionnaire sont *incluses* dans le résultat, juste noyées avec celles des autres).

**Correction obligatoire, appliquée dans `flotte.service.ts`** : ne jamais transmettre `facilitator_uuid`/`vendor_uuid` à Fleetbase comme mécanisme de sécurité. À la place :
1. Récupérer l'intégralité de la liste depuis Fleetbase (`GET /orders` / `GET /drivers`, sans filtre de confiance)
2. Filtrer **côté BFF, en mémoire**, en ne gardant que les enregistrements dont `facilitator_uuid`/`vendor_uuid` correspond exactement au `fleetbaseVendorUuid` du `FleetAccount` authentifié (comparaison stricte, jamais de filtre optimiste)
3. Appliquer la même vérification en lecture unitaire (`getOrderDetail`) : après récupération par ID, vérifier l'appartenance avant de renvoyer quoi que ce soit (même pattern anti-IDOR que `commercant.service.ts` avec `merchantId`)

**À reporter dans `docs/specs_bff.md` §5.2** (pas fait dans cette session — le document de scoping doit être corrigé pour ne plus présenter le filtrage serveur comme acquis).

---

## 3. Bugs BFF (indépendants de Fleetbase)

Ces bugs auraient existé même avec une API Fleetbase parfaitement documentée — erreurs internes au code NestJS/TypeScript du BFF.

### 3.1 `JwtAuthGuard` ignore `JwtStrategy`, perd le mapping `sub` → `id`

`JwtAuthGuard.canActivate()` réimplémente sa propre vérification du token (`this.jwtService.verify(token)`) au lieu d'appeler `super.canActivate()` (Passport), et assigne le payload JWT brut à `request.user`. Le payload contient `{sub, email, type}` — **pas `id`**. Tous les contrôleurs lisant `req.user.id` recevaient donc `undefined`, ce qui plantait silencieusement en 500 dès le premier appel Prisma utilisant cet id (`Argument where of type ... needs at least one of id, email or fleetbaseVendorUuid`).

**Fix** : mapping explicite `request.user = {id: payload.sub, email: payload.email, type: payload.type}` dans le guard. `JwtStrategy` reste de facto du code mort (jamais invoqué par ce guard) — pas nettoyé dans cette session, cosmétique.

### 3.2 Expiration JWT ~86 secondes au lieu de 24h

`JWT_EXPIRATION=86400` (secondes, censé donner 24h) était passé tel quel (string) à `jwtService.sign(..., {expiresIn})`. La librairie `ms` (dépendance de `jsonwebtoken`) interprète une chaîne numérique **sans unité** comme des **millisecondes** — `ms("86400")` = 86400 ms ≈ 86 secondes. Confirmé empiriquement : un token avec `exp - iat = 86` secondes pile.

**Fix** : `parseInt(JWT_EXPIRATION, 10)` avant de le passer à `sign()` — un `expiresIn` de type `number` est traité par `jsonwebtoken` comme des secondes directement, sans repasser par `ms`.

### 3.3 `page`/`limit` non transformés en `number` dans `ListOrdersQueryDto`

Les query params HTTP arrivent toujours en `string` (`?limit=10` → `"10"`), contrairement aux champs JSON d'un body qui gardent leur type. Sans `@Type(() => Number)` (class-transformer), même avec `ValidationPipe({transform: true})` global, `page`/`limit` restaient des strings et cassaient Prisma (`Argument take: Invalid value provided. Expected Int, provided String.`).

**Fix** : ajout de `@Type(() => Number)` + `@IsInt()` sur les deux champs.

### 3.4 `firstName`/`lastName` requis dans le DTO alors qu'optionnels en base

`MerchantRegisterDto` exigeait `firstName`/`lastName` (`@IsString()` sans `@IsOptional()`), alors que le schéma Prisma (`MerchantAccount.firstName String?`) les traite comme optionnels. Fix : ajout de `@IsOptional()`.

---

## 4. Méthode de travail qui a fonctionné (à répéter)

Face à des erreurs opaques ou identiques sur des variations de requête, la vérification directe contre le code source réel de Fleetbase (dans le conteneur `fleetbase-src-application-1`, via `docker exec ... grep/cat/php artisan route:list/tinker`) a été systématiquement plus rapide et plus fiable que d'itérer par essai-erreur sur les payloads/headers envoyés par le BFF. En particulier :
- `php artisan route:list` pour lister les routes réelles et leurs middlewares
- `php artisan route:list -v` pour voir la chaîne de middleware complète d'une route précise
- `php artisan tinker --execute="echo route('...')"` pour obtenir l'URL absolue réelle générée par Laravel, sans ambiguïté sur les préfixes
- Lecture directe des fichiers de contrôleurs/requests (`grep -n ... -A N`) pour voir les règles de validation exactes plutôt que de les déduire de messages d'erreur tronqués
- Quand une erreur est strictement identique quel que soit l'input testé, chercher le message littéral dans le code source (`grep -rln "message exact"`) plutôt que de continuer à varier l'input — ça a directement mené à la découverte du §2.1 (NotFoundHttpException masqué, pas un problème d'auth)
