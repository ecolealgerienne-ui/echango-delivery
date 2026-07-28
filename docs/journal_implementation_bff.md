# Journal d'implémentation BFF — 27-28 juillet 2026, complété le 28/07/2026 (endpoints driver)

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

**Reporté dans `docs/specs_bff.md` §5.2** (fait le 28/07/2026 — le document de scoping ne présente plus le filtrage serveur comme acquis).

**✅ Module `flotte` validé de bout en bout par test réel (28/07/2026)**, avec deux comptes de flotte distincts (`Fleet A`/`Fleet B`, chacun son propre Vendor au sein de la même Organization) pour prouver l'isolation, pas seulement la fonctionnalité :
- `POST /vendors/{id}/assign-driver` (driver → vendor) : confirmé, `GET /flotte/drivers` renvoie strictement le driver du bon vendor pour chaque compte, jamais celui de l'autre.
- `GET /flotte/commandes` : sur 2 commandes appartenant à Fleet A (`facilitator_uuid` posé manuellement, voir §2.10 sur la vraie méthode), Fleet A voit ses 2 commandes, Fleet B voit une liste vide — filtrage applicatif confirmé correct.
- `GET /flotte/commandes/{id}` : Fleet A → `200`, Fleet B sur la même commande → `403` (anti-IDOR confirmé).
- `POST /flotte/commandes/{id}/assigner` : Fleet A assigne son propre driver à sa propre commande → `201`, dispatch réel déclenché côté Fleetbase (`driver_assigned_uuid` posé, notification driver). Fleet B tente d'assigner son driver à la commande de Fleet A → `403`, rejeté avant même d'atteindre Fleetbase.

### 2.9 `facilitator_uuid` sur `/orders` — fausse alerte de méthode, pas un bug Fleetbase

