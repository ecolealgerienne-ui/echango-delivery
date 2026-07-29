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

> ## 🛑 CORRECTION DU 29/07/2026 — LIRE AVANT D'UTILISER CETTE SECTION
>
> **L'observation ci-dessous est exacte ; la conclusion qu'on en a tirée est
> fausse, et elle a coûté trois reconstructions.**
>
> `facilitator_uuid` et `vendor_uuid` **ne sont pas les noms des filtres**. Les
> méthodes de `OrderFilter`/`DriverFilter` s'appellent **`facilitator`**,
> **`vendor`**, **`customer`**, **`driver`**, sans suffixe. Un paramètre sans
> méthode correspondante est abandonné en silence, d'où le résultat observé.
>
> **Fleetbase filtre bien côté serveur** — la console Fleetbase le fait à chaque
> requête. Ne pas généraliser cette section en « les filtres de query string ne
> sont pas fiables » : ce qui n'est pas fiable, c'est **un nom de paramètre
> supposé**.
>
> Détail complet, noms exacts relevés sur la console, et vérifications restant à
> faire : **`docs/architecture_bff_fleetbase.md`** §4 et §9. Récit :
> §20.2 de ce journal.
>
> Restent vraies et non affectées par cette correction : `places?owner_uuid`
> fonctionne (§2.7), `positions` n'a réellement aucun filtre par driver (§2.11),
> `GET /vendors/{uuid}` ignore réellement son paramètre de chemin (§2.13).

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

### 7.7 Un échec de livraison signalé n'était visible nulle part

Signalé par test réel : le driver déclare un échec, « ça ne marche pas », et la commande reste en `enroute` dans « En cours ». Le log Android ne contient aucune erreur Dart.

**Le comportement était en partie correct et entièrement indiscernable d'une panne.** Trois défauts distincts se cumulaient :

1. **Le statut inchangé est voulu** (§6.5) : un signalement ne modifie pas la commande Fleetbase, faute de statut natif confirmé. Mais rien ne l'expliquait à l'écran — l'écart entre « j'ai signalé un échec » et « statut : enroute » passait pour une incohérence.
2. **Le signalement n'était renvoyé par aucun endpoint.** Il était bien enregistré côté BFF, mais `GET /transporteur/commandes` ne l'exposait pas : l'app n'avait aucun moyen de savoir qu'un rapport existait. Un signalement partait dans le vide, du point de vue de l'utilisateur. Corrigé — les commandes renvoyées portent désormais `delivery_failure` (clé que le modèle Dart lisait déjà), avec le rapport le plus récent par commande, un driver pouvant réessayer puis échouer à nouveau.
3. **Un échec du signalement n'affichait rien** : le `if (success)` n'avait pas de `else`. Ni message, ni navigation — un bouton mort. C'est ce qui a rendu le diagnostic difficile.

Corrigé aussi : le double `context.pop()` renvoyait à la liste, où rien ne change, au lieu du détail où le rapport est maintenant affiché. Et l'état local ne fabrique plus un statut `'failed'` inexistant côté serveur — il recharge, plutôt que de mentir puis d'être écrasé au rafraîchissement suivant.

**Leçon** : une fonctionnalité dont l'effet n'est visible nulle part est équivalente, pour l'utilisateur, à une fonctionnalité cassée. Le stockage côté BFF (§6.5) était un choix défendable, mais incomplet tant que rien ne le relisait.

### 7.8 ⚠️ Piège au passage en S3 — le contournement de §6.12 doit être reconfiguré

À traiter **au moment du déploiement VPS**, sinon la preuve de livraison cassera de façon silencieuse.

Rappel du bug amont (§6.12) : `capturePhoto()` lit le bucket depuis la **requête** au lieu de la config. Notre contournement envoie donc `disk` et `filesystems.disks.<disk>.bucket` dans le corps de la requête, avec par défaut `local` et une valeur factice `fleetbase` — ignorée par le disque local, ce qui convient en développement.

**Ce que ça implique en S3** : la valeur envoyée par le BFF **prend le pas** sur la configuration Fleetbase. Laisser les valeurs par défaut ferait écrire dans un bucket nommé `fleetbase` sur le disque `local`, alors même que Fleetbase serait correctement configuré pour S3 — la config serveur serait ignorée sans qu'aucune erreur ne le signale. Il faut donc impérativement renseigner :

```
FLEETBASE_PROOF_DISK=s3
FLEETBASE_PROOF_BUCKET=<nom réel du bucket>
```

**À vérifier en même temps** : si l'amont a corrigé la ligne entre-temps (`config()` au lieu de `$request->input()`), le contournement devient inutile *et nuisible* — il continuerait d'imposer une valeur là où la config serveur devrait décider. Tester d'abord un upload sans ces variables : s'il passe, retirer le contournement de `captureOrderPhoto()`.

C'est le seul endroit du BFF où une valeur d'environnement écrase silencieusement une configuration Fleetbase. Il mérite d'être revu à chaque montée de version.

---

## 8. Interface commerçant (28/07/2026)

### 8.1 ⚠️ Le module commerçant servait un cache jamais resynchronisé

Découvert en préparant l'app : `POST /commercant/commandes` renvoie un **cuid Prisma** (`cms4wivve…`), pas un identifiant Fleetbase. En lisant `commercant.service.ts`, la cause est plus large — `getOrders()` interrogeait **uniquement** `prisma.order`, jamais Fleetbase.

Or ce cache ne contient qu'un id, un `fleetbaseOrderId`, un numéro de suivi et un `status` **figé à `'pending'` à la création, que rien ne resynchronise**. Conséquences pour un commerçant :

- sa livraison n'aurait **jamais** semblé progresser, quel que soit son état réel ;
- ni adresses, ni transporteur assigné, ni date de dispatch — rien de tout ça n'est stocké localement.

Le module passait pourtant les tests : ils vérifiaient qu'une commande est créée et relue, pas que l'état affiché correspond à la réalité. Un cache qui ment est indétectable si on ne compare jamais à la source.

**Correction** : `mergeWithFleetbase()` conserve au cache le seul rôle qu'il remplit bien — **la correspondance commerçant ↔ commande** — et lit tout le reste depuis Fleetbase. Ce partage n'est pas cosmétique : §2.8 a montré que Fleetbase ignore silencieusement les filtres non supportés sur `/orders`, donc lui demander « quelles commandes appartiennent à ce commerçant » renverrait toute la compagnie. **L'appartenance doit rester décidée localement** ; c'est ce qui rend le contrôle anti-IDOR fiable.

**Dégradation explicite plutôt que silencieuse** : si Fleetbase est injoignable, les commandes sont renvoyées marquées `stale` ; si l'une a disparu côté Fleetbase, `missing`. L'app affiche alors « État indisponible » au lieu d'un statut inventé. Une donnée absente doit se voir.

### 8.2 Décisions de périmètre

- **App mobile d'abord**, web ensuite (décision utilisateur). Aucune dépendance native n'a été introduite — ni géolocalisation, ni push, ni carte — ce qui garde la cible web ouverte sans réécriture.
- **Adresses en texte** avec carnet réutilisable, carte plus tard. Conséquence assumée et documentée dans le code : les coordonnées viennent d'une adresse enregistrée ou d'un repli au centre d'Alger, jamais d'un géocodage. Suffisant pour un dispatch géospatial approximatif, à reprendre avec la carte.
- **Pas de dispatch automatique** : une demande créée par un commerçant attend qu'un opérateur la diffuse. L'écran de création le dit, sinon l'absence de transporteur passerait pour une panne. C'est une règle métier à confirmer (`docs/specs_echango_delivery.md` §6), pas une limite technique.

### 8.3 État

`scripts/test-commercant-module.sh` passe au vert intégral, **anti-IDOR compris** — un second commerçant ne voit ni la commande de l'autre (403), ni quoi que ce soit dans sa liste. L'app, elle, **n'a jamais été compilée** : `flutter analyze` reste le premier test réel.

### 8.4 Fusion en application unique (décision 28/07/2026)

Le scaffolding partait sur **une app par persona**. L'utilisateur a fait remarquer que c'est un seul produit — on commande une livraison et on la livre, avec des profils différents. Argument juste, et le code le confirmait : `merchant_app` avait été créé en **copiant** `errors/`, `theme/`, la structure du client HTTP et celle de l'auth depuis `driver_app`. Dupliquer un socle est le signal qu'il devrait être partagé.

**Fusion** : `driver_app` + `merchant_app` → `echango_delivery`, avec `screens/transporteur/` et `screens/commercant/`. Le découpage par profil n'est pas cosmétique — il existe pour que la séparation en deux binaires reste peu coûteuse si le coût ci-dessous devenait bloquant.

**Coût assumé** : les permissions Android sont déclarées dans le manifeste, pas à l'exécution. La géolocalisation en tâche de fond, nécessaire au transporteur, apparaîtra donc pour un commerçant qui ne livrera jamais — y compris sur une fiche Play Store, qui impose en plus une procédure de validation pour cette permission. Elles ne sont *demandées* qu'à l'usage, et une distribution B2B par APK direct ne pose pas la question ; ça reste une dette à surveiller.

**Le profil n'est pas demandé à l'utilisateur** (correction en cours de fusion — la première version affichait un sélecteur transporteur/commerçant, friction inutile pour une information que le serveur détient). Nouvel endpoint **`POST /auth/login`** : il cherche l'email dans les trois tables et vérifie le mot de passe dans chacune, **sans court-circuiter sur la première correspondance d'email** — un même email peut légitimement exister pour deux profils, seul le mot de passe tranche alors. Le profil résolu est renvoyé dans `user.type` et fait autorité pour la navigation.

Deux points de conception à noter :

- **Cas ambigu non deviné** : si le même couple email/mot de passe vaut pour plusieurs profils, le serveur renvoie `requiresRoleSelection` et la liste, plutôt que d'en choisir un. Ouvrir le mauvais espace serait pire qu'une question.
- **Message d'échec uniforme** : un identifiant inconnu et un mot de passe faux donnent la même réponse, sans révéler quels emails existent ni dans quelle table — un endpoint qui interroge trois tables serait sinon un bel oracle d'énumération.

Les endpoints par persona restent en place : les scripts de test s'en servent, et seul l'endpoint unifié enrichit la réponse, puisque lui seul détenait l'information à transmettre.

**Retrait du parcours OTP** : les écrans de connexion par téléphone appelaient `/auth/login-phone` et `/auth/verify-otp`, qui n'existent pas côté BFF. Un écran qui ne peut qu'échouer vaut moins que son absence. Toujours au périmètre spec, à réintroduire avec son serveur.

---

## 9. Correction du P0 de la revue croisée (28/07/2026)

Neuf points traités, issus de `docs/rapports_revue_2026-07-28/00_synthese.md`. Le fil conducteur : **une configuration absente ou une entrée non validée ne doit jamais dégrader silencieusement la sécurité**.

### 9.1 Secret JWT — un seul point de configuration, validé au démarrage (C1)

Le défaut était plus profond qu'un mauvais défaut : `AuthModule` enregistrait **son propre** `JwtModule` avec un repli (`'dev-secret'`) différent de celui d'`AppModule` (`'dev-secret-key-change-in-prod'`). La signature et la vérification utilisaient donc deux `JwtService` distincts — sans la variable d'environnement, les secrets divergeaient et 100 % des requêtes authentifiées partaient en 401 sans indice. Avec la variable posée d'un seul côté, c'était pire : ça marchait, avec un secret public.