Au cours de cette session, une variable shell (`$VENDOR_A_UUID`) censée porter l'UUID du Vendor de test s'est retrouvée vide (perdue entre deux commandes, jamais réellement exportée dans le terminal utilisateur — seulement affichée dans un bloc de commande). Plusieurs tentatives de créer/modifier une commande avec `facilitator_uuid` (ou `facilitator`) valant cette variable vide ont donc silencieusement échoué à chaque fois, ce qui a été interprété à tort comme un bug de persistance Fleetbase (colonne `$fillable`, mais jamais écrite en base, vérifié jusqu'au SQL brut avec `DB::table('orders')->update(...)` renvoyant 0 lignes modifiées).

**Une fois la variable correctement réexportée avec la vraie valeur, `facilitator_uuid`/`facilitator_type` fonctionnent parfaitement dès le premier essai**, via `POST /orders` avec ces deux clés directement (les noms de colonnes `$fillable` du modèle `Order`, pas la clé virtuelle `facilitator` qui n'a pas de resolver dédié contrairement à `customer` — voir §2.10). Aucune anomalie Fleetbase réelle sur ce point.

**Leçon de méthode explicitement notée** : avant de creuser une hypothèse de bug applicatif via lecture de source/DB, toujours vérifier l'état des variables d'environnement/shell utilisées dans le test qui a échoué (`echo "VAR=[$VAR]"`) — un simple test à vide aurait évité l'essentiel de cette investigation.

### 2.10 Création de commande — `customer` doit être `customer_uuid`/`customer_type`, pas une chaîne plate

Découverte pendant l'investigation ci-dessus (en lisant `OrderController::normalizeCustomerType()`) : cette méthode ne lit que `input['customer_uuid']` ou `input['customer']['uuid']` (objet imbriqué) — **jamais** une simple chaîne `input['customer']`. Or `commercant.service.ts`/`fleetbase-api.client.ts` envoyaient depuis le début `customer: merchant.fleetbaseVendorUuid` (chaîne plate), silencieusement ignorée par `normalizeCustomerType()` : validation passe (`ExistsInAny` sur `uuid`, qui matche bien), mais `customer_uuid` reste `null` en base sur **toutes** les commandes commerçant créées jusqu'ici, y compris la toute première commande de test de la session précédente — jamais vérifié jusqu'à aujourd'hui.

**Fix** : envoyer directement `customer_uuid`/`customer_type` (les colonnes `$fillable` réelles du modèle `Order`, même pattern que `facilitator_uuid`/`facilitator_type` confirmé en §2.9) plutôt que la clé virtuelle `customer`. Corrigé dans `fleetbase-api.client.ts::createOrder()` et son appel dans `commercant.service.ts`.

**✅ Vérifié par test réel de bout en bout (28/07/2026)** : nouveau commerçant enregistré, commande créée via `POST /commercant/commandes`, puis vérification directe côté Fleetbase — `customer_uuid` correctement peuplé avec l'UUID du Vendor du commerçant, `customer_type: "vendor"`. Le fix est confirmé correct, pas seulement plausible.

### 2.11 `GET /driver-positions` n'existe pas — vraie ressource `/int/v1/positions`, sans filtre par driver

`GET /driver-positions?driver_ids=...` (hypothèse non vérifiée posée en §"flotte") renvoie `{"errors":["There is nothing to see here."]}` — le même 404 masqué que §2.1, confirmant que la route n'existe pas du tout. La vraie ressource, trouvée via `route:list`, est le contrôleur générique `/int/v1/positions` (CRUD standard : `queryRecord`/`createRecord`/`findRecord`/`updateRecord`).

Lecture de `PositionFilter.php` : **aucun filtre par `driver_uuid` n'existe** — seuls `query` (recherche texte libre) et `createdAt` sont supportés, en plus du scoping automatique par `company_uuid`. Un paramètre `driver_uuid` serait donc silencieusement ignoré, même pattern que §2.8.

**Fix, dans `flotte.service.ts::getDriverPositions`** : `fetchAll` sur `/positions` (sans filtre de confiance) puis filtrage en mémoire par les UUID des drivers possédés par la flotte — même pattern anti-IDOR que pour `/orders`/`/drivers`. **Non vérifié de bout en bout** : la compagnie de test a 0 enregistrement `Position` (aucun driver n'a jamais envoyé de position GPS réelle dans cette instance de dev), donc la forme exacte du champ de référence driver (`subject_uuid` vs `driver_uuid`, actuellement les deux tentés en fallback) reste à confirmer avec une vraie donnée.

### 2.12 Création de driver — même bug d'enveloppe que §2.5, payload doit être `{driver: {...}}`

**Hypothèse initiale (fausse)** : `POST /drivers` avec un payload plat `{name, email, phone}`, par analogie avec `/vendors` et `/places` (qui, eux, acceptent bien un payload plat).

**Réalité, découverte par test réel** : crash PHP identique à celui du §2.5, cette fois dans `DriverController::createRecord()` ligne 67 — `Illuminate\Validation\Factory::make(): Argument #1 ($data) must be of type array, null given`, exactement le même symptôme (`$request->input('driver')` vaut `null` faute d'enveloppe).

**Fix** : `createDriver()` dans `fleetbase-api.client.ts` envoie maintenant `{driver: {name, email, phone}}`. **Vérifié par test réel de bout en bout** : `201`, driver créé avec succès (`Driver Alice1`, `uuid: 5ba69e4f-...`), puis correctement assigné à son Vendor via `assignDriverToVendor()` dans la foulée.

**Leçon** : tous les contrôleurs Fleetbase n'attendent pas la même convention d'enveloppe — `/vendors` et `/places` acceptent un payload plat, `/orders` et `/drivers` exigent une clé racine nommée d'après la ressource. Ne pas généraliser une convention d'un endpoint à l'autre sans test.

### 2.13 `GET /vendors/{uuid}` ignore le paramètre de chemin, renvoie tous les vendors

Découvert incidemment en cherchant le `public_id` d'un Vendor : `GET /int/v1/vendors/{uuid}` ne renvoie pas la ressource unique attendue mais `{"vendors": [...]}`, la liste complète des 7 vendors de la compagnie, avec la meta de pagination habituelle (`{"total": 7, ...}`) — quel que soit l'UUID demandé dans le chemin. Même famille de problème que §2.8 (paramètre silencieusement ignoré), mais ici sur un paramètre de **chemin** (`{uuid}`), pas une query string, et sur un endpoint de lecture simple plutôt qu'un filtre de liste explicite.

**Pas d'implication de sécurité directe pour nous** (les endpoints `/vendors` ne sont utilisés côté BFF que via le compte de service, jamais exposés en lecture par UUID au client final), mais **généralise encore plus largement la leçon du §2.8** : ne jamais supposer qu'un endpoint `GET /resource/{id}` retourne effectivement la ressource unique demandée sans le vérifier — y compris pour un simple `findRecord` en apparence standard. Non creusé plus loin (pas bloquant pour cette session), mais à garder en tête avant de construire une future fonctionnalité qui dépendrait de ce comportement.

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

---

## 5. Endpoints BFF pour l'authentification driver (28/07/2026)

Suite de session (reprise sur branche `claude/echango-delivery-bff-resume-zf24yd`, après merge de la PR précédente #4 dans `main`) : implémentation de la partie "reste ouvert" #3 du contexte de reprise — les endpoints BFF pour l'authentification de l'app conducteur Flutter (`driver_app/`), scaffoldée mais jamais branchée côté serveur. **Aucune instance Fleetbase locale n'était accessible dans ce sandbox** (pas de daemon Docker, comme d'habitude) — le code ci-dessous suit la méthode habituelle de lecture directe du code source Fleetbase, mais cette fois via le dépôt public GitHub (`fleetbase/fleetops`, `fleetbase/core-api`) plutôt que `docker exec` sur une instance locale, faute d'alternative. **Rien de ce qui suit n'a été testé par appel réel** — à revalider dès qu'une instance Fleetbase locale est disponible, avec la même discipline que le reste de ce journal (jamais supposer un comportement sans test, ici seulement approché par lecture de code).

### 5.1 ⚠️ Découverte structurante — le jeton push driver ne se pose pas sur `Driver`, mais sur un `UserDevice` séparé

`docs/specs_app_transporteur.md` §2.1/§11.1 supposait que le BFF écrirait le jeton FCM/APN directement sur l'enregistrement `Driver` Fleetbase correspondant. **Faux**, confirmé en lisant le modèle `Driver` (`fleetbase/fleetops`, `server/src/Models/Driver.php`) :
- `$fillable` du modèle `Driver` ne contient **aucune** colonne de jeton push (ni `fcm_token`, ni `device_token`, ni équivalent) — seulement `location`, `heading`, `bearing`, `altitude`, `speed`, `online`, `current_status`, etc.
- `Driver::routeNotificationForFcm()` et `routeNotificationForApn()` (les méthodes que Laravel appelle pour router une notification `ShouldQueue` comme `OrderPing` vers les canaux `FcmChannel`/`ApnChannel`) lisent en réalité une relation `devices(): HasMany` vers `\Fleetbase\Models\UserDevice::class`, **jointe sur `user_uuid`** (pas `driver_uuid`) — `UserDevice` est un modèle du package `core-api`, entièrement distinct de FleetOps.
- `UserDevice::$fillable` (lu dans `fleetbase/core-api`, `src/Models/UserDevice.php`) : `['user_uuid', 'platform', 'token', 'status']`.
- Route confirmée en lisant `core-api/src/routes.php` : `$router->fleetbaseRoutes('user-devices')`, sous le même groupe `int/v1` + middleware `fleetbase.protected` que le reste de l'API interne — donc `POST /int/v1/user-devices` par analogie avec le pattern déjà établi (`callFleetOps`).

**Conséquence pratique** : pour qu'un driver reçoive un `OrderPing` par push natif, le BFF doit connaître le `user_uuid` du `Driver` (pas seulement son `uuid`), et créer/mettre à jour un `UserDevice` avec ce `user_uuid`, pas patcher le `Driver`. Le `Driver.user_uuid` est déjà présent dans les réponses `GET /drivers` existantes (colonne `$fillable` standard) — capturé au moment du `registerDriver()` BFF (voir §5.2) et stocké dans `DriverAccount.fleetbaseUserUuid`.

**✅ VALIDÉ PAR TEST RÉEL (28/07/2026)**, via `scripts/test-driver-auth.sh` contre l'instance Fleetbase locale de l'utilisateur : le miroir `UserDevice` fonctionne de bout en bout. Les deux déductions risquées se sont révélées justes — **payload plat** (supposé par analogie avec `/vendors`/`/places`, qui utilisent la même macro générique `fleetbaseRoutes()` que `/user-devices`, contrairement à `/orders`/`/drivers` dont les contrôleurs custom exigent une enveloppe, cf. §2.5/§2.12) et **clé de réponse** (`user_device`, supposée par le pattern §2.4). L'analogie « même macro de routage ⇒ même forme de payload » tient donc, ce qui est un repère réutilisable pour les prochaines ressources `fleetbaseRoutes()`.

**Reste non vérifié — et le test du 28/07 ne l'a PAS tranché, contrairement à ce qu'il en avait l'air** : le comptage `user_devices` après plusieurs appels renvoie bien `1`, mais ça ne prouve pas que Fleetbase fait un upsert. C'est un **garde côté BFF** qui produit ce résultat : `registerDriverDeviceToken()` teste `if (driver.fleetbaseUserUuid && !record.fleetbaseUserDeviceUuid)` — une fois le miroir posé, tout appel ultérieur avec le même jeton **saute entièrement l'appel Fleetbase**. Le comportement natif de la route sur jeton répété reste donc inconnu. Il faudrait, pour le savoir, appeler `POST /int/v1/user-devices` deux fois directement (hors BFF).

En pratique le risque immédiat est couvert : le cas courant (Firebase renvoie le même jeton à chaque démarrage) ne crée pas de doublon, grâce à ce garde.

**✅ CORRIGÉ le 28/07/2026 (§6.10)** — le trou décrit ci-dessous est désormais traité et testé automatiquement.

**En revanche, ce test met au jour un vrai trou, lui non couvert** : quand Firebase **fait tourner** un jeton (réinstallation, effacement des données de l'app, restauration de sauvegarde), l'app enregistre un jeton neuf → nouvelle ligne `DriverDeviceToken` **et** nouveau `UserDevice` côté Fleetbase — mais **l'ancien `UserDevice` n'est jamais supprimé**. Or `Driver::routeNotificationForFcm()` renvoie *tous* les devices rattachés au `user_uuid` (§5.1) : Fleetbase continuera donc d'émettre vers des jetons morts indéfiniment, et les lignes mortes s'accumuleront. À traiter avec le module `transporteur` (piste : supprimer le `UserDevice` correspondant quand un jeton est remplacé, ou purger côté Fleetbase les devices du `user_uuid` avant d'en écrire un neuf). **Non corrigé à ce stade** — nécessite de connaître la route de suppression `user-devices`, non vérifiée.

### 5.2 Modèle de comptes driver — `DriverAccount`, provisioning manuel

Cohérent avec la décision déjà actée (`docs/specs_app_transporteur.md` §2.1, §13 Q8 : "commencer manuel") : contrairement à `MerchantAccount`/`FleetAccount` (dont l'enregistrement *crée* un `Vendor` Fleetbase), `DriverAccount.register()` ne crée **rien** côté Fleetbase — il **lie** un compte Echango (email/mot de passe) à un `Driver` Fleetbase déjà existant, provisionné manuellement par un opérateur au préalable (console Fleetbase, ou `POST /flotte/drivers` existant). Le endpoint `POST /auth/transporteur/register` prend un `fleetbaseDriverUuid` en entrée (communiqué au driver hors-bande par l'opérateur) et vérifie qu'il correspond à un vrai `Driver` avant de créer le compte — jamais fait confiance à l'UUID fourni sans vérification.

Cette vérification réutilise `getAllDrivers()` + un `find()` côté BFF plutôt qu'un `GET /drivers/{uuid}`, en cohérence directe avec **§2.13 ci-dessus** : `GET /drivers/{uuid}` ignore le paramètre de chemin et renvoie tous les drivers de la compagnie, donc un lookup par id accepterait silencieusement n'importe quel UUID (y compris une faute de frappe) sans jamais renvoyer 404 — seul un `find()` côté BFF sur la liste complète confirme réellement l'existence du driver.

### 5.3 Nouveaux endpoints (`AuthController`/`AuthService`, pas de nouveau module `transporteur` cette session)

- `POST /auth/transporteur/register` — voir §5.2
- `POST /auth/transporteur/login` — symétrique à `loginMerchant`/`loginFleet`
- `POST /auth/transporteur/device-token` — enregistre le jeton localement (nouveau modèle `DriverDeviceToken`, séparé de `DeviceToken` qui est câblé en dur sur `MerchantAccount`) puis tente le miroir Fleetbase `UserDevice` (§5.1) en best-effort : un échec du miroir est loggé mais ne fait pas échouer la requête (le polling REST reste fonctionnel même si le push natif est cassé)

Pas de nouveau module `transporteur/` créé cette session (structure `commercant`/`flotte`) — seuls les endpoints d'auth existent pour l'instant, mêmes dans `AuthController` que `merchant`/`flotte`. Le futur module `transporteur` (dashboard, liste/détail commande, accepter/rejeter adhoc, changement d'activité, POD, toggle en ligne/hors ligne, échec de livraison — cf. `docs/specs_app_transporteur.md` §3-5) reste à construire, volontairement laissé pour une session dédiée plutôt que fait à moitié sans capacité de test.

### 5.4 Limite d'environnement rencontrée — `prisma generate` bloqué par la politique de proxy sortant

Nouveau dans ce sandbox (pas rencontré dans les sessions précédentes, qui avaient peut-être un accès différent) : `npx prisma generate` échoue systématiquement, y compris avec `PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING=1` — `binaries.prisma.sh` est bloqué par la politique du proxy sortant (`403` sur le `CONNECT`, confirmé via `$HTTPS_PROXY/__agentproxy/status`), pas seulement absent de la liste blanche par erreur temporaire. Le client Prisma présent dans `node_modules/.prisma/client` est donc le template générique non généré (0 modèle, y compris `MerchantAccount`/`FleetAccount` qui existaient déjà avant cette session) — **jamais généré avec succès dans ce sandbox**, avant même les modèles `DriverAccount`/`DriverDeviceToken` ajoutés ici. `npx nest build` compile néanmoins sans erreur (le client non généré expose apparemment un typage assez permissif pour ne pas faire échouer `tsc`), donc ce n'est pas bloquant pour committer/pousser du code, mais ça signifie qu'aucune vérification de type stricte contre le schéma Prisma réel n'a eu lieu ici — à garder en tête, et à re-générer/tester dans l'environnement Docker de l'utilisateur avant de faire confiance à ce code en pratique.


### 5.5 Écart app Flutter ↔ API réelle — le scaffolding avait été écrit contre une API imaginée

Constaté en préparant les tests (28/07/2026) : `driver_app/` a été scaffoldé le 27/07 **avant** que le moindre endpoint BFF n'existe, donc contre une API supposée. La comparaison ligne à ligne de `driver_app/lib/services/bff_api_client.dart` avec le BFF réel donne un écart quasi total — utile à garder en tête comme leçon de méthode : **scaffolder un client contre une API pas encore écrite produit du code qui a l'air fini mais n'est branché sur rien**.

| L'app appelait | Réalité serveur |
|---|---|
| `/auth/login` | `/auth/transporteur/login` (préfixe `transporteur`) |
| réponse `data.data.access_token` | `{token, user:{...}}` — à plat, clé `token` |
| `auth_state.dart` lisait `response['data']['driver']` | clé `user` |
| `baseUrl = localhost:3000/api/v1` | port **3001**, aucun préfixe global (`main.ts`) |
| `/auth/login-phone`, `/auth/verify-otp`, `/auth/logout` | n'existent pas |
| `/driver/profile`, `/driver/location`, `/driver/status` | n'existent pas |
| `/orders`, `/orders/:id/accept|start|complete|failure` | n'existent pas |
| *(rien)* | `/auth/transporteur/device-token` existait mais n'était jamais appelé — le jeton FCM était récupéré puis jeté |

Corrigé cette session : chemins/formes de la tranche auth alignés sur le serveur réel, méthode `registerDeviceToken()` ajoutée, tout le reste annoté `NON IMPLÉMENTÉ CÔTÉ BFF` en commentaire de code plutôt que supprimé (l'OTP et le login social sont au périmètre spec §2, seul leur arbitrage MVP/V2 est ouvert — ce n'est pas du code mort). Le `README.md` de `driver_app` a été corrigé de la même façon : il annonçait comme fonctionnelles des fonctionnalités sans contrepartie serveur.

### 5.6 Script de validation `scripts/test-driver-auth.sh`

Écrit pour valider au curl la tranche auth avant de brancher l'app — le diagnostic d'un échec est bien plus lisible en curl qu'à travers le client Flutter. Couvre : BFF joignable, `register`, `login`, `device-token`, et **le rejet d'un UUID Fleetbase inconnu** (test qui compte autant que les autres : cf. §2.13, `GET /drivers/{uuid}` renvoie tous les drivers au lieu d'un 404, donc une vérification naïve accepterait n'importe quel UUID — c'est le contournement `getAllDrivers()` + `find()` qu'on valide là).

Le script distingue explicitement « jeton enregistré localement » de « miroir Fleetbase `UserDevice` réussi », parce que le miroir est best-effort côté BFF : **un 2xx ne prouve pas que le push natif fonctionnera**. Il rappelle en sortie les deux vérifications que seule une inspection manuelle peut faire (ligne `user_devices` réellement créée, et upsert vs doublon sur un 2e appel avec le même token).

Non exécuté dans le sandbox (ni Docker ni Fleetbase) — seules la syntaxe et les branches d'erreur y ont été vérifiées. **Exécuté avec succès par l'utilisateur le 28/07/2026 : les 5 étapes passent au vert**, y compris le miroir `UserDevice` (§5.1).

**Trois frictions rencontrées avant d'y arriver, toutes corrigées dans le script ou le BFF** — elles valent d'être notées, ce sont des pièges d'installation qui se reproduiront :

1. **`public_id` vs `uuid`** : la console Fleetbase affiche `driver_al95c9vcat`, le BFF compare sur le `uuid`. Le register répondait « UUID inconnu » — exact mais trompeur. Le script détecte maintenant le préfixe `driver_` et donne la commande de résolution.
2. **Identifiants de base croisés** : réflexe naturel d'essayer `bff_user`/`bff_password` sur le MySQL de Fleetbase. Ce sont ceux du **Postgres du BFF** — deux bases, deux moteurs, deux conteneurs. Les commandes du script passent désormais par `php artisan tinker`, qui utilise la connexion configurée de Fleetbase et ne demande aucun mot de passe.
3. **`prisma generate` oublié** ⇒ `TypeError: Cannot read properties of undefined (reading 'findUnique')`, sorti en **500 nu**. Deux causes cumulées : le client Prisma n'avait jamais été régénéré depuis l'ajout des modèles (§5.4 — impossible dans le sandbox), et surtout les vérifications d'unicité de `registerDriver()` étaient placées **hors du `try`**, donc hors de toute gestion d'erreur. `HttpExceptionFilter` étant `@Catch(HttpException)`, une `TypeError` brute passait à travers sans rien d'exploitable. Corrigé : vérifications déplacées dans le `try`, et les deux pannes d'installation probables (P2021 table absente, client obsolète) mappées vers un message qui nomme les commandes à lancer.

**Leçon de méthode** : le point 3 est le plus instructif. Placer une requête base hors du bloc de gestion d'erreur ne se voit pas tant que la base répond ; ça ne se paie qu'au premier démarrage à froid, exactement là où le diagnostic doit être le plus lisible. À vérifier par réflexe dans les endpoints du futur module `transporteur`.

### 5.7 Tableau de suivi des tests — tranche auth driver (28/07/2026)

Bilan de ce qui est **réellement prouvé par exécution**, par opposition à ce qui est seulement écrit ou déduit. Colonne « preuve » = comment on le sait, pour éviter de reclasser plus tard une déduction en test.

| Élément | Statut | Preuve |
|---|---|---|
| `POST /auth/transporteur/register` | ✅ testé | `test-driver-auth.sh`, compte créé et lié |
| Vérification de l'existence du Driver Fleetbase | ✅ testé | UUID bidon rejeté (contourne §2.13) |
| `POST /auth/transporteur/login` | ✅ testé | JWT obtenu et réutilisé sur la requête suivante |
| `POST /auth/transporteur/device-token` | ✅ testé | enregistrement créé côté BFF |
| Miroir Fleetbase `UserDevice` | ✅ testé | ligne `user_devices` présente, uuid remonté |
| Payload plat sur `POST /int/v1/user-devices` | ✅ testé | l'appel réussit → analogie `fleetbaseRoutes()` confirmée |
| Clé de réponse `user_device` | ✅ testé | `fleetbaseUserDeviceUuid` renseigné en base |
| Idempotence du rappel de jeton, **côté BFF** | ✅ testé | 2 appels → même `DriverDeviceToken` |
| Upsert vs doublon, **côté Fleetbase** | ❌ **non testé** | le garde BFF saute l'appel, cf. §5.1 — `count=1` ne prouve rien |
| Nettoyage d'un jeton **remplacé** (rotation Firebase) | ❌ **trou identifié** | non implémenté, §5.1 |
| Réception réelle d'un push par un appareil | ❌ non testé | demande un vrai appareil + projet Firebase configuré |
| Module `transporteur` métier | ❌ non écrit | bloquant pour tester l'app au-delà du login |

**Ce que ça change pour la suite** : la couche d'identité driver (compte Echango ↔ `Driver` Fleetbase ↔ `UserDevice`) est solide et vérifiée, donc le module `transporteur` peut être construit dessus sans réserve. Les deux lignes rouges du milieu du tableau ne bloquent pas ce développement, mais doivent être traitées **avant** toute mise en service réelle : des jetons morts jamais purgés dégradent silencieusement le dispatch, sans erreur visible nulle part.

---

## 6. Module `transporteur` — implémentation (28/07/2026)

Construit après validation de la tranche auth (§5.7). Méthode identique au reste de ce journal : **chaque route vérifiée dans le code source Fleetbase avant d'écrire**, cette fois par lecture du dépôt public (`fleetbase/fleetops`, `fleetbase/core-api`) faute d'instance dans le sandbox.

### 6.1 ⚠️ Découverte structurante — les opérations driver n'existent pas sur `int/v1`

Le BFF n'avait jusqu'ici parlé qu'à `int/v1` (middleware `fleetbase.protected`, token Sanctum — §2.1/§2.2). **Aucune** des opérations dont l'app driver a besoin n'y est déclarée. En lisant `server/src/routes.php` :

| Opération | Route réelle | Groupe |
|---|---|---|
| Mise à jour d'activité | `POST /v1/orders/{id}/update-activity` | `v1` |
| Démarrer une commande | `POST /v1/orders/{id}/start` | `v1` |
| Terminer une commande | `POST /v1/orders/{id}/complete` | `v1` |
| Preuve photo / signature / QR | `POST /v1/orders/{id}/capture-{photo,signature,qr}` | `v1` |
| Position GPS | `POST /v1/drivers/{id}/track` | `v1` |
| Bascule en ligne | `POST /v1/drivers/{id}/toggle-online` | `v1` |

`int/v1` ne porte que les variantes *bulk*/dispatch pensées pour la console (`bulk-assign-driver`, `bulk-dispatch`…). Il fallait donc ouvrir un second canal vers l'API publique `v1` : `FleetbaseApiClient.callFleetOpsPublic()`.

### 6.2 ⚠️ Correction de §2.2 — le token Sanctum fonctionne AUSSI sur `v1`

§2.2 concluait que la clé `flb_live_` « ne sert (presque) à rien » et que les deux schémas d'auth étaient séparés. **La conclusion était trop étroite.** En lisant `CoreServiceProvider`, le groupe `v1` utilise l'alias `fleetbase.api` → `AuthenticateOnceWithBasicAuth`. Ce nom est trompeur : la classe **ne fait pas de Basic Auth**. Son `handle()` lit `$request->bearerToken()` puis tente **`PersonalAccessToken::findToken()` en premier**, et ne se rabat sur une recherche `ApiCredential` (clé `flb_live_`) que si ça échoue.

**Conséquence pratique** : un seul token Sanctum couvre tout — `int/v1` **et** `v1`. Aucun second credential à provisionner, aucune variable d'environnement supplémentaire. La formulation exacte est : *les deux credentials marchent sur `v1`, seul Sanctum marche sur `int/v1`*.

**Leçon** : un nom de classe n'est pas une spécification. `AuthenticateOnceWithBasicAuth` aurait justifié de conclure « il faut du Basic Auth » sans lire le corps de la méthode — c'était faux, et ça aurait conduit à provisionner un credential inutile.

### 6.3 `assign` attend un `public_id`, pas un `uuid`

`OrderController@startOrder` valide son paramètre `assign` comme un **public_id** (préfixe `driver_` obligatoire) — le seul endroit de l'API qui refuse l'uuid utilisé partout ailleurs. Ironique vu le piège inverse rencontré en §5.6. D'où la colonne `DriverAccount.fleetbaseDriverPublicId`, remplie à l'inscription et rattrapée à la volée pour les comptes antérieurs (`getDriverPublicId()`).

### 6.4 Anti-IDOR — filtrage systématiquement côté BFF

`GET /transporteur/commandes` récupère **toutes** les commandes de la compagnie puis filtre sur `driver_assigned_uuid` **dans le BFF**. Ce n'est pas de la prudence excessive : §2.8 a établi que Fleetbase **ignore silencieusement** les filtres non supportés sur `/orders` et renvoie la collection entière. Un filtre passé en paramètre aurait donc *l'air* de marcher tout en exposant les commandes de toute l'organisation à chaque driver.

Même discipline sur l'accès unitaire : `getOrder()` autorise soit une commande assignée au driver, soit une commande adhoc non réclamée (opportunité légitime), et répond **404** — pas 403 — dans tous les autres cas : un driver n'a pas à apprendre qu'un identifiant existe.

Troisième garde, souvent oublié : les 3 personas partagent le même émetteur JWT, donc un token commerçant est *structurellement* valide sur ces routes. Chaque endpoint vérifie `req.user.type === 'transporteur'`.

### 6.5 Échec de livraison — stocké côté BFF, faute de statut natif confirmé

`docs/specs_app_transporteur.md` §4.3 laissait ouvert l'existence d'un statut « failed » natif par étape. Rien dans les routes ni dans le modèle `Activity` ne permet de l'affirmer, et aucun test n'a pu être mené. Décision : le modèle `DeliveryFailure` (BFF) est source de vérité pour l'échec lui-même ; ce qui est poussé vers Fleetbase est la trace visible par l'opérateur — la photo en `Proof`, avec la raison dans les `remarks`.

L'upload photo est **best-effort délibérément** : un driver devant une porte close, en mauvaise couverture, doit pouvoir déclarer l'échec même si l'envoi de l'image échoue. Perdre le signalement pour cause d'image serait le pire compromis possible.

### 6.6 État de vérification

| Élément | Statut | Preuve |
|---|---|---|
| Routes `v1` existent et leurs payloads | ✅ vérifié | lecture `routes.php` + `{Order,Driver}Controller` |
| Sanctum accepté sur `v1` | ✅ vérifié | lecture `AuthenticateOnceWithBasicAuth::handle()` |
| `assign` = public_id | ✅ vérifié | validation du contrôleur |
| Compilation du module | ✅ vérifié | `nest build` |
| **Tous les appels réels** | ✅ testé le 28/07 | voir §6.8 |
| Forme exacte de l'objet `Activity` | ✅ testé le 28/07 | route dédiée `next-activity`, §6.9 |
| Upload photo base64 | ✅ testé le 28/07 | après contournement du bug amont, §6.12/§6.17 |
| Filtrage anti-IDOR en conditions réelles | ✅ testé le 28/07 | commande d'un autre driver → 404 (§6.8) |

`scripts/test-transporteur-module.sh` couvre profil, statut, position, liste, anti-IDOR, rejet de token non-driver, absence de token et échec de livraison. Accepter/démarrer/activité en sont **volontairement absents** : ils modifient un état difficile à remettre en place, à tester à la main sur une commande jetable.

### 6.7 ⚠️ Correction par test réel — l'API `v1` s'adresse par `public_id`, jamais par `uuid`

Premier test réel du module (28/07/2026) : `POST /transporteur/statut` échoue. Log Fleetbase sans ambiguïté :

```
404 POST /v1/drivers/eec8c72d-fd1e-4416-b516-69b584a1a65b/toggle-online
   - {"error":"Driver resource not found."}
```

Le driver existe pourtant, et `php artisan route:list --path=toggle-online` confirme que la route est bien `v1/drivers/{id}/toggle-online`. Deux hypothèses étaient en lice : (a) perte du contexte d'organisation, `fleetbase.api` n'incluant pas `SetupFleetbaseSession` contrairement à `fleetbase.protected` ; (b) mauvais identifiant.

**C'est (b)**, tranché en lisant `findRecordOrFail()` (core-api, `HasApiModelBehavior`) :

```php
$query->where('public_id', $id);
if ($hasInternalId) { $query->orWhere('internal_id', $id); }
```

**Le `uuid` n'est jamais matché.** L'API publique `v1` adresse ses ressources par `public_id` (`driver_xxx`, `order_xxx`) exclusivement — alors que `int/v1` travaille en uuid. Ma lecture initiale (« findRecordOrFail supporte les deux ») était **fausse** : elle venait d'un résumé de la méthode, pas de son corps.

L'hypothèse (a) est écartée au passage, et c'est utile : le scope compagnie est conditionné à `session('company')`, vide sans `SetupFleetbaseSession`, donc **aucune** contrainte n'est appliquée. La conclusion de §6.2 (un seul token Sanctum suffit) tient toujours.

**Portée de l'erreur** : elle ne touchait pas que `toggle-online` mais **toutes** les routes `v1` du module — position, start, complete, update-activity, capture-photo. Elles auraient toutes échoué en 404 l'une après l'autre.

**Correction** : `resolveOrder()` retrouve la commande par uuid *ou* public_id dans la liste de la compagnie, et toute mutation `v1` passe par `orderPublicId(order)` ; côté driver, `getDriverPublicId()` était déjà là pour `assign` et sert maintenant à `track`/`toggle-online`. Les paramètres du client sont renommés `orderPublicId`/`driverPublicId` pour que l'exigence soit lisible à l'appel plutôt qu'enfouie dans un commentaire.

**Leçon de méthode, la deuxième en deux sections** : §6.2 rappelait qu'un nom de classe n'est pas une spécification ; §6.7 rappelle qu'un **résumé** de méthode n'en est pas une non plus. Les deux erreurs ont la même racine — avoir accepté une description au lieu du corps de la fonction. Sur les points qui décident d'une implémentation, lire le code, pas ce qu'on en dit.

### 6.8 Résultats du test réel (28/07/2026)

`scripts/test-transporteur-module.sh` après la correction §6.7 :

| Contrôle | Résultat |
|---|---|
| `GET /transporteur/profil` | ✅ |
| `POST /transporteur/statut` (toggle-online) | ✅ |
| `POST /transporteur/position` (track) | ✅ |
| `GET /transporteur/commandes` (3 catégories) | ✅ (0 active, 1 adhoc) |
| **Anti-IDOR — commande d'un autre driver** | ✅ **404**, sur une vraie commande assignée ailleurs |
| Requête sans token | ✅ 401 |

**Le résultat le plus important est l'anti-IDOR**, testé en conditions réelles : une commande réellement assignée à un autre driver, existante en base, est refusée. C'est la vérification qui donne sa valeur au filtrage BFF de §6.4 — sans elle, on n'aurait su qu'une chose, à savoir que le code *a l'air* de filtrer.

**Deux contrôles initialement non concluants, désormais couverts** :

1. **Rejet d'un token valide mais du mauvais persona** — sautait faute de compte commerçant. Le script **forge** maintenant un JWT `type:"merchant"` signé avec le vrai `JWT_SECRET` : c'est exactement l'objet à éprouver (un jeton légitime, du mauvais type), sans créer de Vendor/Contact parasite côté Fleetbase comme le ferait une inscription commerçant. Un 401 est distingué d'un 403 et signalé comme **non concluant** (secret désynchronisé ⇒ le contrôle de type n'a jamais été atteint), plutôt que compté comme un succès.
2. **Échec de livraison** — demandait une commande assignée, il n'y en avait aucune. Ajout d'un mode opt-in `WITH_MUTATIONS=1` qui réclame une commande adhoc disponible puis déroule accepter → échec. **Jamais par défaut** : accepter assigne *et* démarre la commande, un état que le script ne sait pas défaire.

**Résultats complémentaires en mode `WITH_MUTATIONS=1`** (même session) :

| Contrôle | Résultat |
|---|---|
| Rejet d'un token valide non-driver | ✅ **403** — le contrôle de type fonctionne |
| `POST .../accepter` (réclamer une adhoc) | ✅ commande `order_4ioz8zuyve` réclamée |
| `POST .../echec` (échec de livraison) | ✅ |

L'acceptation d'une commande adhoc est donc validée de bout en bout : le driver est assigné et la commande démarrée en un seul appel, conformément à §4.2 de la spec. À noter que le script a bien envoyé un **public_id** (`order_4ioz8zuyve`) — la correction §6.7 est confirmée en conditions réelles, pas seulement en lecture de code.

**Reste non testé** : `demarrer` (redondant avec `accepter` pour une adhoc, mais utile pour une commande pré-assignée), `activite`, l'upload photo base64, et surtout **la forme exacte de l'objet `Activity`** — dernier inconnu bloquant pour l'écran détail de l'app. `scripts/inspect-order-activity.sh` a été écrit pour la relever sur une vraie commande assignée, en cherchant les clés candidates (`config`, `activities`, `next_activity`, `tracker_data`…) et, si aucune n'est présente, en orientant vers l'`OrderConfig` — auquel cas le BFF devra exposer ce flow à l'app, ce qu'aucun endpoint ne fait aujourd'hui.

### 6.9 Forme de l'objet `Activity` — relevée sur une vraie commande (28/07/2026)

Dernier inconnu bloquant de §6.8, levé avec `scripts/inspect-order-activity.sh` sur la commande `order_4ioz8zuyve`.

**Le détail de commande ne contient aucune donnée d'activité.** Clés réellement renvoyées : `status`, `latest_status`, `latest_status_code`, `dispatched`, `started_at`, `order_config_uuid`, `payload`, `tracking`… mais ni `config`, ni `activities`, ni `next_activity`, ni `tracker_data` (null). Impossible, donc, de récupérer l'objet `Activity` depuis le détail comme le supposait le commentaire du scaffolding.

**La route dédiée existe** : `GET /v1/orders/{id}/next-activity` → `OrderController@getNextActivity`. Elle résout le flow de l'`OrderConfig` contre l'état courant de la commande et renvoie des objets `Activity` directement réutilisables :

```json
[{ "code": "...", "status": "...", "details": "...", "complete": bool,
   "require_pod": bool, "pod_method": "...",
   "_resolved_status": "...", "_resolved_details": "..." }]
```

Elle accepte un paramètre `waypoint` pour cibler une étape précise d'une tournée multi-arrêts.

**Ce que ça évite** : reconstruire la machine à états côté BFF ou côté app à partir de `order_configs.flow`. C'eût été à la fois du travail inutile et une source de divergence — deux implémentations d'un même flow finissent toujours par ne plus concorder.

**Bénéfice secondaire, non anticipé** : le drapeau `require_pod`/`pod_method` porté par chaque activité est précisément ce dont l'app a besoin pour savoir quand router vers l'écran de preuve de livraison (`docs/specs_app_transporteur.md` §5, « quand la config de la commande l'exige »). Cette information n'a donc pas à être déduite ailleurs.

**Ajouté** : `GET /transporteur/commandes/:id/activites-suivantes` (BFF) et `getNextActivities()` (client Flutter), avec les mêmes contrôles d'appartenance que le reste du module. Le script de test affiche les codes proposés et ceux exigeant une preuve.

### 6.10 Purge des jetons push périmés — le trou de §5.1 refermé

§5.1 avait identifié, sans le corriger, le seul défaut de cette tranche capable de **dégrader la production en silence** : à chaque rotation de jeton Firebase (réinstallation, effacement des données, restauration de sauvegarde), l'app enregistre un jeton neuf et l'ancien `UserDevice` reste en base. Or `Driver::routeNotificationForFcm()` renvoie **tous** les devices rattachés au `user_uuid` — Fleetbase émet donc indéfiniment vers des appareils morts. Aucune exception, aucun log, aucune alerte : juste des notifications qui n'arrivent pas.

**Correction** : `registerDriverDeviceToken()` retire d'abord les autres jetons actifs du driver — suppression du `UserDevice` côté Fleetbase (`DELETE /int/v1/user-devices/{uuid}`, route confirmée comme faisant partie de ce que génère la macro `fleetbaseRoutes()`, cf. `RESTRegistrar`), puis passage à `active:false` côté BFF.

La suppression est **best-effort à dessein** : si l'ancien device ne peut pas être supprimé, il ne faut surtout pas bloquer l'enregistrement du nouveau — le driver cesserait alors de recevoir quoi que ce soit. Un jeton mort de trop est un moindre mal comparé à un driver injoignable.

**Testé automatiquement** : `scripts/test-driver-auth.sh` enregistre désormais un second jeton (simulant la rotation) puis **compte les `user_devices` portant l'ancien** — attendu `0`. C'est le seul moyen de vérifier la purge : la réponse du BFF ne dit rien de l'état côté Fleetbase, comme l'avait montré la fausse conclusion de §5.1.

### 6.11 Couverture des deux dernières écritures non testées

Ajoutées à `test-transporteur-module.sh` sous `WITH_MUTATIONS=1` :

- **`POST .../activite`** — renvoie l'objet `Activity` complet tel que reçu de `activites-suivantes` (§6.9) et vérifie que la transition est acceptée. Sur la commande de test, la seule transition proposée était `enroute`, sans preuve exigée.
- **`POST .../preuve`** — envoie un PNG 1×1 transparent encodé en base64, le plus petit fichier valide possible. Valide que le contrôleur accepte bien du base64 plutôt que du multipart, hypothèse retenue en §6.1 pour éviter d'introduire du multipart dans le BFF.

### 6.12 ⚠️ Bug amont Fleetbase — tout upload de preuve est cassé hors S3

Constaté au premier essai réel de `POST .../preuve` (28/07/2026) :

```
500 POST /v1/orders/order_4ioz8zuyve/capture-photo
storeProofPhoto(): Argument #4 ($bucket) must be of type string, null given
```

Cause, dans `OrderController@capturePhoto` :

```php
$disk   = $request->input('disk', config('filesystems.default'));
$bucket = $request->input(
    "filesystems.disks.{$disk}.bucket",       // ← lit la REQUÊTE, devrait être config()
    config('filesystems.disks.s3.bucket')      // ← repli systématique : null sans S3
);
```

La première ligne est manifestement une faute de frappe amont : elle interroge `$request->input()` avec une clé de configuration. Cette clé n'étant jamais présente dans une requête, le repli s'applique **toujours** — et vaut `null` sur une installation sans S3. Comme `storeProofPhoto()` type ce paramètre `string`, l'appel meurt en `TypeError`.

**Portée** : ce n'est pas propre à notre BFF. **Tout** upload de preuve échoue sur une installation Fleetbase non-S3, y compris depuis Navigator ou la console. Ça concerne la POD (§5 de la spec app) *et* la photo d'échec de livraison (§4.3) — les deux passent par ce contrôleur.

**Contournement retenu** : le bug est son propre remède. La valeur étant lue depuis la requête, on l'y place — le BFF envoie `disk` et l'objet imbriqué `filesystems.disks.<disk>.bucket`. Les deux sont surchargeables par `FLEETBASE_PROOF_DISK`/`FLEETBASE_PROOF_BUCKET` pour un déploiement S3 réel.

C'est un contournement, pas une correction : il faudra le retirer si l'amont corrige la ligne. **À signaler en amont** (issue Fleetbase) — non fait à ce stade.

### 6.13 `warn` non défini dans `test-driver-auth.sh`

Le test de rotation de jeton (§6.10) appelait `warn`, fonction définie dans `test-transporteur-module.sh` mais pas dans celui-ci. Le test tournait donc bien, mais s'écrasait au moment d'afficher son résultat — `warn: command not found` — et n'a **jamais rien validé**. Fonction ajoutée, et le bloc replacé avant le résumé final plutôt qu'après, où il était inséré par erreur.

Rappel utile : `set -euo pipefail` n'attrape pas ce cas comme on l'espérerait ; la commande absente fait bien échouer la ligne, mais après que le résumé « tout est validé » a déjà été affiché — d'où une sortie trompeusement rassurante.

### 6.14 Purge des jetons — la suppression échoue aussi sur l'identifiant

Le test de rotation (§6.10), enfin exécutable après la correction de §6.13, échoue : `1 ancien UserDevice subsiste`. La purge ne fonctionne donc pas.

Diagnostic le plus probable — **la même leçon qu'au §6.7** : le miroir n'a capturé qu'un `uuid`, or `DELETE /int/v1/user-devices/{id}` passe vraisemblablement par la même résolution `findRecordOrFail()`, qui matche `public_id` et jamais `uuid`. Deuxième fois que cet écart mord au même endroit.

**Correction** : plutôt que de deviner quel identifiant la route accepte, `findUserDeviceByToken()` récupère l'enregistrement complet et la suppression essaie le `public_id` d'abord, l'`uuid` en repli. Le comportement best-effort est conservé — échouer à supprimer un ancien device ne doit jamais empêcher d'enregistrer le nouveau, sous peine de rendre le driver injoignable.

**Hypothèse démentie par le test (28/07/2026)** — le log est sans appel :

```
404 DELETE /int/v1/user-devices/user_device_clo2hpiu10 - {"message":"User Device not found"}
[AuthService] Retired 1 stale push token(s)
```

Le `public_id` échoue, le repli en **uuid réussit** (aucun warning « Could not delete » n'est émis). C'est donc **l'exact inverse du §6.7** : l'API publique `v1` résout par `public_id`, cette route interne `int/v1` par `uuid`. **La résolution d'enregistrement n'est pas uniforme dans Fleetbase** — il n'existe pas de règle générale à appliquer, seulement des routes à vérifier une par une. Mon code d'origine était correct ; c'est le diagnostic qui était faux.

Ordre inversé en conséquence (uuid d'abord, recherche du public_id seulement en repli), pour éviter un aller-retour 404 systématique à chaque rotation.

**Le voyant orange du test était par ailleurs un faux positif** : le script comptait un jeton constant partagé entre exécutions, dont les `UserDevice` s'étaient accumulés au fil des runs *antérieurs à la purge*. Il mesurait donc un reliquat historique, pas l'effet de la rotation qu'il venait de déclencher. Corrigé : chaque exécution utilise désormais un jeton unique, ce qui rend l'assertion auto-suffisante.

**Leçon** : un test qui s'appuie sur un identifiant partagé entre exécutions mesure l'histoire du jeu de données, pas le comportement qu'il prétend vérifier. Le symptôme est trompeur dans les deux sens — il aurait aussi bien pu masquer une vraie régression.

### 6.15 `scripts/seed-test-order.sh` — commandes de test jetables

Problème pratique apparu à l'usage : chaque run en `WITH_MUTATIONS=1` **consomme** la commande de test (accepter → activite → `completed`), donc le run suivant n'a plus rien à exercer — `preuve` et `echec` redeviennent non testés. C'est ce qui s'est produit au 3e run.

Le script crée une commande adhoc jetable et la dispatche. Il ne tente pas d'inventer client/lieux/config — ce qui supposerait de recréer une arborescence entière — mais **recopie ceux d'une commande existante**, ce qui le rend indépendant du jeu de données. Prérequis : au moins une commande déjà en base.

**Non testé** (ni Docker ni Fleetbase dans le sandbox). Écrit à partir de formes déjà établies : enveloppe `{order:{…}}` (§2.5) et adressage `v1` par `public_id` (§6.7). Rappelle en sortie que le driver doit être **en ligne et positionné** pour qu'une adhoc lui parvienne — le matching est géospatial (§3.2).

### 6.16 Le seed échouait aussi sur un identifiant — l'API `v1` n'expose pas d'uuid

Premier essai de `seed-test-order.sh` : `pickup=` et `dropoff=` vides alors que la commande modèle est bien formée. Cause visible dans la réponse — l'API `v1` n'expose **que** des identifiants publics, sous la clé `id` :

```json
"customer": { "id": "contact_0c7hx0i0lu", "customer_id": "customer_0c7hx0i0lu", … }
```

Aucun champ `uuid` nulle part. Or la création de commande passe par `int/v1`, qui exige des `*_uuid`. Le script traduit donc désormais `public_id → uuid` via la liste des places.

C'est le troisième incident d'identifiant de cette session (§6.7, §6.14, §6.16). Le motif est constant et mérite d'être retenu : **`int/v1` parle uuid, `v1` parle public_id, et traverser la frontière impose une traduction explicite.** Le §6.14 montre que l'inverse existe aussi ponctuellement — d'où la règle pratique : ne jamais présumer, vérifier route par route.

### 6.17 Le contournement du bug de bucket était lui-même neutralisé par un middleware

Deuxième échec identique de `POST .../preuve` malgré le contournement de §6.12. Cause visible **dans la pile de la trace elle-même**, qu'il aurait fallu lire plus attentivement la première fois :

```
Illuminate\Foundation\Http\Middleware\ConvertEmptyStringsToNull
```

Le contournement envoyait `bucket: ""`. Ce middleware, standard dans Laravel, convertit toute chaîne vide en `null` **avant** que le contrôleur ne la lise — reproduisant exactement le `TypeError` qu'on cherchait à éviter. Correction : valeur non vide par défaut (`fleetbase`), ignorée de toute façon par le disque `local`.

**Leçon** : la trace contenait déjà la réponse. Sur une pile de middlewares Laravel, ce qui transforme la requête entre le client et le contrôleur fait partie du contrat, au même titre que la signature de la méthode.

### 6.18 Deux faux négatifs de test corrigés

**Rotation de jeton** — restait orange même avec un jeton unique par exécution (§6.14). Les modèles Fleetbase utilisent `SoftDeletes` : la purge fonctionne, mais `DB::table('user_devices')->count()` court-circuite le scope global d'Eloquent et compte les lignes supprimées. Ajout de `whereNull('deleted_at')`. Le test mesurait la présence de la ligne, pas sa suppression logique.

**Dispatch du seed** — `{"error":"Order has already been dispatched!"}` traité comme un échec, alors qu'une commande créée avec `adhoc:true` est **déjà dispatchée par Fleetbase à la création**. La preuve était dans le run suivant : la commande apparaissait bien comme opportunité adhoc et a pu être acceptée. Refus reclassé en succès.

Ces deux cas, plus §6.14, forment un motif : **trois faux signaux de suite venaient de l'outil de mesure, pas du code mesuré.** Un test qui échoue mérite la même suspicion qu'un test qui passe.

### 6.19 État final de la tranche transporteur (28/07/2026)

Trois scripts au vert intégral. Ce qui est **prouvé par exécution réelle** :

| Domaine | Couverture |
|---|---|
| Authentification driver | register (+ rejet d'UUID inconnu), login, device-token |
| Jetons push | miroir `UserDevice`, idempotence, **purge à la rotation** |
| Identité & état driver | profil, position GPS, bascule en ligne |
| Commandes | liste (3 catégories), détail, accepter une adhoc |
| Machine à états | transitions disponibles, application d'une transition |
| Preuve & incidents | upload photo base64, échec de livraison |
| Sécurité | isolation entre drivers (404 sur commande d'autrui), rejet du mauvais persona (403), rejet sans token (401) |

**Non couvert, et assumé comme tel** :

- `demarrer` sur une commande **pré-assignée** — `accepter` couvre le chemin adhoc, mais c'est un code path distinct
- **réception réelle d'un push** par un appareil — demande un téléphone et un projet Firebase configuré ; le pipeline serveur est validé jusqu'à l'envoi (§3.2), pas au-delà
- **l'app Flutter n'a jamais été compilée** — aucun toolchain Flutter dans le sandbox ; le client est aligné sur les routes réelles, mais `flutter analyze` reste à passer côté Windows

**Dette assumée à retirer un jour** : le contournement du bug amont §6.12 (bucket lu depuis la requête). Il doit sauter si Fleetbase corrige la ligne — sinon il masquera une configuration S3 réellement invalide.

**Sur la méthode** : cette tranche a produit six corrections d'hypothèses fausses (§6.2, §6.7, §6.9, §6.14, §6.17, §6.18). Toutes venaient d'avoir accepté une description — nom de classe, résumé de méthode, message d'erreur, sortie de test — à la place du code ou de la donnée elle-même. Le taux de réussite du raisonnement à partir du code source est resté élevé ; c'est le raisonnement à partir de *ce qu'on dit du* code source qui a systématiquement échoué.

---

## 7. Alignement de l'app Flutter sur l'API vérifiée (28/07/2026)

Le serveur étant validé (§6.19), revue du code Dart contre les formes réelles. `driver_app/` ayant été scaffoldé avant l'existence des endpoints (§5.5), le modèle de données était lui aussi écrit contre une API imaginée. **Aucune compilation possible dans le sandbox** (pas de toolchain Flutter) : ce qui suit est une revue de cohérence, pas une validation.

### 7.1 `Order.fromJson` aurait planté au premier chargement

Comparaison avec les clés réellement renvoyées (relevées au §6.9) :

| Attendu par le modèle | Clé réelle |
|---|---|
| `facilitator_id` (**requis non-nul**) | `facilitator_uuid`, souvent absent |
| `customer_id` | `customer_uuid` |
| `driver_id` | `driver_assigned_uuid` |
| `pickup_place` / `dropoff_place` | `payload.pickup` / `payload.dropoff` |
| `payload.type` | `type`, à la racine |
| `notes`, `distance`, `estimated_duration`, `proof_url` | n'existent pas |

Le premier écart suffisait à faire échouer tout chargement de liste : `json['facilitator_id'] as String` sur une clé absente lève une `TypeError`, et une seule commande mal formée faisait tomber l'écran entier. Corrigé, et les désérialiseurs rendus tolérants par principe — une commande inattendue doit être ignorable, pas fatale.

`Place.fromJson` avait le même défaut sur `location.coordinates` (déréférencement direct), plus un piège classique : Fleetbase renvoie du **GeoJSON**, donc `[longitude, latitude]` — ordre inverse de l'usage courant. Le scaffolding l'avait bien vu ; c'est conservé et désormais commenté.

### 7.2 Prédicats de statut inopérants

Le modèle testait `picked_up` et `cancelled` — statuts qui **n'existent pas** dans Fleetbase (les vrais : `created`, `dispatched`, `started`, `enroute`, `completed`, `canceled`, avec un seul « l »). Conséquence : `isInProgress` était toujours faux, donc aucune commande n'apparaissait jamais comme en cours, et les boutons d'action de l'écran détail ne s'affichaient pas.

Statut volontairement laissé en `String` plutôt qu'en enum : la machine à états vient de l'`OrderConfig` côté serveur (§6.9), la figer côté client la ferait diverger au premier changement de configuration.

### 7.3 Les raisons d'échec étaient rejetées par le serveur

L'écran envoyait des libellés anglais (`'Recipient not available'`) comme valeur, alors que le BFF valide contre une liste fermée de codes (`client_absent`, `adresse_introuvable`, …). **Tout signalement d'échec aurait été rejeté en 400.**

Les deux listes divergeaient aussi sur le fond : le scaffolding proposait « Traffic/delay » et « Vehicle issue » — des retards, pas des échecs de livraison — et omettait « accès impossible » présent dans la spec §4.3. Remplacé par un couple code/libellé aligné exactement sur le serveur.

**Statut** : ✅ `flutter analyze` **passe sans aucune anomalie** (28/07/2026, côté utilisateur). Une seule erreur avait été remontée sur l'ensemble de la revue — `BffApiClient.isAuthenticated()` appelée par `auth_state` mais jamais définie — corrigée. Le code compile ; il n'a pas encore été exécuté.

### 7.4 Blocages structurels au premier lancement

Trois obstacles identifiés avant même d'essayer, aucun lié au code métier :

1. **Aucun scaffolding de plateforme** — `driver_app/` ne contient que `lib/`, pas de `android/` ni `ios/`. `flutter run` ne peut pas aboutir tant que `flutter create . --platforms=android` n'a pas été lancé. Le scaffolding du 27/07 avait produit le code Dart sans les dossiers de plateforme.
2. **Firebase bloquait le démarrage** — `firebase_options.dart` est encore un gabarit (`YOUR_PROJECT_ID`), et `currentPlatform` renvoie systématiquement la config `web`. `Firebase.initializeApp()` levait donc au lancement et empêchait **toute** utilisation de l'app, y compris la connexion et les commandes, qui n'ont aucun besoin de Firebase. Encadré par un `try/catch` : le push est un déclencheur de rafraîchissement (§11.1 de la spec), pas une dépendance de fonctionnement. Sans config, le driver rafraîchit à la main.
3. **HTTP en clair bloqué par Android** depuis l'API 28 — un BFF local en `http://` échouera en `CLEARTEXT communication not permitted` tant que `usesCleartextTraffic` n'est pas posé. À retirer avant distribution, le BFF devant passer en HTTPS.

Le point 2 illustre un principe utile pour la suite : **une dépendance de confort ne doit pas conditionner le démarrage.** Une intégration tierce non configurée doit dégrader une fonctionnalité, pas rendre l'application inutilisable.

### 7.5 L'écran détail rejouait des transitions déjà faites

Premier test réel de l'app (28/07/2026) : accepter une commande adhoc fonctionne, puis « Start Delivery » échoue en `Failed to start this order`.

**Le message était exact.** Accepter une adhoc l'assigne **et** la démarre en un seul appel Fleetbase (§4.2 de la spec — `startOrder` avec `assign`). La commande était donc déjà `started`, et le bouton redemandait une transition accomplie.

Cause réelle : l'écran construisait ses actions à partir de prédicats **locaux** (`isPending`, `isInProgress`) — une machine à états codée en dur côté client, doublant celle du serveur. Or les transitions réelles dépendent de l'`OrderConfig` et varient d'une commande à l'autre ; seul `activites-suivantes` les connaît (§6.9).

**Correction** : les boutons sont désormais générés à partir de ce que le serveur propose, un par activité disponible, avec le libellé `_resolved_status` (déjà interpolé côté serveur, contrairement à `status` qui peut contenir des gabarits). « Accepter » reste un bouton distinct, parce qu'une adhoc non réclamée n'a par définition aucune transition tant qu'elle n'est assignée à personne. `_startOrder`/`_completeOrder` supprimés plutôt que laissés en place : du code mort suggérant un flux qui n'existe plus.

**Reste ouvert** : le drapeau `require_pod` est affiché sur le bouton mais **pas honoré** — la capture photo (§5) n'est pas branchée, donc l'étape part sans preuve. Le serveur l'accepte ; c'est la preuve qui manquera au dossier.

**Leçon** : dupliquer côté client une machine à états qui vit côté serveur produit une divergence silencieuse. Ici elle s'est vue tout de suite ; sur un flux moins fréquenté, elle serait passée en production.

### 7.6 Autres écarts corrigés au même passage

- **Liste vide en permanence** : l'app ne demandait que `type=assigned`. Une commande adhoc n'étant assignée à personne, elle ne pouvait jamais apparaître — l'onglet destiné aux opportunités était structurellement vide. Bascule sur les trois catégories renvoyées ensemble par le BFF.
- **Erreur de chargement invisible** : une liste vide et un échec de requête produisaient exactement le même écran. Le message d'erreur est maintenant affiché — c'est ce qui rendait le premier lancement impossible à diagnostiquer.
- **Couleurs de statut inertes** : `_getStatusColor` testait `accepted` et `picked_up`, absents de Fleetbase ; tout tombait dans le gris par défaut.