Corrections : suppression du `JwtModule` local (celui d'`AppModule` est `global: true`), suppression des trois replis, et `validateEnv()` qui **refuse le démarrage** si `JWT_SECRET` manque, fait moins de 32 caractères, ou reprend une des valeurs présentes dans l'historique Git. Le `docker-compose.yml` utilise désormais `${JWT_SECRET:?...}` — Docker refuse de démarrer plutôt que de substituer un défaut.

Au passage, `JwtStrategy` supprimée : `JwtAuthGuard` surchargeait `canActivate` sans jamais appeler `super`, donc Passport n'était jamais sollicité. Le fichier était du code mort **piégeur** — une modification faite là en croyant durcir l'authentification n'aurait rien changé. Le garde n'hérite plus d'`AuthGuard` et fixe explicitement `algorithms: ['HS256']`.

### 9.2 Inscription transporteur — invitation obligatoire (C2)

La revue a démontré une chaîne complète de prise de contrôle : un commerçant lit `driver_assigned_uuid` sur **sa propre** commande, appelle `POST /auth/transporteur/register` avec cet uuid et ses propres identifiants, et devient ce transporteur — le vrai driver se retrouvant bloqué, l'uuid étant marqué comme lié.

La correction rétablit ce que la décision de provisioning manuel supposait déjà : **c'est l'opérateur qui décide qui devient transporteur**. Nouveau modèle `DriverInvitation` ; le driver visé est figé à l'émission, plus fourni par l'appelant. Points de conception :

- **Jeton haché en base** (SHA-256 — 32 octets aléatoires, ni devinables ni réutilisés ailleurs, un sel n'apporterait rien) : une fuite de la base ne livre pas d'invitations utilisables.
- **Message identique** pour un jeton inconnu, expiré ou déjà consommé — sinon l'endpoint devient un oracle sur les invitations valides.
- **Consommation après création du compte** : si la création échoue, l'invitation reste utilisable plutôt que d'être perdue pour le transporteur.
- **Émission réservée au persona `fleet`** (`POST /auth/transporteur/invitation`).

### 9.3 Injection de chemin vers le token de service (E3/M8)

`subjectId = "../../ORDER_X/cancel"` transformait `/v1/orders/ORDER_A/capture-photo/<subjectId>` en `/v1/orders/ORDER_X/cancel` après normalisation amont — exécuté avec le token de service qui a tous les droits sur l'organisation. Le contrôle d'appartenance portait sur ORDER_A pendant que la requête partait vers ORDER_X.

**Deux barrières volontairement redondantes** : validation en entrée (`@Matches(FLEETBASE_ID_PATTERN)` sur les DTO, `FleetbaseIdPipe` sur les `@Param('id')` des trois modules — un `@Param` n'est pas couvert par le `ValidationPipe` global) et ré-encodage en sortie (`encodeURIComponent` sur tous les segments interpolés du client Fleetbase). Une seule suffirait aujourd'hui ; les deux garantissent qu'un futur appelant qui oublierait la validation ne rouvre pas la faille.

### 9.4 Garde de persona unifié (E4)

`CommerçantController` était le seul des trois à ne pas vérifier `req.user.type`. Il n'était protégé que par une propriété **non voulue** du schéma — les `cuid` de tables différentes ne se rencontrent pas, donc la recherche échouait en 404. Une garantie probabiliste, qui tombait au premier compte multi-profils.

Décorateur `@Persona(...)` + `PersonaGuard` global, appliqués aux trois contrôleurs et à `POST /auth/device-token` (qui écrit dans `DeviceToken`, lié à `MerchantAccount`). Les trois helpers dupliqués disparaissent, et l'oubli sur une route future devient visible.

### 9.5 Limitation de débit, ciblée par nature de risque (E5)

Un plafond uniforme sur `/auth` aurait cassé les scripts de test (13 appels d'auth par exécution) sans gain : **personne ne bruteforce un endpoint d'inscription**. Deux plafonds distincts :

- **connexion : 5/minute** — laisse place aux fautes de frappe, rend un dictionnaire inexploitable ;
- **inscription : 10/heure** — le risque y est la pollution (chaque inscription crée un `Vendor` Fleetbase durable), pas la devinette.

`ThrottlerGuard` est enregistré **avant** `JwtAuthGuard` : borner le débit avant tout travail coûteux, sinon chaque requête rejetée fait quand même payer une vérification de jeton.

### 9.6 Taille de corps et bornes photo (M11 / archi #4)

Express plafonne le JSON à **100 ko** par défaut : toute vraie photo de téléphone (1–4 Mo en base64) partait en 413. La preuve de livraison, pourtant validée côté serveur et pour laquelle le contournement du bug amont Fleetbase avait été payé, était **inutilisable en conditions réelles**. Le test qui passait au vert envoyait un PNG 1×1 — il ne pouvait pas le révéler.

Deux bornes cohérentes plutôt qu'une : `MAX_REQUEST_BODY` (10 Mo, configurable) protège le processus, `@ArrayMaxSize(5)` + `@MaxLength(7_000_000)` renvoient une erreur de validation lisible au lieu d'un 413 opaque.

**Leçon** : un test qui utilise une donnée minimale valide vérifie le chemin, pas la charge réelle. Le PNG 1×1 était le bon choix pour tester l'API — pas pour conclure que la fonctionnalité marche.

### 9.7 Annulation et suivi commerçant (archi #3 + #15)

Deux identifiants coexistent — le `cuid` local et l'`uuid` Fleetbase — et l'app envoie l'uuid. `cancelOrder` et `getOrderTracking` cherchaient le cuid : **404 systématique**, le suivi échouant en silence côté client. Ma correction du 28/07 n'avait touché que `getOrderDetail`.

`resolveOwnedOrder()` factorise la résolution (les deux identifiants) et le contrôle d'appartenance, pour que les trois méthodes ne divergent plus. Deux corrections s'y ajoutent :

- **Le garde de transition lit l'état réel chez Fleetbase**, plus le champ `status` du cache — figé à `'pending'` depuis la création et jamais resynchronisé, il laissait annuler une commande déjà livrée.
- **Annulation refusée après `started`/`enroute`** : le transporteur peut être devant la porte. Le refus protège les deux parties tant que la règle métier n'est pas tranchée (§6), et l'opérateur garde la main depuis la console.

### 9.8 Oracle de timing sur la connexion unifiée (M7)

`loginUnified` n'appelait `bcrypt.compare` que si la ligne existait : ~5 ms pour un email inconnu, ~100 ms pour un email connu. Un ordre de grandeur, mesurable à travers Internet — **et le commentaire du code affirmait le contraire**. C'est le cas le plus instructif de la revue : un commentaire qui décrit une intention peut certifier une propriété que le code n'a pas.

Chemin à coût constant : trois `bcrypt.compare` systématiques, contre le hash réel ou contre un `DUMMY_HASH` calculé au chargement du module. Messages d'échec uniformisés (`INVALID_CREDENTIALS`) — « Email not verified » et « Account is inactive » étaient deux oracles de plus.

### 9.9 Sonde de disponibilité (archi #13)

Le `HEALTHCHECK` du Dockerfile interrogeait `/health`, route inexistante : conteneur `unhealthy` en permanence, redémarrage en boucle selon l'orchestrateur. `HealthController` vérifie la base (`SELECT 1`).

Fleetbase n'est **délibérément pas** vérifié : son indisponibilité dégrade le service sans le rendre inutile, et faire redémarrer le BFF parce qu'un tiers est tombé ne réparerait rien.

### 9.10 État

Le BFF compile, les scripts sont syntaxiquement valides, l'app Flutter est équilibrée. **Rien n'a été exécuté** — pas d'instance dans le sandbox. `scripts/test-driver-auth.sh` a été réécrit pour le parcours par invitation (émission via un compte flotte) et vérifie deux nouveaux contrôles : rejet d'une invitation inventée, et refus qu'un transporteur s'auto-émette une invitation.

**Prérequis avant de relancer les tests** : `npm run prisma:migrate` (nouveau modèle `DriverInvitation`) et un `JWT_SECRET` d'au moins 32 caractères dans `.env` — le service refuse désormais de démarrer sans.

---

## 10. Présence transporteur — le P1 bloquant pilote (28/07/2026)

Les trois revues croisées convergeaient sur un même constat : côté serveur, tout ce dont un transporteur a besoin existait et était validé par des tests réels ; côté app, **rien ne l'appelait**. `LocationService` n'était instancié nulle part, `getDeviceToken()` n'était appelé par personne, `setOnline` n'existait que dans le client HTTP. Un driver de test n'aurait donc jamais été « en ligne » pour Fleetbase, n'aurait jamais émis de position, jamais reçu de push, et n'aurait vu une nouvelle course que s'il tirait l'écran vers le bas au bon moment.

### 10.1 Trois mécanismes qui n'ont de sens que combinés

Regroupés dans `DriverPresenceState` plutôt que dispersés dans les écrans, parce qu'ils ne se tiennent qu'ensemble :

| Mécanisme | Sans lui |
|---|---|
| Bascule en ligne | Fleetbase ne diffuse aucune course à ce driver |
| Suivi de position | en ligne mais invisible — le dispatch choisit par proximité |
| Push + interrogation | la course arrive, l'écran ne bouge pas |

La présence suit la **session**, pas un écran : elle démarre après connexion ou restauration au lancement, et s'arrête à la déconnexion même si le driver n'a jamais ouvert le tableau de bord.

### 10.2 Le passage hors ligne devait précéder l'invalidation du jeton

Premier branchement écrit : la présence réagissait au changement d'état d'`AuthState`. Il ne pouvait pas fonctionner — `logout()` appelle `clearSession()` **avant** de notifier, donc l'appel `setOnline(false)` serait parti sans jeton et aurait échoué en 401, silencieusement. Un transporteur déconnecté serait resté « en ligne » côté Fleetbase, éligible à des courses que personne n'aurait prises.

D'où `AuthState.onBeforeLogout`, exécuté pendant que le jeton est encore valide. Repère plus général : **tout nettoyage déclenché par un changement d'état arrive après coup** ; ce qui exige encore les droits de la session doit être accroché avant, pas observé après.

### 10.3 `getProfile` ne disait pas si le driver était en ligne

Sans ce champ, l'app aurait affiché au démarrage la position par défaut de son interrupteur. Un driver rouvrant l'app se serait cru hors ligne tout en continuant de recevoir des courses — le sens dangereux de l'erreur.

`getProfile` lit désormais `online` depuis Fleetbase, seul à savoir à qui le dispatch diffuse. `null` quand Fleetbase est injoignable, et l'app affiche alors « — » plutôt que d'affirmer « hors ligne ».

### 10.4 Le suivi de position ne s'arrêtait jamais

`stopBackgroundTracking()` basculait un booléen sans annuler l'abonnement au flux `Geolocator` : le GPS restait allumé et les positions continuaient de partir après la déconnexion. Batterie vidée, et un driver qui se croyait hors ligne alimentait encore le dispatch. L'abonnement est maintenant réellement annulé, et `isTracking` dérive de son existence au lieu d'un drapeau parallèle qui pouvait mentir.

### 10.5 Le plafond silencieux de 100 commandes

`getAllOrders()` avait `limit = 100` par défaut, et trois des quatre appelants s'en servaient comme d'un « tout ». Puisque **chaque filtre est appliqué côté BFF** (Fleetbase ignore silencieusement les filtres de requête, §2.8), une liste tronquée n'est pas une liste partielle : c'est une **réponse fausse**. À partir de la 101ᵉ commande de l'organisation, `resolveOrder()` aurait cessé de trouver des commandes existantes et légitimement assignées, et renvoyé 404.

Le module flotte avait déjà écrit la pagination correcte pour cette raison exacte ; elle est hissée dans le client (`fetchEveryOrder`) et partagée par les trois personas. Le garde-fou de pages journalise quand il est atteint — au-delà, les réponses redeviennent fausses.

### 10.6 La carte de flotte téléchargeait tout l'historique de positions

`/positions` de Fleetbase n'a aucun filtre par driver (§2.9). Servir une carte depuis lui obligeait à télécharger tout l'historique de la compagnie à chaque rafraîchissement, pour n'afficher qu'un point par driver — un coût qui croît avec l'historique, pas avec le nombre de drivers affichés.

`POST /transporteur/position` écrit désormais un miroir local (`lastLatitude`/`lastLongitude`/`lastPositionAt` sur `DriverAccount`), et la flotte le lit. L'historique reste chez Fleetbase, source de vérité. Le miroir échoue en avertissement, jamais en erreur : l'écriture Fleetbase a déjà réussi à ce stade, et faire échouer l'appel ferait croire au driver que sa position n'est pas partie.

Conséquence assumée : un driver sans compte Echango, ou qui n'a jamais émis depuis l'app, n'apparaît pas sur la carte. Fleetbase n'en aurait de toute façon aucune position.

### 10.7 Statuts optimistes inventés

`acceptOrder` écrivait localement `accepted`, `startOrder` écrivait `picked_up` — **aucun des deux n'existe dans Fleetbase** (`dispatched`, `started`, `completed`, `canceled`). L'app affichait donc un statut qu'aucune couleur ni aucun filtre ne reconnaissait. Et le statut n'est pas la seule chose qui change : les transitions suivantes en dépendent et viennent du serveur. Les cinq mutations passent par un `_mutateOrder` unique qui relit l'état après coup, comme le faisait déjà `applyActivity`.

### 10.8 Aucune requête HTTP n'avait de délai maximal

`package:http` n'applique aucun timeout par défaut. Une requête partie vers un réseau qui cesse de répondre restait en attente indéfiniment : indicateur de chargement perpétuel, sans erreur ni possibilité de réessayer — sur le téléphone d'un transporteur en couverture faible, le mode d'échec le plus courant et le plus difficile à distinguer d'une app figée. Enveloppé dans un `http.BaseClient` plutôt qu'appliqué appel par appel, pour qu'un nouvel endpoint ne puisse pas l'oublier.

### 10.9 État

BFF : compile (`tsc --noEmit`). **Non exécuté** — pas d'instance Fleetbase dans le sandbox.

App : **jamais compilée**, aucune toolchain Flutter ici. `flutter analyze` reste à passer côté Windows.

**Prérequis avant de relancer les tests** : `npm run prisma:migrate` (trois colonnes de position sur `DriverAccount`).

**Reste ouvert** : le suivi de position s'arrête quand l'app passe en arrière plan — `ACCESS_BACKGROUND_LOCATION` et un service au premier plan (`flutter_foreground_task`, §11.2 de `specs_app_transporteur.md`) ne sont pas branchés. En l'état, un transporteur doit garder l'app ouverte pour alimenter le dispatch.

### 10.10 `POST /transporteur/statut` ne rapportait pas ce que Fleetbase avait fait

Le premier passage réel de l'assertion « le profil reflète le passage en ligne » l'a fait échouer : `POST /statut` renvoyait `{online: true}`, puis `GET /profil` renvoyait `online: false`.

Le service recopiait `dto.online` dans sa réponse au lieu de lire la `DriverResource` que Fleetbase renvoie. La route répondait donc **toujours** la valeur demandée, y compris si l'écriture n'avait aucun effet — le test au vert de la session précédente ne prouvait rien. Corrigé : la réponse rapporte ce que Fleetbase confirme, journalise l'écart le cas échéant, et vaut `null` si le champ manque.

**Piège de lecture, dans la ressource Fleetbase** (`Http/Resources/v1/Driver.php`) :

```php
'online' => data_get($this, 'online', false)
```

Elle renvoie `false` aussi bien pour « hors ligne » que pour « attribut non chargé ». Un `false` lu dans une **collection** ne distingue donc pas les deux, et se lit à tort comme une disponibilité — exactement l'ambiguïté que le `null` de `getProfile` cherchait à éviter, réintroduite par la source. La relecture passe désormais par `GET /v1/drivers/{public_id}`, fiche unique et hydratée, et non par un `find` dans la liste.

Repère général : **une valeur par défaut dans une ressource amont détruit l'information d'absence**. Chercher `data_get($this, 'x', <défaut>)` avant de traiter un champ Fleetbase comme faisant autorité.

Cause encore non tranchée à ce stade : si la colonne vaut bien `1` en base, le défaut de la ressource explique tout ; si elle vaut `0`, l'écriture elle-même est en cause et le `public_id` utilisé pour la bascule est le premier suspect. Le script affiche désormais la commande de vérification en cas d'échec.

### 10.11 Un test de cloisonnement qui ne pouvait pas conclure

Le contrôle « un jeton valide d'un autre persona doit être refusé » forgeait son jeton avec le `JWT_SECRET` lu dans `backend/bff/.env`. Rien ne garantit que c'est celui du conteneur — `docker-compose.yml` le prend de l'environnement du shell. Quand les deux diffèrent, le jeton forgé est rejeté à la **vérification de signature** (401), et le contrôle de rôle n'est jamais atteint : le test ne démontrait rien. Il le disait au moins honnêtement (« non concluant »), mais un contrôle de sécurité qui ne conclut jamais ne protège de rien.

Remplacé par un jeton **émis par le serveur** (persona `fleet`, déjà créé pour les invitations) : toujours valide, donc le 403 obtenu prouve bien que c'est le persona qui bloque, et non la signature.

Repère : dès qu'un test doit reproduire un secret du serveur pour fabriquer une entrée valide, il teste aussi la synchronisation de ce secret — et échouera pour cette raison-là plutôt que pour celle qu'il annonce. Faire émettre l'entrée par le serveur quand c'est possible.

---

## 11. Preuve photo et expurgation des opportunités adhoc (28/07/2026)

Deux items P1 qui ne dépendaient d'aucune décision produit.

### 11.1 La capture photo — une chaîne serveur validée mais inatteignable

`POST /transporteur/commandes/{id}/preuve` était validé par test réel depuis le 28/07, contournement du bug amont compris (§6.12). L'app, elle, affichait « Photo capture will be available in future updates » : les étapes marquées `require_pod` partaient sans preuve, acceptées par le serveur, et le dossier restait incomplet sans que personne ne le voie.

`widgets/photo_field.dart` sert les deux besoins, pour que les écrans ne divergent pas comme l'avaient fait les deux scripts de test. Deux règles opposées, chacune motivée :

- **Preuve de livraison, obligatoire** — l'étape n'est appliquée qu'après envoi réussi. Annuler la capture annule l'étape : envoyer sans preuve contournerait la règle que le serveur vient d'énoncer. Et si l'envoi échoue, l'étape n'est pas appliquée — mieux vaut une commande bloquée que le transporteur peut reprendre qu'une commande close sans son justificatif.
- **Échec de livraison, facultative** — l'imposer pousserait à photographier n'importe quoi pour débloquer l'écran, alors qu'un destinataire absent n'a rien à montrer.

La borne de taille du serveur (`MAX_PHOTO_BASE64_LENGTH`) est vérifiée **avant** l'envoi. Sans ça la requête part et revient en 400 après avoir consommé la connexion mobile du transporteur — le seul acteur du système dont la connexion est incertaine par nature.

### 11.2 Les opportunités adhoc diffusaient des données personnelles (revue M9)

Une commande adhoc est diffusée à **tous** les transporteurs de l'organisation, dont aucun n'a encore de lien avec cette livraison. Servie telle quelle, elle livrait à chacun le nom, l'adresse exacte et le téléphone du client et du commerçant — pour des courses qu'ils ne prendront pas. C'est une diffusion de données personnelles à des tiers, pas une fonctionnalité.

`redactUnclaimedOrder()` ne laisse que ce qui permet de décider : d'où à où (au niveau du lieu, pas de la porte), distance et durée estimées. Le détail complet arrive à l'acceptation.

**Le point qui comptait** : `getOrder` renvoyait la commande complète pour une adhoc non réclamée — l'accès y est légitime, c'est ainsi que le driver consulte une opportunité avant de la prendre. Expurger la seule liste aurait donc été un théâtre : il suffisait d'ouvrir la fiche pour récupérer ce que la liste venait de retirer. La même expurgation s'applique aux deux chemins.

Repère : **une donnée retirée d'une liste doit l'être de toutes les routes qui servent le même objet.** Chercher systématiquement l'accès unitaire quand on filtre un accès collectif.

**Ce que ça ne règle pas** : la diffusion reste organisation-wide, sans filtre de proximité. Le rayon est une décision produit ouverte.

### 11.3 Vérification

Le script assère les deux chemins, avec un détecteur générique (`jq | .. | objects`) qui cherche toute clé `phone`/`contact_name`/`email` à n'importe quelle profondeur, plutôt qu'une liste de champs connus — un champ ajouté plus tard côté Fleetbase sera attrapé sans qu'on y pense. Détecteur éprouvé dans les deux sens avant d'être commis : il attrape un `contact_phone` planté à la main, et laisse passer une charge propre.

### 11.4 Suivi en arrière plan et navigation externe

`flutter_foreground_task` figurait dans le `pubspec` depuis l'initialisation du projet et n'était appelé nulle part — le même motif que la présence, la capture photo et les jetons push : une dépendance déclarée, jamais branchée, qui donne l'illusion que le besoin est couvert.

Sans service au premier plan, Android suspend le processus dès que le transporteur passe à une autre application ou éteint son écran : l'abonnement Geolocator cesse d'émettre et le dispatch travaille sur une position figée. C'est le mode d'échec le plus insidieux du profil, puisque **tout fonctionne tant qu'on regarde l'écran** — c'est-à-dire exactement pendant qu'on teste.

Le service tourne **sans `TaskHandler`**, délibérément : on n'a pas besoin d'exécuter du code dans un isolate séparé, seulement d'empêcher le système de tuer le processus. L'abonnement GPS continue alors dans l'isolate principal, avec la session et le client HTTP déjà en place. Un isolate séparé imposerait de re-créer les deux et de faire transiter les positions par messages, pour aucun gain.

Deux choix de comportement valent d'être notés. `autoRunOnBoot: false` : être en ligne est une décision du transporteur, pas un état qu'on lui rétablit au redémarrage du téléphone — il se retrouverait éligible à des courses sans le savoir. Et la notification est en importance `LOW` : permanente pendant tout un service, la faire sonner la rendrait odieuse et pousserait à la couper, donc à se rendre invisible.

Défaut introduit puis corrigé en cours d'écriture : l'avertissement « sans notification, le suivi s'arrêtera » était posé sur `_errorMessage` juste avant la remise à zéro de ce même champ, deux lignes plus bas. Il n'aurait jamais été affiché.

**Navigation externe** : `url_launcher` avec un intent `geo:` d'abord (Android laisse alors le choix entre Maps, Waze, OsmAnd) puis un repli HTTPS universel. On délègue plutôt que d'embarquer un guidage : refaire un GPS routier correct n'a aucun rapport avec ce que ce produit apporte. Les deux blocs d'adresse, jusque-là recopiés avec des libellés anglais et aucune action, deviennent un composant unique portant itinéraire et appel.

### 11.5 L'app restait bloquée sur l'écran de démarrage

Symptôme : écran de démarrage figé, alors que les logs du BFF montraient l'application bien vivante — `GET /transporteur/profil` appelé régulièrement par la présence transporteur, qui démarrait donc correctement.

Le `redirect` du routeur traitait `/splash` comme une route protégée ordinaire :

```dart
if (!authState.isAuthenticated) return isPublic ? null : '/login';
if (isPublic) return authState.homePath;
```

Non authentifié, `/splash` n'est pas public, donc redirection vers `/login` — correct. **Authentifié**, `/splash` n'est pas public non plus, donc aucune redirection : on y restait indéfiniment.

Ce qui rend le cas instructif, c'est pourquoi il n'apparaissait pas plus tôt. Après une connexion, la redirection part de `/login`, qui est public, donc `homePath` s'applique et tout fonctionne. Le défaut ne se manifeste qu'au **démarrage avec une session restaurée** — un chemin qui n'existait pas tant que l'émulateur était réinstallé à chaque essai, ce qui effaçait le jeton. Il est apparu le jour où la session a commencé à survivre.

Repère : **une route d'attente n'est ni publique ni protégée**, c'est une troisième catégorie. La traiter comme l'une des deux donne un comportement correct dans un cas et un blocage dans l'autre.

Deuxième piège du même ordre, corrigé avant qu'il ne morde : `AuthState.homePath` renvoie `/flotte` pour le persona flotte, route qui n'existait pas. Un compte flotte — il s'en crée un à chaque exécution des scripts de test — tombait sur l'écran d'erreur de `go_router`. Il obtient maintenant un écran qui explique que l'espace n'est pas construit et propose de changer de compte.

### 11.6 Un upload réussi rapporté comme échoué — deux pièges de la ressource Proof

Le signalement partait avec sa photo (`photo présente (34 ko base64)` dans les logs), Fleetbase l'acceptait sans erreur, et l'app annonçait pourtant « la photo n'a pas pu être jointe ». Deux causes cumulées, toutes deux dans la lecture de la réponse :

**1. `uuid` n'existe pas sur l'API publique.** `Http/Resources/v1/Proof` place `uuid` et `public_id` derrière `Http::isInternalRequest()`. L'upload passe par `v1`, donc seul `id` est présent — et il porte le public_id. Lire `uuid` renvoyait invariablement `null`, et `photoUploaded: Boolean(fleetbaseProofUuid)` en concluait, logiquement, que rien n'avait été joint.

C'est une variante du repère de §6.7/§6.14 : la résolution d'identifiant n'est pas uniforme entre `v1` et `int/v1`. Ici ce n'est pas la route qui change de clé mais **la réponse qui en masque une** selon l'API empruntée.

**2. La ressource Proof expose elle-même un champ `data`.** Le déballage `proof?.data ?? proof`, destiné à traverser l'enveloppe Laravel, tombait donc sur la charge utile de la preuve au lieu de la preuve. Deux significations du même nom à un niveau d'imbrication d'écart.

`extractProof()` discrimine désormais sur la présence de `url`/`id` plutôt que sur celle de `data`, et `photoUploaded` s'appuie sur l'**URL** — le seul signal qui ne dépende pas de l'API empruntée.

Repère : **déballer une enveloppe par le nom de sa clé est fragile dès que la charge utile peut porter ce même nom.** Discriminer sur le contenu attendu, pas sur la structure supposée.

Ce qui a permis de trancher : la ligne de log ajoutée en §11.5, qui distingue « photo absente » de « photo présente ». Sans elle, trois causes très différentes produisaient le même écran vide. Le service journalise maintenant aussi ce qu'il a su extraire, et les clés reçues quand il n'a rien trouvé.

### 11.7 La preuve est servie par le BFF, jamais par une URL Fleetbase

Une fois l'extraction corrigée, l'URL enregistrée était :

```
http://localhost:8000/storage/uploads/<company>/photos/proof_8byelnem7s.png
```

Inaffichable depuis l'émulateur — `localhost` y désigne l'émulateur lui-même. La correction évidente aurait été de réécrire l'hôte. C'est la mauvaise, pour deux raisons :

1. Elle ferait appeler Fleetbase **directement par l'app**, ce que `specs_app_transporteur.md` §2.1 exclut explicitement.
2. Ces URL de stockage ne sont protégées par **aucune authentification**. Les donner à l'app revient à publier les preuves de livraison à qui devine l'adresse — nom du commerçant, contenu du colis, parfois une porte d'entrée.

Le BFF sert donc le fichier lui-même, sur `GET /transporteur/preuves/:id`, avec le contrôle d'appartenance habituel (`driverId` en plus de l'identifiant, sans quoi un transporteur lirait les preuves d'un autre en changeant un cuid). L'app reçoit un chemin relatif, jamais une URL Fleetbase, et le charge via le client HTTP — `Image.network` ne porterait pas l'en-tête d'autorisation, et le jeton n'a pas à sortir du client.

`fetchStoredFile()` ne conserve que le **chemin** de l'URL stockée et le résout contre `FLEETBASE_API_URL`. Outre le problème d'hôte, une URL absolue lue en base et suivie telle quelle est une porte de sortie : quiconque parviendrait à y écrire ferait émettre au BFF, avec ses accès réseau, une requête vers l'hôte de son choix.

Effet de bord bienvenu : ça règle aussi le cas S3 en production, où les fichiers peuvent être privés — le BFF les relaie avec son propre credential au lieu d'exiger un bucket public.

### 11.8 L'historique des signalements était écrasé à chaque tentative

Remarque de l'utilisateur au premier essai : un seul signalement s'affichait, jamais les précédents. C'était un choix explicite d'`attachFailures`, avec ce commentaire — « seul le dernier décrit l'état courant ».

L'affirmation est vraie d'un **badge de statut**, fausse d'un **signalement**. Une livraison qui a échoué trois fois n'est pas celle qui a échoué une fois : c'est précisément la série qui fonde la décision de l'opérateur — relancer, réaffecter, rembourser. Et chaque tentative portant sa propre photo, n'en exposer qu'une revenait à effacer les preuves antérieures.

`delivery_failures` porte désormais la liste complète, du plus récent au plus ancien. `delivery_failure` reste le premier élément : les vues résumées n'ont besoin que de lui, et le retirer aurait cassé la liste sans rien apporter.

L'écran numérote à rebours — le plus récent porte le numéro le plus élevé — et affiche le compte dans l'en-tête. C'est cette information qui change la décision, et elle se perdrait dans une liste qu'il faudrait dénombrer soi-même.

Défaut corrigé au même endroit : `_ProofImage` construisait son `Future` dans `build()`. Un `FutureBuilder` ainsi alimenté relance sa requête à chaque reconstruction — sans conséquence visible avec une seule photo, coûteux dès qu'il y en a une par tentative. Le futur est mémorisé dans l'état et recalculé seulement si l'URL change.

### 11.9 Le fichier était écrit là où aucun serveur web ne le sert

Le relais du BFF fonctionnait, mais Fleetbase répondait `400` avec son 404 masqué :

```
{"errors":["There is nothing to see here."]}
```

Cause structurelle, pas accidentelle. Le contournement du bug de bucket (§6.12) écrivait sur le disque **`local`**, dont la racine est `storage/app` — répertoire qu'aucun serveur web ne sert. Fleetbase construit pourtant l'URL du fichier en `/storage/...`, qui suppose le disque **`public`** et son lien symbolique vers `public/storage`. Le fichier était donc correctement écrit, et introuvable par HTTP par construction.

Le défaut n'était visible d'aucune façon jusqu'ici : l'upload réussissait, la ressource renvoyait une URL d'apparence normale, et rien ne signalait qu'elle ne mènerait nulle part. Il a fallu relayer le fichier pour que l'erreur apparaisse.

`FLEETBASE_PROOF_DISK` vaut désormais `public` par défaut. **Prérequis** : `php artisan storage:link` côté Fleetbase — sans ce lien, le disque public écrit correctement et reste tout aussi inaccessible. Le message d'avertissement du BFF nomme les deux causes, pour que le prochain diagnostic ne reparte pas de zéro.

Les preuves déjà enregistrées sur le disque `local` restent inaccessibles : leur URL est en base, le fichier est sur le disque, mais aucune route ne les relie.

Repère : **une URL renvoyée par un service ne prouve pas qu'elle est servie.** Ici l'émetteur du fichier et le serveur du fichier sont deux composants distincts d'une même application, configurés séparément.

### 11.10 Chaîne preuve photo validée de bout en bout (28/07/2026)

Résolu après `php artisan storage:link` et le passage au disque `public`. Un nouveau signalement avec photo s'affiche correctement dans l'app.

Ce que ce test valide, et qui ne dépend pas du stockage retenu :

- le contournement du bug de bucket amont (§6.12) — le point le plus fragile ;
- l'extraction de l'URL depuis une ressource `Proof` qui masque `uuid` hors requête interne (§11.6) ;
- le relais authentifié par le BFF, avec sa garde d'appartenance sur `driverId` (§11.7) ;
- le chargement côté app via le client HTTP plutôt que `Image.network`, qui ne porterait pas le jeton.

Le passage à S3 ne changera que deux variables d'environnement — `FLEETBASE_PROOF_DISK=s3` et `FLEETBASE_PROOF_BUCKET` — avec le piège déjà noté : ces valeurs prennent le pas sur la configuration serveur, donc les oublier ferait écrire sur le disque public malgré une config S3 correcte, sans erreur visible.

Bénéfice du relais qui n'apparaît qu'en production : le bucket S3 peut rester **privé**. Sans relais il faudrait le rendre public pour que l'app y accède, c'est-à-dire publier les preuves de livraison à qui devine l'adresse.

**Les preuves antérieures au correctif restent inaccessibles** : leur URL est en base, leur fichier sur le disque `local`, et aucune route ne les relie. Sans conséquence — ce sont des essais.

### 11.11 L'expurgation ne tenait pas sa promesse

Remarque de l'utilisateur, écran à l'appui : le bandeau annonçait « les contacts et l'adresse précise s'affichent dès que vous acceptez », alors que l'adresse complète était affichée — `MAGASIN1 - 3 AVENUE PAUL LANGEVIN, SCEAUX, 92330`.

`redactUnclaimedOrder` ne retirait en effet que les **contacts** : nom de contact, téléphone, email. Le nom du lieu et l'adresse formatée passaient intacts. Le texte de l'interface décrivait donc l'intention du commentaire de code, pas ce que le code faisait.

Deux corrections possibles — rendre le texte honnête, ou rendre l'expurgation conforme. La seconde est celle que visait la revue M9 : diffuser l'adresse exacte de chaque livraison en attente à tous les transporteurs de l'organisation revient à leur distribuer le carnet d'adresses des clients de chaque commerçant.

**Décision produit (28/07/2026), après discussion** : les deux points n'ont pas le même statut.

| | Avant acceptation | Justification |
|---|---|---|
| Enlèvement | tout, téléphone compris | c'est un commerce : coordonnées professionnelles le plus souvent déjà publiques, dont le transporteur a besoin pour juger la course et signaler un problème à l'enlèvement |
| Livraison | commune seule — ni nom, ni rue, ni coordonnées, ni téléphone | c'est un particulier |

Une seule exception à « tout » sur l'enlèvement : les relations imbriquées `owner` et `customer`, qui peuvent porter les données du **client** de la commande. Les laisser rouvrirait par une porte de côté ce que l'expurgation de la livraison ferme — c'est le genre de fuite qui ne se voit pas, parce qu'on regarde le champ qu'on a masqué et pas celui qui le contient encore.

La commune est reconstruite depuis les champs structurés quand ils existent, sinon en retirant le premier segment de l'adresse formatée (heuristique fragile, qui renvoie **rien** plutôt qu'un fragment identifiant en cas de doute).

**Le point le plus facile à manquer** : les coordonnées. Masquer le libellé tout en transmettant le point GPS aurait été le même défaut dans un autre champ — le bouton « Itinéraire » de l'app s'en sert directement, et un point mène à la porte aussi sûrement qu'une adresse écrite. Il est masqué avec elles.

Le détecteur de fuite du script couvre maintenant `street`, `latitude` et `longitude` en plus des contacts.

Repère : **quand une interface annonce une garantie, c'est une assertion testable.** Celle-ci était fausse depuis son écriture et n'aurait été démentie par aucun test — ils vérifiaient l'absence des champs retirés, jamais la présence de ceux qui restaient.

---

## 12. P2 de la revue (28/07/2026)

Les sept points restants, dont trois structurels.

### 12.1 Projection par persona — le correctif qui referme une classe entière (M10)

Les trois modules relayaient l'objet Fleetbase **intégral**. Ce qui sortait du BFF n'était donc pas décidé ici mais en amont, et changeait silencieusement à chaque mise à jour de Fleetbase.

Toutes les fuites corrigées à la main pendant la session sont la même erreur répétée : `driver_assigned_uuid` exploitable pour usurper l'identité d'un transporteur (C2), adresses et téléphones sur les courses non réclamées (M9), relation `customer` imbriquée dans un lieu, commissions exposées au commerçant par un `include` Prisma. À chaque fois, **on retirait ce qu'on avait pensé à retirer**.

Une liste d'exclusion est fausse par défaut : un champ ajouté en amont sort sans que personne ne le décide. Une liste d'autorisation est vide par défaut : un champ nouveau ne sort pas tant qu'on ne l'a pas voulu. Le coût est symétrique — il faut penser à ajouter ce dont l'app a besoin — mais **l'oubli devient visible à l'écran plutôt qu'invisible sur le réseau**.

### 12.2 Révocation de session (M12)

Un jeton volé restait valide 24 h, et changer son mot de passe n'y changeait rien — alors que la désactivation d'un compte était déjà immédiate, les trois modules relisant `active` à chaque requête. Il manquait le pendant sur les jetons.

`tokenVersion` par compte, porté par le jeton et comparé à chaque requête, plus `POST /auth/revoquer-sessions`. **Le contrôle vit dans le garde**, pas dans chaque service : un contrôle de sécurité qu'il faut se rappeler d'appeler finit par manquer sur la route qu'on vient d'ajouter. Coût assumé : une requête par appel authentifié.

Les jetons émis avant l'ajout du champ n'ont pas de `tv` et sont comparés à la valeur par défaut : le déploiement ne coupe pas les sessions en cours.

### 12.3 Piste d'audit (F14)

Le modèle existait, rien ne l'écrivait, et les refus anti-IDOR ne laissaient qu'un `logger.warn` non structuré, perdu à la rotation. Sur un système dont **tout** le cloisonnement est applicatif, une exploitation réussie n'aurait été ni détectée ni reconstituable.

`merchantId`/`fleetId` ne savaient pas exprimer un transporteur et obligeaient à une colonne par persona : remplacés par le couple `actorType` + `actorId`. L'écriture ne bloque pas la réponse — on est dans le chemin d'un refus, et une base d'audit indisponible ne doit pas transformer un 403 propre en 500 — mais son échec est journalisé en `error`, seul cas où la disparition d'une trace doit se voir.

### 12.4 Compensation de l'inscription commerçant (archi #11)

L'inscription écrit dans deux systèmes sans transaction commune : Fleetbase d'abord (Vendor puis Contact), le BFF ensuite. Un échec à la deuxième ou troisième étape laissait un `Vendor` que plus rien ne référençait — invisible du BFF, non réutilisable, et qu'une nouvelle tentative avec le même email **dupliquait** au lieu de récupérer.

La compensation supprime le Vendor et **ne masque jamais l'erreur d'origine** : si la suppression échoue à son tour, l'uuid est journalisé pour un nettoyage manuel, et c'est l'échec initial qui remonte — c'est lui qui intéresse l'appelant.

### 12.5 Nettoyage du schéma (archi #15)

Supprimés : `fleetbaseSanctumToken` (jamais écrit ni lu depuis que le module commerçant est passé au cache local — et il portait l'annotation « encrypted at rest » alors qu'aucun chiffrement n'existe), `emailVerifiedAt`, `appVersion`, `lastUsedAt`.

Le motif commun mérite d'être nommé : **un champ mort au nom évocateur est un piège**. `lastUsedAt` laissait croire que les jetons push étaient purgés selon leur fraîcheur ; « encrypted at rest » dispensait de vérifier le chiffrement. Une annotation fausse est pire que pas d'annotation.

**Non corrigé délibérément** : `create_login: false` sur la création de Contact. Chaque inscription commerçant provisionne un User Fleetbase inutilisé — une surface d'authentification gratuite. Mais l'inscription est un chemin validé par test réel, et le paramètre n'est pas éprouvable dans ce bac à sable : le passer à l'aveugle risquerait de casser un parcours qui fonctionne. Documenté dans le code, à traiter avec un test sous la main.

### 12.6 Fusion des désérialiseurs Dart (archi #14)

Les deux modèles de commande désérialisaient les mêmes champs chacun de son côté, et avaient **déjà divergé** : seul l'un traitait `tracking_number` sous ses deux formes, et les replis d'identifiant différaient. Une troisième copie de la lecture des coordonnées vivait dans `SavedAddress`.

`fleetbase_json.dart` porte les lectures communes. `OrderPlace` disparaît au profit de `Place`, dont il n'était qu'un sous-ensemble.

Un défaut trouvé en fusionnant : `Place.latitude/longitude` valaient `0` quand les coordonnées manquaient — ce qui place le point **au large du golfe de Guinée**, et l'itinéraire y aurait mené sans rien signaler. Le cas est devenu courant depuis que le BFF retire les coordonnées d'une course non réclamée. Elles sont désormais nulles, et la navigation refuse plutôt que d'ouvrir une carte au hasard. `SavedAddress` garde son repli à 0, délibérément : une adresse enregistrée sert à pré-remplir une commande, qui exige un point.

### 12.7 État

BFF : compile. **Non exécuté** — pas d'instance ici. App : `flutter analyze` à passer.

**Prérequis** : `npm run prisma:migrate` puis `prisma generate` (trois colonnes `tokenVersion`, refonte d'`AuditLog`, quatre colonnes supprimées).

---

## 13. Interface commerçant — carte, favoris, options de course (28/07/2026)

Série de demandes utilisateur sur l'écran de création, plus ce que la lecture du modèle Fleetbase a révélé de disponible et d'inexploité.

### 13.1 Ce que Fleetbase portait déjà et qu'on n'utilisait pas

La lecture du `$fillable` du modèle `Order` (28/07/2026) a montré cinq colonnes natives ignorées : `scheduled_at`, `driver_assigned_uuid`, `pod_required`/`pod_method`, et surtout **`adhoc_distance`**.

Cette dernière répond à une question produit qu'on avait laissée ouverte — le rayon de diffusion des courses adhoc — et à laquelle on s'apprêtait à répondre par du code côté BFF. Elle est native : c'est le dispatch géospatial de Fleetbase qui l'applique. Repère : **avant de construire un filtre sur un système tiers, chercher la colonne qui le porte déjà.**

### 13.2 La carte règle un défaut, pas seulement un confort

Toute adresse saisie librement tombait au **centre d'Alger** : le dispatch choisissait donc le transporteur le plus proche d'un point faux, et deux livraisons opposées dans la ville avaient exactement les mêmes coordonnées. Un formulaire texte ne peut pas produire une position.

Le formulaire **refuse désormais l'envoi** sans point désigné, plutôt que d'en inventer un. C'est le changement qui compte : une valeur par défaut plausible est plus nuisible qu'une absence, parce qu'elle ne se signale jamais.

OpenStreetMap plutôt que Google Maps (décision utilisateur) : pas de clé API, pas de facturation au chargement, cohérent avec l'auto-hébergement. Le repère reste au centre et c'est la carte qui bouge — le doigt ne masque jamais le point visé, ce qu'un marqueur déplaçable au toucher fait systématiquement.

**Le géocodage passe par le BFF**, jamais par l'app. Nominatim exige un `User-Agent` identifiant et plafonne à une requête par seconde : depuis des milliers d'appareils, chacun s'annoncerait comme Dart et le débit cumulé ferait bloquer notre plage d'adresses. Un seul appelant, identifié, dont on maîtrise le rythme — et le jour où l'on hébergera notre propre instance, une seule classe changera.

### 13.3 Favoris plutôt qu'assignation directe (décision produit)

La demande initiale était de choisir nommément un transporteur. Techniquement gratuit — `driver_assigned_uuid` est accepté à la création — mais en tension avec la thèse du produit : l'effet réseau suppose un pool **mutualisé**, et des désignations nominatives feraient glisser la place de marché vers des relations bilatérales où les nouveaux entrants ne démarrent jamais.

Retenu après discussion : des **favoris avec repli**. Sollicités en premier, la course retombe dans le pool commun si aucun n'est disponible. La préférence est respectée, la liquidité du réseau préservée.

**Ce que le repli fait, et ne fait pas** : il choisit *au moment de la création*. Il ne reprend pas la course si le favori l'ignore ensuite — ce second repli, différé, demande une tâche de fond surveillant les courses assignées et non démarrées. En attendant, une course confiée à un favori inactif reste bloquée : limite à connaître avant d'activer l'option en production.

La liste proposée se limite aux transporteurs **ayant déjà livré pour ce commerçant**. Exposer l'annuaire complet livrerait la composition du réseau à quiconque crée un compte, et n'a aucune utilité : on ne met en favori que quelqu'un qu'on a vu travailler. L'endpoint d'ajout applique le même contrôle — sans lui, il permettrait de sonder l'existence d'un uuid arbitraire.

### 13.4 Catégorie de véhicule

Fleetbase n'a pas de filtre natif par *catégorie* : `vehicle_assigned_uuid` désigne un véhicule précis. Sa notion de `Fleet` serait le bon foyer à terme, mais suppose de provisionner des flottes qui n'existent pas. En attendant : le type vit dans `meta`, le transporteur déclare le sien, et le BFF filtre les opportunités.

Deux règles qui évitent d'exclure à tort. Une exigence est un **minimum, pas une égalité** — demander une voiture n'écarte pas un utilitaire. Et un transporteur qui n'a **rien déclaré voit tout** : être écarté du réseau par un champ non rempli serait le pire des défauts silencieux.

### 13.5 Défauts trouvés en relisant

Quatre, tous dans du code écrit dans la même session :

1. `_resolveLabel()` appelait `setState` depuis `initState` — interdit avant le premier rendu.
2. ~~`DropdownButtonFormField.initialValue` n'existe que depuis Flutter 3.35~~ — **correction : j'ai eu tort.** J'ai remplacé `initialValue` par `value` par prudence, sans pouvoir vérifier la version de Flutter de l'utilisateur. Sa toolchain est postérieure à 3.33, donc `initialValue` existe et c'est `value` qui est déprécié : mon correctif a introduit les trois avertissements qu'il prétendait éviter. Leçon : **une précaution prise sans vérifier le fait qu'elle suppose est un pari, pas une précaution** — la version de Flutter était consultable en une commande.
3. `context` lu après un `await` dans le chargement des favoris, sans garde `mounted`.
4. `_vehicleType` survivait à la déconnexion : le transporteur suivant sur le même appareil héritait de la catégorie du précédent, et voyait une liste filtrée sur un critère qui n'était pas le sien. Même famille que le défaut de `stopTracking()` en §10.4 — **un état de session qui n'est pas remis à zéro à la déconnexion**.

### 13.6 Non fait, et pourquoi

~~**Le prix affiché.**~~ **Ajouté après retour utilisateur**, sous une forme qui contourne la question du barème : le commerçant **propose** un montant, le transporteur le voit et décide. Ça résout le vrai problème — un transporteur qui ignore ce que rapporte une course ne peut pas la choisir — sans préempter la tarification : le marché ajuste, et les montants observés au pilote informeront le barème plutôt que l'inverse. Le prix figure en tête de carte dans la liste des opportunités, pas seulement au détail : l'enterrer obligerait à ouvrir chaque course pour le connaître.

**La signature comme preuve.** Le contrat serveur l'accepte, rien ne la recueille côté transporteur. L'app ne la propose donc pas : offrir une option qui promettrait une trace inexistante est pire qu'une option absente.

**La duplication d'une commande**, le suivi cartographique temps réel, les arrêts multiples : reportés, aucun n'est bloquant.

### 13.7 État

BFF : compile. **Non exécuté**. App : `flutter analyze` à passer — et cette fois il compte plus que d'habitude, la carte introduisant deux dépendances dont je n'ai pu vérifier aucune signature d'API.

**Prérequis** : `flutter pub get`, puis `npm run prisma:migrate` et `prisma generate` (modèle `DriverFavourite`, colonne `vehicleType`).

### 13.8 Préparer la tarification calculée sans la décider

Le barème — au kilomètre, à la durée, avec majorations d'horaire — viendra plus tard (décision utilisateur). Ce qui ne peut **pas** attendre, c'est la capture de ses données d'entrée.

**Pourquoi ce n'est pas rattrapable.** La distance dépend du géocodage et du réseau routier au moment de la course : recalculée six mois après sur les mêmes adresses, elle ne donnera pas le même chiffre. Sans ces valeurs figées, les commandes du pilote ne permettront pas de répondre à « qu'aurait coûté ce trajet au tarif X ? » — donc ne serviront pas à calibrer quoi que ce soit. On aurait un historique de prix sans les trajets qui les justifiaient.

`PricingService.buildInputs()` enregistre sur chaque commande : distance, méthode de calcul de cette distance, catégorie de véhicule, horodatage de l'enlèvement, plus l'heure et le jour extraits séparément — ce sont eux qui porteront les majorations, et les extraire au moment du calcul supposerait de connaître le fuseau d'alors.

**La distance est à vol d'oiseau, et c'est dit.** Elle sous-estime la distance routière de 20 à 40 % en ville. Étiquetée `distance_method: 'haversine'`, elle pourra coexister avec une distance routière le jour où OSRM sera auto-hébergé — sans que l'historique devienne ambigu.

**L'origine du prix est enregistrée avec lui** (`price_source`). Sans elle, l'historique mélangerait les montants proposés par les commerçants et ceux calculés par la plateforme, et la calibration se ferait sur ses propres résultats — ce qui validerait la formule quoi qu'elle vaille.

`pricing_inputs` n'est **pas** projeté vers les clients : c'est de la donnée de calibration, sans usage dans les applications. Le prix et son origine, eux, atteignent le transporteur — un prix proposé et un tarif de plateforme ne se négocient pas de la même façon.

**L'appel est posé de bout en bout, la formule seule manque.** `POST /commercant/devis` existe, l'écran de création l'interroge dès que les deux points sont connus puis à chaque changement de paramètre tarifaire, et affiche ce qu'on lui répond. Aujourd'hui `amount` vaut `null` et la saisie manuelle reste ; le jour où la formule existera, l'écran basculera seul sur le tarif affiché.

Poser la couture avant la formule évite le scénario habituel : un barème décidé, puis trois semaines à recâbler les écrans pour l'afficher.

**Le calcul est centralisé côté serveur, sans exception.** L'app ne connaît aucun barème et n'en appliquera jamais : un calcul dupliqué côté client dériverait au premier changement de tarif, et corriger un prix demanderait alors une mise à jour d'application — sur des téléphones qu'on ne contrôle pas. Deux entrées mènent au même `PricingService` : la création de commande et le devis.

Quand le barème sera tranché : implémenter `computeQuote()` et basculer `PRICING_MODE=computed`. Aucun appelant ne change, ni serveur ni client. Et le barème pourra être éprouvé rétroactivement sur les vraies courses du pilote avant d'être activé.

---

## 14. Refus motivé, duplication, notifications commerçant (29/07/2026)

Trois fonctionnalités retenues parmi quatre proposées la veille — la quatrième, la contre-proposition de prix par le transporteur, est écartée sur décision explicite et documentée comme piste dans `docs/specs_echango_delivery.md` §6.1.

### 14.1 Le refus motivé sert deux besoins qui n'ont rien en commun

Sans trace, un refus se manifeste par une absence : la course reste dans la liste, le transporteur la fait défiler à chaque rafraîchissement, et personne n'apprend rien.

**Pour le transporteur**, une course écartée disparaît. C'est la seule façon de rendre une liste d'opportunités exploitable : sans ce filtre, ce qu'il ne veut pas noie ce qu'il voudrait. Et c'est aussi le seul retour visible du geste — un refus sans effet à l'écran est indiscernable d'une fonctionnalité en panne.

**Pour la plateforme**, le motif est la donnée manquante du barème. `PricingService` capture ce qu'une course *valait* (distance, horaire, véhicule) ; le refus dit ce que le marché en *pense*. Un « prix insuffisant » sur 12 km à 22 h vaut mieux que n'importe quelle estimation faite au bureau.

**Les entrées tarifaires sont copiées sur le refus, pas référencées.** Une référence à la commande suffirait si la commande était immuable : elle ne l'est pas, elle peut être modifiée ou supprimée. C'est l'appariement « ce qui était offert » / « refusé pour tel motif » qui a de la valeur, et il disparaît avec l'original.

**`indisponible` est une soupape, pas un motif.** Sans elle, un transporteur qui refuse simplement parce qu'il finit sa journée choisirait un motif au hasard et empoisonnerait les six autres. Une catégorie « aucune information » qu'on sait ignorer vaut mieux qu'une donnée fausse qu'on croit lire.

### 14.2 Rendre une course assignée n'est pas refuser une proposition

Deux situations passent par le même endpoint, avec des conséquences opposées :

- **course diffusée non réclamée** → elle quitte la liste de ce transporteur, et de lui seul. Rien ne change pour les autres ni pour le commerçant : refuser une proposition n'est pas un évènement ;
- **course assignée à lui** (favori sollicité en premier) → elle est détachée, remise en diffusion, et le commerçant est prévenu.

Le second cas lève une partie d'une limite signalée de longue date par `pickAvailableFavourite()` : une course confiée à un favori indisponible restait bloquée jusqu'à intervention manuelle. Le refus traite le cas où le transporteur *sait* qu'il ne la prendra pas. Il ne traite toujours pas celui du favori qui ignore la course sans rien dire — ce repli-là demande une tâche de fond, et le délai est une décision produit.

**Le détachement passe AVANT l'enregistrement du refus.** Si Fleetbase refuse l'écriture, la course reste assignée : enregistrer quand même un refus produirait un écran qui affiche « rendue » et une course toujours là. On échoue bruyamment plutôt que d'inscrire un refus sans effet.

**Une course démarrée n'est pas refusable.** À ce stade le transporteur est engagé, souvent en route ; la sortie est le signalement d'échec, qui laisse une trace et une preuve. Rendre la course par un simple refus effacerait cette obligation.

⚠️ `releaseOrderToPool()` (`PUT /int/v1/orders/{uuid}`, enveloppe `{ order: ... }`) **n'est pas validé par un appel réel** — aucune instance Fleetbase joignable depuis ce bac à sable. La forme repose sur l'analogie avec la création, qui a tenu jusqu'ici (§5.6), mais l'analogie n'est pas une preuve. C'est le premier point à éprouver.

### 14.3 Duplication : un modèle, pas une commande

`GET /commercant/commandes/:id/modele` renvoie les champs à reprendre ; l'application rouvre le formulaire pré-rempli. Elle ne crée rien.

**Pourquoi ne pas créer directement.** Une duplication silencieuse recopierait aussi ce qui ne se duplique pas : un enlèvement programmé la veille à 8 h, recréé aujourd'hui, est dans le passé. `scheduledAt` est donc délibérément **absent** du modèle — c'est le seul champ qu'on ne peut pas reprendre sans mentir, et le laisser vide fait retomber sur « dès que possible », qui est vrai. Accessoirement, une livraison réelle facturée à quelqu'un ne doit pas pouvoir naître d'un tapotement.

**Défaut trouvé en construisant le modèle : les contacts étaient jetés.** `createPlace()` ne prenait qu'un nom et des coordonnées. Le formulaire demandait le nom et le téléphone du contact d'enlèvement et de livraison, les validait, les envoyait — et ils s'arrêtaient au DTO. Le transporteur arrivait donc devant une adresse sans savoir qui appeler, ce qui est *exactement* la situation que constate le signalement « client absent ». Le téléphone va désormais sur la colonne native `phone`, le nom dans `meta.contact_name` (le modèle `Place` n'a pas de champ dédié), et la projection le remonte — uniquement dans la branche complète, ce nom étant précisément ce que l'expurgation d'une course non réclamée retire.

C'est encore le motif récurrent de la veille, inversé : l'app envoyait, le serveur jetait.

### 14.4 Notifier suppose d'abord de savoir que quelque chose a changé

Fleetbase n'appelle pas le BFF. Rien, dans le flux normal, ne nous prévient qu'un transporteur a pris une course — et l'évènement survient parfois **hors de nos routes** : un driver peut accepter depuis l'application, mais un opérateur peut aussi assigner depuis la console Fleetbase, et ce second cas ne traverse aucun endpoint du BFF. Un déclenchement posé dans nos services n'en verrait qu'un ; l'autre disparaîtrait en silence, soit le pire mode de panne, puisqu'il ressemble à « rien ne s'est passé ».

D'où `OrderReconcilerService` : un passage périodique qui compare l'état amont au cache local. Les webhooks Fleetbase sont la bonne cible à l'échelle — ils supposent une URL joignable, une vérification de signature et un déploiement configuré, prérequis de mise en production et non de développement. Le journal de notifications qu'alimente le scrutateur ne changera pas quand la source deviendra un webhook.

**Ce que le scrutateur corrige au passage.** `Order.status` était figé à sa valeur de création, jamais resynchronisé — il ne décrivait pas une commande mais l'instant de sa création. Le tenir à jour en fait la mémoire qu'il prétendait être, et **c'est de cette mémoire que viennent les transitions** : sans un « avant », il n'y a pas d'évènement, seulement un état.

**Deux corrections de vocabulaire s'imposaient d'un coup.** La création écrivait `'pending'`, un statut qui n'appartient pas au vocabulaire de Fleetbase ; l'annulation écrivait `'cancelled'` là où Fleetbase dit `'canceled'`. Tant que personne ne comparait cette colonne à l'amont, l'écart était invisible. Dès qu'on la compare, il produit une transition fantôme à chaque passage — donc une notification d'annulation en boucle.

**La mémorisation vient après les notifications.** Si l'écriture échoue, le passage suivant reverra la même transition et renotifiera : un doublon visible, préférable à un évènement perdu, qui ne se rattrape jamais.

**Une commande absente de Fleetbase n'est pas conclue terminée.** Un appel manqué la ferait disparaître définitivement du suivi. On passe.

### 14.5 Le journal est la source de vérité, le push ne serait qu'un accélérateur

Un push est un message sans accusé de réception utile : téléphone éteint, jeton périmé après réinstallation, notification balayée sans être lue. S'il était le seul support, l'information disparaîtrait avec lui — et c'est précisément celle qu'un commerçant vient chercher en rouvrant l'application.

⚠️ **L'envoi push n'est pas branché**, et ce n'est pas un oubli. Le commerçant n'est volontairement pas un `User` Fleetbase (`docs/specs_bff.md`), donc le push natif de Fleetbase, qui route par `UserDevice`, ne peut pas l'atteindre ; et aucun credential serveur Firebase n'est configuré dans ce déploiement. Les jetons d'appareil sont bien collectés (`DeviceToken`, endpoint existant) : **il ne manque que l'expéditeur.** L'application relève donc le journal par interrogation, et la pastille de l'écran d'accueil est aujourd'hui le seul signal.

**Le compte de non-lues vient du serveur**, pas d'un `where(...).length` local : la liste est plafonnée, et compter sur une liste tronquée donnerait une pastille fausse dès qu'un commerçant accumule des évènements.

**Cinq types, pas plus.** Une notification qui n'appelle aucune décision est du bruit, et le bruit fait désactiver les notifications — après quoi les trois qui comptaient ne passent plus non plus. Les états intermédiaires du dispatch (`dispatched`, `enroute`) sont délibérément exclus : ils changent souvent, n'appellent aucune action, et le suivi de la commande les montre déjà à qui les cherche.

**Deux notifications ne passent pas par le scrutateur** et sont émises directement, parce qu'aucun changement d'état Fleetbase ne les trahirait : l'échec de livraison (pas de statut « failed » natif confirmé, §6.5) et le désistement d'un favori.

### 14.6 Défauts trouvés en chemin

- **`_firstItemDescription` n'existait pas.** Appelée par `MerchantOrder.fromJson`, jamais définie : l'application ne compilait pas. Introduite la veille en ajoutant l'affichage du contenu du colis, invisible faute de toolchain Flutter ici — et confirmée par le `flutter analyze` de l'utilisateur pendant cette session.
- **`'Order #$widget.orderId'`** interpolait l'objet `widget` puis affichait « .orderId » en littéral. L'écran de signalement montrait donc le nom de la classe suivi d'un fragment de code. Accolades ajoutées, libellé passé en français au passage (le reste de cet écran est encore en anglais — reste à faire).
- **`RadioListTile` évité.** Le couple `groupValue`/`onChanged` est déprécié depuis Flutter 3.32 au profit de `RadioGroup`. Des `ListTile` sélectionnables font le même travail sans pari sur la version installée — la leçon de la veille sur `initialValue` : une précaution prise sans vérifier le fait qu'elle suppose est un pari.
- **`Color.withValues` retiré.** Il exige Flutter 3.27 alors que le pubspec déclare `>=3.20`. La couleur de l'icône portait déjà la distinction ; la pastille teintée n'apportait rien qui justifie une contrainte de version.

### 14.7 État de vérification

BFF : `tsc --noEmit` passe. **Le client Prisma n'a pas pu être régénéré** — le proxy sortant bloque `binaries.prisma.sh` en 403, même avec `PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING=1`. Les trois nouveaux modèles sont donc typés `any` à la compilation ici : la vérification de types sur `OrderDecline`, `MerchantNotification` et les colonnes ajoutées à `Order` reste à faire côté utilisateur, après `prisma generate`.

App : **jamais compilée** (pas de toolchain Flutter dans ce bac à sable). `flutter analyze` reste la vérification manquante.

⚠️ **Prérequis** : `npm run prisma:migrate` (deux modèles, quatre colonnes sur `Order`), puis `prisma generate`. Nouvelles variables d'environnement facultatives : `RECONCILER_ENABLED`, `RECONCILER_INTERVAL_MS`.

---

## 15. Lot léger côté commerçant — le rattrapage serveur→app (29/07/2026)

Suite de `docs/comparaison_marche_commercant.md`. La coupe suit une seule règle : **est léger ce dont la capacité existe déjà côté serveur et qu'il suffit de servir au commerçant ; est lourd ce qui engage le modèle d'affaires.**

Écartés délibérément, et ce sont des décisions produit et non du développement : le barème (`computeQuote()`), la page de suivi pour le destinataire final, le paiement à la livraison, la notation du transporteur, la facturation.

### 15.1 `proof_url` sortait vers le commerçant, sans protection

Le champ figurait dans `ORDER_FIELDS`, donc la projection commerçant le servait. C'est l'URL que Fleetbase construit depuis son propre `APP_URL` : injoignable depuis un téléphone, et **protégée par rien**.

Toute la discipline posée côté transporteur le 28/07 — jamais l'URL Fleetbase, toujours un chemin BFF authentifié — était contournée ici par un champ oublié dans une liste d'autorisation. C'est le mode d'échec propre aux listes d'autorisation : elles rendent l'oubli visible à l'écran, pas l'inclusion de trop.

Le champ Dart `Order.proofUrl` a été supprimé avec lui. Il aurait toujours valu `null` : un champ mort au nom évocateur est un piège, et le prochain écran l'aurait affiché en croyant la preuve accessible — exactement l'erreur du `lastUsedAt` supprimé lors du P2.

### 15.2 La preuve n'atteignait pas celui qui en a besoin

Le transporteur photographie, Fleetbase stocke, le BFF relaie de façon authentifiée — **au transporteur seul**. Le commerçant, qui devra répondre à son propre client et éventuellement le rembourser, ne voyait rien : le seul destinataire du justificatif était celui qui l'avait produit.

Deux routes symétriques de celles du transporteur : `GET /commercant/commandes/:id/preuve` (preuve de livraison) et `GET /commercant/preuves/:id` (photo d'un signalement d'échec). L'appartenance se vérifie en deux temps pour la seconde — le signalement porte l'uuid de la commande, et c'est le cache local qui dit à quel commerçant elle appartient.

Les signalements sont désormais joints au détail de commande, **toute la série** : une livraison tentée trois fois n'est pas celle tentée une fois, et chaque tentative porte sa propre photo.

⚠️ La preuve de livraison dépend de `proof_url` **sur la commande Fleetbase, dont le renseignement n'est pas vérifié**. La capture crée bien une ressource `Proof` ; que Fleetbase reporte son URL sur la commande reste à confirmer sur une vraie livraison avec `pod_required`. Si le champ reste vide, la route répond « pas de preuve » — indiscernable, pour l'appelant, d'une livraison sans preuve exigée.

### 15.3 La position existait, et n'était servie qu'à la flotte

Le transporteur remonte sa position, le BFF la miroite sur `DriverAccount`, le module flotte l'affiche. Le module commerçant ne l'exposait pas. `GET /commercant/commandes/:id/position` sert le miroir local — et non l'historique Fleetbase, dont l'endpoint `/positions` n'offre aucun filtre par transporteur (§10).

**Un point, pas un suivi.** Ni itinéraire ni heure d'arrivée : celle-ci demande un moteur de routage non auto-hébergé. Attendre OSRM pour ne rien montrer laisserait le commerçant devant un statut textuel alors que la donnée est là.

**La fraîcheur accompagne toujours le point.** Une position vieille d'une heure présentée comme actuelle est pire qu'aucune position : le commerçant croirait son transporteur immobile alors qu'il a perdu le réseau, et appellerait pour rien. Au-delà de dix minutes le marqueur passe au gris — la couleur se lit avant la légende.

### 15.4 Le téléphone du transporteur, envoyé et jamais lu

`projectOrderForMerchant` exposait déjà `driver_assigned: { name, phone, photo_url }`. Le modèle Dart ne lisait que le nom. Un commerçant qui voulait savoir où en était sa livraison n'avait aucun moyen d'appeler le coursier — alors que le numéro était déjà dans la réponse HTTP posée sur son téléphone.

Le motif du projet dans sa forme la plus pure, et la correction tient en deux lignes.

### 15.5 Vingt-cinq commandes, puis plus rien

`GET /commercant/commandes` pagine depuis toujours ; l'app n'envoyait **aucun paramètre**. Au-delà de 25 livraisons, les plus anciennes devenaient inaccessibles sans que rien ne le signale. Même nature que le plafond de 100 corrigé côté transporteur : une liste tronquée en silence n'est pas partielle, elle est **fausse** pour qui la lit comme complète.

Le total vient du serveur, jamais d'une supposition sur la taille de page : c'est ce qui distingue « dernière page » de « page pleine par coïncidence ».

**La recherche est locale, et l'écran le dit.** Une recherche serveur serait plus juste, mais tout le filtrage du BFF est applicatif — Fleetbase ignore les filtres de requête — donc elle imposerait de parcourir toute l'organisation à chaque frappe. Le bouton « charger plus » étend le périmètre de recherche autant que la liste.

### 15.6 Poids et fragilité : le contrat les acceptait, le formulaire ne les envoyait pas

`OrderItemDto` déclare `weight` et `fragile` depuis l'origine. Le formulaire envoyait une description et `quantity: 1` en dur. Or c'est précisément ce qui permet au transporteur de juger si sa moto suffit — donc ce qui fonde son refus pour `colis_inadapte`, motif que nous venons d'ajouter.

La fragilité est une case à cocher et non une mention libre : noyée dans les instructions, elle se lit après le chargement.

### 15.7 Le carnet d'adresses servait du Fleetbase brut

`getAddresses()` renvoyait les objets `Place` intégraux — seul reliquat de la fuite M10 corrigée partout ailleurs le 28/07. Ce qui sortait était donc décidé par Fleetbase, et aurait changé à sa prochaine mise à jour. Projeté comme le reste.

### 15.8 `ProofImage` extrait plutôt que dupliqué

Le widget était privé à l'écran transporteur. Le commerçant en avait besoin à l'identique : `widgets/proof_image.dart`, partagé. Deux copies auraient divergé — et c'est ce widget qui porte le piège du `FutureBuilder` reconstruit à chaque trame, corrigé une fois pour les deux profils.

### 15.9 Vérification

BFF : `tsc --noEmit` passe.

App : **jamais compilée** (pas de toolchain). Trois API `flutter_map` utilisées ici pour la première fois ont été **vérifiées contre la documentation de la version épinglée (7.0.2)** plutôt que supposées : `MapOptions.interactionOptions`, les constantes `InteractiveFlag.drag`/`pinchZoom`, et le `Marker({point, width, height, child})` — `child` et non `builder`, la signature ayant changé entre versions majeures. C'est l'application directe de la leçon du 28/07 sur `initialValue` : **une précaution prise sans vérifier le fait qu'elle suppose est un pari**, et l'inverse vaut aussi — une API qu'on croit connaître se vérifie en une minute.

`flutter analyze` reste la vérification manquante.

---

## 16. Paiement à la livraison — mise en œuvre de la Voie B (29/07/2026)

Étude et arbitrage : `docs/specs_paiement_livraison.md`. Le modèle retenu est le
Voie B — **le transporteur encaisse et conserve, l'application tient le
registre, Echango ne touche jamais l'argent**.

### 16.1 Le registre enregistre des faits, jamais un solde

`CashCollection` (espèces perçues à la porte) et `CashRemittance` (espèces
rendues au commerçant) sont des évènements ; la dette s'en déduit par
différence. Aucun compteur n'est stocké.

Un solde incrémenté à chaque écriture dérive au premier échec partiel, et plus
rien ne dit alors laquelle des deux valeurs — le compteur ou les faits — fait
foi. Recalculer coûte une agrégation. Se tromper coûte la confiance dans le
registre, qui est ici **le seul produit que nous vendons** : nous ne détenons
pas l'argent, nous n'en tenons que le compte.

**Les remises non confirmées ne réduisent pas la dette.** Tant que la seconde
partie n'a rien confirmé, une remise est une affirmation, pas un fait — les
compter laisserait un transporteur effacer sa dette en la déclarant. Et une
remise n'est jamais confirmable par son propre déclarant : ce serait une
répétition, pas une preuve.

### 16.2 Le montant à encaisser n'est pas la rémunération, et rien ne doit les rapprocher

`meta.cod_amount` est ce que le destinataire doit au **commerçant** ;
`meta.price` est ce que le commerçant doit au **transporteur**. Ils circulent en
sens inverse. Les additionner, les substituer ou les afficher sans les nommer
serait l'erreur fondatrice de tout le mécanisme — d'où deux champs, deux
libellés distincts sur chaque écran, et l'avertissement répété dans le schéma,
le DTO et les deux modèles Dart.

### 16.3 Le défaut qui aurait tout vidé de son sens

La garde « pas de clôture sans déclaration d'encaissement » avait d'abord été
posée sur `POST /transporteur/commandes/:id/terminer`.

**L'application n'emprunte pas ce chemin.** Elle suit les transitions que le
serveur lui propose (`next-activity`) et applique la transition terminale par
`update-activity` — mécanisme mis en place le 28/07 précisément pour ne pas
reconstruire la machine à états côté client. La garde était donc **décorative** :
le chemin réellement emprunté la contournait, et une livraison encaissée se
serait close sans que l'argent figure nulle part. C'est-à-dire une somme perdue
pour le commerçant, sans trace de qui la détient.

Corrigé en factorisant `settleCashIfDue()`, appelée depuis **les deux** chemins.
La leçon vaut au-delà : une garde se pose sur le chemin qu'on emprunte, pas sur
celui qui porte le nom de l'action.

**L'ordre est aussi une décision** : le registre s'écrit **avant** la clôture
Fleetbase. Si l'écriture échoue, la commande reste ouverte et le transporteur
peut réessayer. Dans l'ordre inverse, on obtiendrait une livraison close et un
encaissement fantôme — soit exactement ce qu'on cherche à empêcher.

### 16.4 Deux garde-fous, tous deux logiciels

Un transporteur intégré borne son risque par des agences et un dépôt quotidien.
Nous n'avons ni l'un ni l'autre : les seuls instruments disponibles sont
logiciels, et ils remplacent une contrainte physique.

**Plafond de dette** (`COD_DEBT_CEILING`, 20 000 par défaut) : au-delà, plus
aucune course encaissée n'est confiée à ce transporteur **pour ce commerçant**.
Le montant de la course à venir entre dans le calcul — autoriser celle qui fait
franchir le plafond viderait le plafond de son sens. C'est le mécanisme de
DoorDash, transposé.

**Courses encaissées réservées aux favoris** (`COD_FAVOURITES_ONLY=true`) :
confier des espèces à quelqu'un qu'on n'a jamais vu travailler est le scénario
que la Voie B ne sait pas couvrir. Et si aucun favori n'est disponible, la
course **est refusée** au lieu de partir au pool : un repli silencieux
contournerait la garantie au moment précis où elle compte, et le commerçant
croirait sa règle appliquée.

Conséquence assumée, dite à l'écran plutôt que découverte au refus : un
commerçant sans favori ne peut pas encore faire de livraison encaissée.

### 16.5 L'écart se déclare à la porte, dans une liste fermée

Cinq motifs (`somme_incomplete`, `refus_de_payer`, `pas_de_monnaie`,
`montant_conteste`, `autre`), obligatoires dès que le montant perçu diffère de
celui annoncé. Un champ libre ne se compte pas, et c'est le comptage qui
remplace l'enquête au dépôt — 3 à 5 % d'erreurs et 15 % de trésorerie en suspens
dans les rapprochements manuels du marché.

Percevoir **plus** que dû est refusé plutôt qu'absorbé : soit le montant annoncé
était faux, soit la déclaration l'est, et les deux appellent une correction
humaine.

La feuille de déclaration **pré-remplit le montant attendu** — le cas de très
loin le plus fréquent, et une saisie de moins devant une porte — tout en le
laissant modifiable. Le masquer derrière un second écran pousserait à valider le
montant théorique, c'est-à-dire à perdre exactement l'information recherchée.

### 16.6 Ce que le registre ne décide pas

**Qui supporte la perte** en cas d'écart ou de non-remise. C'est une règle métier
non tranchée (§9 du document d'étude), et l'encoder l'aurait tranchée par
défaut. Le registre constate ; l'arbitrage viendra se poser dessus.

### 16.7 Un seul écran pour les deux profils

Transporteur et commerçant regardent le **même registre depuis les deux bouts** :
ce que l'un doit est ce que l'autre attend, et les gestes sont symétriques —
déclarer, confirmer, contester. `CashScreen(persona:)` et `CashState` sont
partagés ; seuls les mots changent, et ils comptent : « je dois » n'est pas « on
me doit », même quand c'est le même nombre.

La dette est présentée **par contrepartie et jamais globalement** : le
transporteur ne doit rien « à la plateforme », il doit une somme à chaque
commerçant, et c'est ainsi que ça se règle. Un total unique n'aurait aucun
destinataire — il est affiché comme repère, avec la phrase qui le dit.

### 16.8 Défaut trouvé en relisant

Une interpolation Dart échappée (`\$currency` au lieu de `$currency`) dans la
carte d'encaissement du commerçant : l'écran aurait affiché le texte littéral
« $currency » à la place de la devise. Introduite par une substitution
automatisée, invisible à la relecture rapide — et impossible à voir sans
compiler.

### 16.9 Vérification

BFF : `tsc --noEmit` passe. **Client Prisma non régénéré** (le proxy bloque
`binaries.prisma.sh`), donc `CashCollection` et `CashRemittance` sont typés
`any` ici : deux agrégations ont demandé des annotations explicites pour
compiler, et la vérification de types réelle reste à faire après
`prisma generate`.

App : **jamais compilée**. `flutter analyze` reste la vérification manquante, et
ce lot est celui où le plus de Dart neuf a été écrit sans toolchain.

⚠️ **Prérequis** : `npm run prisma:migrate` (deux modèles, une colonne sur
`Order`) puis `prisma generate`. Nouvelles variables facultatives :
`COD_DEBT_CEILING`, `COD_FAVOURITES_ONLY`.

**Non éprouvé par un test réel** : la chaîne complète encaissement → dette →
remise → confirmation. C'est le premier scénario à jouer, et il demande deux
comptes (un transporteur, un commerçant) et une commande avec `codAmount`.

---

## 17. Règlement net et commission Echango (29/07/2026)

Deux décisions produit prises ce jour : le transporteur **déduit sa rémunération
de l'encaissement**, et Echango se rémunère par une **commission sur le prix du
transport**.

### 17.1 Le calcul qui simplifie tout

Le montant à encaisser vaut normalement marchandise + frais de livraison, et
c'est le commerçant qui décide si le transport y est inclus. On s'attendait à
deux règlements distincts. Il n'y en a qu'un :

```
frais inclus     : client paie 5 000, dette = 5 000 − 500 = 4 500
frais non inclus : client paie 4 500, dette = 4 500 − 500 = 4 000
```

Dans les deux cas **`dette = perçu − rémunération`**. Le drapeau
`codIncludesDelivery` ne pilote donc aucun calcul : il sert au commerçant à lire
son chiffre d'affaires, et au transporteur à expliquer au destinataire ce qu'il
paie. C'est dit explicitement partout, faute de quoi quelqu'un finira par écrire
une branche conditionnelle qui n'a pas lieu d'être.

### 17.2 La dette devient signée, et il le fallait

Borner la dette à zéro effaçait un cas entier : une course **sans encaissement**,
ou dont le client n'a payé qu'une partie, laisse le commerçant débiteur du
transporteur. Le transporteur aurait travaillé sans que rien ne l'enregistre.

```
position = encaissé − rémunérations − remises confirmées + versements confirmés
```

Positive : le transporteur détient des espèces. Négative : le commerçant lui
doit. `CashRemittance.direction` porte les deux sens, **et le sens est déduit de
qui doit, jamais du déclarant** — laisser le déclarant le choisir permettrait
d'enregistrer un versement à l'envers et de doubler une dette au lieu de
l'éteindre, une erreur de saisie qui coûterait de l'argent réel.

### 17.3 On ne se paie pas sur de l'argent qu'on n'a pas

La retenue est plafonnée au montant réellement perçu. Sur une course prépayée,
le transporteur ne retient rien ; sur une course où le client n'a payé que 300
d'un dû de 500, il retient 300. Le reliquat demeure dû par le commerçant — c'est
ce que la position négative exprime, et ce qu'un versement en sens inverse règle.

`DriverEarning` enregistre les quatre grandeurs : brut, taux, commission, part
retenue. Le taux est **figé au moment de la course** : il changera, et une
commission recalculée plus tard sur d'autres paramètres ne serait plus celle qui
était due. Même raisonnement que `pricing_inputs`.

### 17.4 Les soldes passent par la formule canonique

`driverBalances` et `merchantBalances` appellent `debtBetween()` par
contrepartie plutôt que de refaire l'agrégation à côté. Deux façons de calculer
la même dette finissent par en donner deux valeurs, et sur de l'argent la
divergence n'est pas un détail d'affichage. Le coût — une requête par
contrepartie — est assumé.

Les contreparties viennent de **l'union des trois tables**, pas des seuls
encaissements : un transporteur qui a livré sans encaisser n'apparaîtrait nulle
part, alors que c'est précisément le cas où on lui doit quelque chose.

### 17.5 La commission est calculée, son recouvrement ne l'est pas

Sur la **rémunération**, jamais sur le montant encaissé : celui-ci appartient au
commerçant et ne fait que transiter, prélever dessus reviendrait à taxer la
marchandise d'autrui.

Son recouvrement — facture au transporteur, compensation — n'est pas construit,
et l'écran le dit en toutes lettres plutôt que d'afficher un solde exigible :
« déjà prélevée sur vos courses, facturée séparément par Echango, pas depuis
cette application ». Ce qui ne se rattrape pas, c'est le calcul ; c'est donc lui
qu'on fait dès le premier jour.

### 17.6 Deux modèles morts supprimés

`Commission` existait depuis l'origine et **aucune ligne n'y a jamais été
écrite** : `include: { commissions: true }` le lisait pour jeter le résultat.
`Order.totalAmount` et `Order.commission` de même. Trois choses qui laissaient
croire que la facturation existait quelque part. `DriverEarning` les remplace et
fait ce qu'elles promettaient.

### 17.7 Le démarrage cassé, et ce qu'il apprend

`UpdateActivityDto.cash` est typé `CashCollectionDto`, déclaré cent lignes plus
bas. `emitDecoratorMetadata` émet `__metadata("design:type", CashCollectionDto)`
**à la définition de la classe**, et une classe n'est pas hissée : zone morte
temporelle, le processus meurt au chargement. TypeScript ne le voit pas — la
référence est légale à la compilation, seul l'ordre d'évaluation la casse. D'où
un « Found 0 errors » suivi d'un crash.

Deux causes de fond corrigées avec : les DTO importaient une constante depuis
`cash.service`, tirant Prisma et les notifications dans leur graphe pour une
liste de chaînes (`cash.constants.ts` désormais) ; et `FLEETBASE_ID_PATTERN`
était **défini deux fois**, alors qu'il porte une garantie de sécurité — deux
copies d'une règle de sécurité finissent par en devenir deux règles différentes.

**Leçon de méthode** : `tsc --noEmit` ne suffit pas pour une erreur d'ordre
d'évaluation. La vérification est désormais de compiler **et de charger** le
module racine.

### 17.8 Vérification

BFF : `tsc` passe, et `app.module` se charge réellement — l'erreur restante est
`validateEnv` qui refuse un environnement vide, c'est-à-dire son travail.

**Client Prisma non régénéré** (proxy bloquant), donc les trois nouveaux modèles
sont typés `any` ici.

App : **jamais compilée**. `flutter analyze` reste la vérification manquante.

⚠️ **Prérequis** : `npm run prisma:migrate` puis `prisma generate`. Nouvelle
variable : `COMMISSION_RATE`.

**Reste non construit, et assumé** : le recouvrement de la commission, et le
règlement d'une course prépayée — le commerçant doit alors verser au
transporteur, et la position négative le dit, mais aucun moyen de paiement n'est
intégré.


---

## 18. La réservation aux favoris était un garde-fou mal placé (29/07/2026)

Constaté à l'usage, dès la première commande encaissée : refus, avec un message
demandant un transporteur habituel qu'un commerçant nouveau ne peut pas avoir.

**Le raisonnement de départ était faux sur un fait.** Il supposait un pool
anonyme — « on ne confie pas d'espèces à quelqu'un qu'on n'a jamais vu
travailler ». Or les transporteurs ne s'inscrivent pas : ils sont **sélectionnés
et provisionnés par Echango**, sur invitation nominative (`DriverInvitation`,
décision de provisioning manuel actée au 27/07). Le contrôle a donc déjà eu
lieu, **à l'entrée du réseau**, et il est plus fort qu'une liste par commerçant :
il porte sur l'identité réelle, pas sur une habitude de travail.

Refaire ce contrôle par commerçant ne protégeait de rien, et interdisait
l'encaissement à tout commerçant sans favori — c'est-à-dire à tout nouveau
commerçant, précisément ceux qu'on cherche à convaincre.

Le **plafond de dette** demeure, et c'est celui qui fait le travail : il ne
présume rien de la personne, il borne l'exposition.

### 18.1 Ce que la levée a déplacé, et qu'il fallait rattraper

Une course encaissée peut désormais partir au pool commun. Le plafond était
vérifié **à la création**, sur les favoris sollicités d'avance — il ne couvrait
donc plus le chemin devenu le plus fréquent : un transporteur du pool qui
accepte. Il serait resté décoratif, exactement comme la garde de clôture posée
sur la route que l'application n'emprunte pas (§16.3).

`assertCashCeiling()` s'exécute maintenant à l'acceptation, et le message porte
les chiffres : « vous détenez déjà X, cette course en ajouterait Y, plafond Z ».
Un refus sans montant laisse le transporteur sans moyen de savoir combien
remettre pour repartir.

### 18.2 Un défaut révélé par le message d'erreur lui-même

Le journal montrait le refus **réemballé** :

```
Failed to create order: Une livraison avec encaissement ne peut être confiée...
```

`createOrder` lève son erreur métier **à l'intérieur du `try`**, et le `catch`
générique la réemballait. En développement le détail survivait par accident ; en
production, le commerçant aurait reçu « Failed to create order » — un message
qui ne dit ni ce qui ne va pas, ni quoi faire, alors que le refus avait été
rédigé exactement pour le lui expliquer.

Une `HttpException` traverse désormais intacte. `cancelOrder` faisait déjà cette
distinction ; `createOrder` l'avait perdue.

---

## 19. Deux impasses d'écran, même cause (29/07/2026)

Constatées à l'usage, dans la foulée : « Mes transporteurs » sans moyen d'en
trouver un, et un carnet d'adresses où les entrées ne s'ouvrent ni ne se
modifient. Deux écrans construits pour un chemin unique, celui qui remplit la
liste — et rien pour partir d'une liste vide, ni pour revenir sur ce qu'on y a
mis.

### 19.1 Trouver un transporteur : une recherche, pas un annuaire

Les favoris ne se constituaient qu'à partir des transporteurs **ayant déjà
livré**. Un commerçant nouveau voyait donc une page vide et sans issue.

Le raisonnement d'origine tenait en deux moitiés. La première reste vraie :
« exposer l'annuaire complet livrerait la composition du réseau à quiconque crée
un compte » — un concurrent s'inscrit et énumère nos transporteurs. La seconde
était fausse : « on ne met en favori que quelqu'un qu'on a vu travailler ». On
peut aussi l'avoir croisé, ou se l'être fait recommander.

**Et le mécanisme avait changé de nature le matin même.** Tant que les courses
encaissées étaient réservées aux favoris, la liste était une *barrière* et son
contenu comptait beaucoup. Depuis la levée de cette restriction (§18), c'est une
simple *préférence* avec repli automatique. L'enjeu a chuté, et l'argument pour
verrouiller la liste avec lui.

Retenu : **recherche par nom ou téléphone**, trois caractères minimum. Elle sert
le seul cas réel — la relation existe déjà hors de l'application.

**Au-delà de dix correspondances, le serveur refuse et demande de préciser**,
plutôt que d'en renvoyer dix. Une liste tronquée qu'on balaie en changeant une
lettre serait exactement l'annuaire qu'on refuse d'ouvrir ; « précisez » ferme ce
chemin sans gêner celui qui cherche une personne — il tape un nom, pas une
lettre.

**Le téléphone n'est jamais renvoyé.** Celui qui cherche le connaît déjà, c'est
par là qu'il cherche ; le renvoyer ferait de la recherche un moyen de récupérer
les coordonnées de prestataires qu'on n'a jamais fait travailler.

Le garde d'`addFavourite` change de nature en conséquence : de « a déjà livré
pour vous » à « existe et est actif dans le réseau ». Il empêche toujours de
sonder un uuid arbitraire, sans interdire les favoris à un commerçant nouveau.
**Le nom vient désormais du serveur**, jamais de la requête — sinon une liste de
favoris cesserait de décrire des personnes réelles.

### 19.2 Le carnet d'adresses était en écriture seule

Créer, oui. Consulter, modifier, supprimer : rien. La liste n'était qu'un
affichage mort.

Ce qui rend le manque sérieux : **une adresse enregistrée est réutilisée** —
elle pré-remplit chaque livraison qui la choisit. Une position mal placée ou un
téléphone erroné ne gêne donc pas une fois, il se répète, et la seule issue
était d'accumuler des doublons.

`PUT` et `DELETE` sur `/commercant/adresses/:id`, avec contrôle d'appartenance
par `owner_uuid` — le seul filtre que Fleetbase honore réellement sur `/places`.
Sans lui, un identifiant deviné suffirait à modifier l'adresse d'un autre
commerçant : les lieux vivent tous dans la même organisation.

Le formulaire de création sert aussi à la modification, plutôt qu'un second
écran : les champs sont identiques, et deux écrans auraient divergé — celui de
modification aurait fini par ne plus proposer la carte, comme la création avant
sa correction.

**Défaut trouvé en écrivant la relecture** : la création déposait le contact
sous `meta.contactName`, tandis que `projectPlace` relit `meta.contact_name` —
la clé posée par la création de commande. Le contact d'une adresse enregistrée
disparaissait donc **à sa première relecture**. Deux orthographes pour la même
donnée, sur un chemin où personne ne relisait ce qu'il venait d'écrire.

La liste signale aussi les adresses **sans position** : le formulaire de commande
en exige une, et le découvrir au moment de commander est trop tard.

Une suppression ne demande qu'une confirmation légère, et l'explique : chaque
livraison a créé son propre lieu à la commande, distinct de l'entrée du carnet.
Supprimer n'efface donc aucun historique.

### 19.3 La recherche cherchait dans la mauvaise table

Constaté immédiatement après : une recherche sur un nom bien visible dans la
console Fleetbase ne renvoyait rien.

La requête portait sur `DriverAccount`, la table locale des **comptes
applicatifs**. Deux critères cachés en découlaient, dont aucun n'était visible
du commerçant :

1. **Le transporteur devait avoir créé son compte dans l'application.** Un
   transporteur provisionné par l'opérateur n'y figure pas tant qu'il n'a pas
   utilisé son invitation. C'était le cas de la plupart.
2. **Le nom devait avoir été saisi à l'inscription.** `firstName`/`lastName`
   sont facultatifs et remplis par le transporteur lui-même — souvent vides, et
   sans rapport garanti avec le nom que l'opérateur voit dans la console, qui
   est `Driver.name` côté Fleetbase.

L'annuaire qui fait autorité est celui de **Fleetbase** : c'est là que
l'opérateur crée les transporteurs, c'est ce nom qu'il communique, et c'est
l'uuid Fleetbase que `DriverFavourite` référence de toute façon. La recherche y
porte désormais, ainsi que le garde d'`addFavourite` — viser `DriverAccount`
là aurait refusé précisément ceux que la recherche venait de proposer.

**Un transporteur trouvé peut ne pas avoir l'application**, et c'est dit :
`pickAvailableFavourite` ne retient que ceux qui ont un compte, donc le mettre
en favori serait sinon un geste **sans effet** — et le commerçant croirait sa
préférence enregistrée.

Le motif est celui de la journée, une fois de plus : **une donnée cherchée là où
elle n'est pas encore**. Le cache local ne décrit qu'une partie du réel, et le
prendre pour l'ensemble produit un vide qui ressemble à une absence.

---

## 20. Deux écritures reprenables, et une hypothèse fondatrice invalidée (29/07/2026)

Session de discussion, presque sans code. Point de départ : *« on fait de la
double écriture, BFF et Fleetbase ? D'un point d'archi ce n'est pas propre. »*
La décision d'architecture qui en sort et l'inventaire complet des faits vérifiés
sont dans **`docs/architecture_bff_fleetbase.md`** — ce journal ne garde que le
récit et les deux correctifs.

### 20.1 Les deux défauts trouvés en instruisant la question (commit `e390a3b`)

Chercher où le BFF écrivait deux fois a fait apparaître deux vrais bugs, tous
deux du même genre : une opération qui doit aboutir **des deux côtés**, sans
transaction commune entre le MySQL de Fleetbase et le PostgreSQL du BFF.

**Un interblocage sur l'encaissement.** `declareCollection()` levait quand
l'encaissement était déjà enregistré. Or le registre s'écrit **avant** la
clôture Fleetbase — délibérément, pour qu'un échec laisse la course reprenable
plutôt qu'un encaissement fantôme (§16.3). Si cette clôture échouait, le
transporteur réessayait, repassait par le registre, et levait. **La course
devenait définitivement non clôturable, l'argent enregistré nulle part
d'exploitable.** On ne peut pas rendre les deux systèmes atomiques ; on peut
rendre la reprise sûre. Un encaissement déjà déclaré par le **même**
transporteur est désormais rejoué (`replayed: true`) ; par un autre, refusé —
deux personnes n'ont pas encaissé la même livraison.

**Une commande orpheline.** `createOrder()` laissait la commande Fleetbase en
place quand la ligne locale de rattachement ne s'écrivait pas. Cette ligne porte
le lien commerçant ↔ commande. Sans elle, la commande **part au dispatch, un
transporteur la voit et la livre, et elle n'appartient à personne** : invisible
au commerçant, absente de ses notifications, encaissement refusé faute de savoir
à qui l'imputer. Une commande orpheline est pire qu'une commande non créée.
`createOrderCache()` annule donc la commande amont en compensation — même geste
que pour le `Vendor` d'une inscription commerçant interrompue (§12). Si
l'annulation échoue à son tour, l'identifiant est journalisé en `error`, seule
trace permettant de la retrouver à la main.

Trois propriétés, à défaut d'atomicité : **ordre** (écrire d'abord le côté
récupérable), **idempotence** (une reprise après échec partiel doit être sûre),
**compensation** (défaire l'amont si l'aval échoue). L'idempotence était la
jambe manquante, et elle a produit un blocage réel.

### 20.2 §2.8 était une observation juste et une conclusion fausse

L'utilisateur a contesté l'affirmation « Fleetbase ignore les filtres » :
*« il y a bien des filtres au niveau de la console, donc il sait faire. »*

Il avait raison. Lecture de `Filter::apply()` : chaque paramètre est cherché
comme méthode sur la classe de filtre, sous son nom brut puis en camelCase, sans
aucun repli. Et `OrderFilter` déclare une méthode **`facilitator`** — pas
`facilitator_uuid`. Nos tests de §2.8 envoyaient `facilitator_uuid` et
`vendor_uuid` : deux noms qui n'existent pas, jetés en silence.

Le défaut amont est réel mais banal — **un paramètre inconnu est abandonné sans
erreur** — et c'est ce qui a transformé une faute de frappe en fausse limitation
permanente, sur laquelle trois mécanismes ont été construits : isolation
commerçant, isolation flotte, recherche de transporteur. Tous filtrent en
mémoire ce que le serveur savait filtrer.

Détail qui pique : §2.9 note que `facilitator` sans suffixe avait bien été
essayé — mais pendant la session où la variable shell était vide. Le bon nom
testé avec une mauvaise valeur, le mauvais nom avec une bonne valeur.

**La correction a été obtenue par lecture de code, exactement comme l'erreur
qu'elle corrige.** Elle n'est pas acquise : les appels réels de vérification sont
listés dans `architecture_bff_fleetbase.md` §9, et rien n'a été supprimé.

### 20.3 Deux découvertes des en-têtes de la console

**Les lectures passent par un cache Redis.** `x-cache-key:
{api_query}:orders:company_<uuid>:v357:<hash>` — invalidation par génération, un
compteur par ressource. C'est la première objection sérieuse au fait de
supprimer nos colonnes miroir pour tout lire en direct : reste à savoir si le
compteur est incrémenté à **chaque** écriture. Détail et scénario de test :
`architecture_bff_fleetbase.md` §6.

**Le filtre `phone` des conducteurs renvoie 500.** `DriverFilter::phone()` fait
un `whereHas('phone', …)` alors que `phone` n'est pas une relation sur `Driver`
mais un attribut calculé (`$appends` + `getPhoneAttribute()` qui traverse
`user`). Reproduit depuis leur propre console. Troisième bug amont trouvé après
le bucket de `capturePhoto()` (§6.12) et la résolution non uniforme des
identifiants (§6.7). **Utiliser `query`, jamais `phone`** — `query()` couvre le
téléphone via la bonne relation, on ne perd rien.

### 20.4 Ce que la séquence apprend sur la méthode

Le motif du 28 était *« le serveur savait, l'app ignorait »*. Celui du 29 est
plus embarrassant : **le serveur savait, et on avait écrit noir sur blanc qu'il
ne savait pas.** Une conclusion fausse, documentée avec soin et référencée dans
une douzaine de commentaires de code, est plus coûteuse qu'une absence de
documentation — elle empêche de reposer la question.

D'où la règle ajoutée : **avant d'écrire un filtre côté BFF, regarder ce que la
console envoie pour la même question.** L'onglet réseau donne les noms exacts en
trente secondes, et la console est l'implémentation de référence.
