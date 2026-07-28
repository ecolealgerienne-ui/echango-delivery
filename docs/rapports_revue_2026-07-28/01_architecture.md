# Revue d'architecture — Echango Delivery (28/07/2026)

*Agent : general-purpose (Opus). Périmètre : `backend/bff/src/**`, `backend/bff/prisma/schema.prisma`, `echango_delivery/lib/**`, Dockerfile/compose. Lecture seule.*

## CRITIQUE

### 1. Le secret JWT a trois valeurs par défaut différentes, et aucune n'échoue au démarrage
`backend/bff/src/app.module.ts:24` (`'dev-secret-key-change-in-prod'`), `backend/bff/src/auth/auth.module.ts:13` (`'dev-secret'`), `backend/bff/src/auth/strategies/jwt.strategy.ts:11` (`'dev-secret'`), `backend/bff/docker-compose.yml:42` (`${JWT_SECRET:-dev-secret-key}`).

`AuthService` signe avec le `JwtService` **local** d'`AuthModule` ; `JwtAuthGuard` (fourni par `CommonModule`) vérifie avec le `JwtService` **global** d'`AppModule`. Sans `JWT_SECRET` défini, les deux secrets diffèrent et **100 % des appels authentifiés partent en 401** sans indice. Avec le compose tel quel sur un VPS, le secret est `dev-secret-key`, versionné dans le dépôt : n'importe qui forge un jeton `{sub: <cuid>, type: 'merchant'}` et prend le contrôle de n'importe quel compte.

**Correction** : supprimer les trois valeurs de repli, lire le secret via `ConfigService` en un seul endroit, et lever au boot si la variable est absente ou < 32 caractères.

### 2. Toutes les listes de commandes sont plafonnées à 100 lignes pour l'organisation entière
`backend/bff/src/fleetbase/fleetbase-api.client.ts:285` (`getAllOrders(page = 1, limit = 100)`), appelé **sans arguments** par `transporteur.service.ts:101` (`resolveOrder`), `transporteur.service.ts:234` (`listOrders`) et `commercant.service.ts:46` (`mergeWithFleetbase`).

Le filtrage anti-IDOR côté BFF est légitime, mais il s'applique ici à un échantillon tronqué. Conséquences dès la 101ᵉ commande *de toute l'organisation* — pas par commerçant, pas par driver :
- le driver ne voit plus sa commande dans la liste, et `GET /transporteur/commandes/:id` répond **404 sur une commande qui lui est bel et bien assignée** ;
- côté commerçant, la commande sort du lot des 100 et `mergeWithFleetbase` la marque `missing: true` (`commercant.service.ts:61`) : l'app affiche « commande disparue » pour une livraison en cours.

Échelle : à 20 commerçants × 10 livraisons/jour, la casse survient **le premier jour**. Seul `flotte.service.ts:227` (`fetchAllOrders`) pagine correctement — l'incohérence entre modules est en soi le signal.

**Correction, sans sur-ingénierie** : (a) pour `resolveOrder`, ne pas lister du tout — `GET /int/v1/orders/{uuid}` fonctionne (déjà utilisé en `commercant.service.ts:254`), un appel unitaire suffit et l'anti-IDOR se fait sur l'enregistrement retourné ; (b) pour les listes, réutiliser `fetchAllOrders()` (à remonter dans le client Fleetbase, il n'a rien à faire dans `flotte`) avec une borne temporelle (`?createdAt=` ou 30 jours) ; (c) un cache mémoire de 5–10 s sur la liste compagnie, car un simple « Accepter » déclenche aujourd'hui 2 récupérations complètes (`acceptOrder` → `getOrder` → `resolveOrder`, puis `getDriverPublicId`).

### 3. Annuler une commande et consulter son suivi sont cassés à 100 % côté commerçant
`backend/bff/src/commercant/commercant.service.ts:198` et `:240` cherchent `prisma.order.findUnique({ where: { id: orderId } })` — le **cuid BFF**. Or l'app envoie l'**uuid Fleetbase** : `echango_delivery/lib/models/merchant_order.dart:70` (`id: json['uuid'] ?? …`), passé tel quel par `orders_screen.dart:198` puis `order_detail_screen.dart:48` et `bff_api_client.dart:635`/`:618`.

Résultat : `POST /commercant/commandes/:id/annuler` répond **toujours** 404, et `GET …/suivi` aussi — ce dernier silencieusement, car `merchant_order_state.dart:57` avale l'exception et affiche « suivi indisponible ». `getOrderDetail` (`commercant.service.ts:111`) fait pourtant déjà la bonne chose avec un `findFirst({ OR: [{id}, {fleetbaseOrderId}] })`.

**Correction** : extraire ce `findFirst` en helper `resolveOwnedOrder(merchantId, orderId)` et l'utiliser dans les trois méthodes.

### 4. Aucune limite de corps de requête relevée, alors que les photos transitent en base64
`backend/bff/src/main.ts` (aucun `bodyParser`/`json({limit})`) ; charges concernées : `transporteur.dto.ts:97` (`photos: string[]`) et `:90` (`photo?`).

Express plafonne le JSON à **100 kB** par défaut. Une photo de téléphone en base64 pèse 1 à 4 Mo → `413 Payload Too Large`, sans passer par le filtre d'exception, donc avec un message que l'app traduit en « Server error (413) ». La preuve de livraison et l'échec avec photo — validés côté serveur — sont inutilisables en conditions réelles. Le test qui « passe au vert » utilise un PNG 1×1 (`scripts/test-transporteur-module.sh:249`), il ne pouvait pas révéler la limite.

**Correction** : `app.use(json({ limit: '10mb' }))` dans `main.ts`, plus un `@MaxLength` explicite sur les champs base64 pour refuser proprement au-delà.

### 5. La carte flotte récupère l'intégralité de l'historique des positions, sans filtre ni pagination
`backend/bff/src/fleetbase/fleetbase-api.client.ts:632` (`getAllPositions`, aucun paramètre) consommé par `flotte.service.ts:142`, qui filtre ensuite en mémoire.

Un driver qui émet une position tous les 10 s produit ~8 600 lignes/jour. À 10 drivers, la table dépasse le million de lignes en deux semaines, et chaque ouverture de la carte demande tout. De plus le service renvoie **toutes** les positions historiques, pas la dernière connue par driver (`flotte.service.ts:150`) — ce n'est pas ce dont une vue dispatch a besoin.

**Correction pertinente et peu coûteuse** : la position passe déjà par le BFF (`transporteur.service.ts:198`) ; y persister la dernière position par driver (2 colonnes sur `DriverAccount` ou une petite table) et servir la carte depuis là. Fleetbase reste le journal, le BFF détient l'instantané.

## IMPORTANT

### 6. La chaîne de notification push n'est branchée nulle part dans l'app
`echango_delivery/lib/services/notification_service.dart:84` (`getDeviceToken`) et `lib/services/bff_api_client.dart:241` (`registerDeviceToken`) ne sont **appelés par aucun fichier** (vérifié par grep sur tout `lib/`). `main.dart:34` initialise FCM et s'arrête là.

Le `OrderPing` natif, le miroir `UserDevice` et la purge des jetons périmés — le travail serveur le plus difficile de la semaine — n'atteindront jamais un téléphone. Le driver ne découvrira une course adhoc qu'en tirant sur la liste pour rafraîchir.

**Correction** : après connexion réussie (`auth_state.dart:_persist`), récupérer le jeton et le poster ; réabonner sur `onTokenRefresh`.

### 7. Le suivi GPS de fond n'est jamais démarré, et son arrêt n'arrête rien
`echango_delivery/lib/services/location_service.dart` : la classe n'est instanciée nulle part. Par ailleurs `startBackgroundTracking` (`:88`) ne conserve pas le `StreamSubscription`, et `stopBackgroundTracking` (`:101`) se contente de basculer `_isTracking = false` — le stream continue d'émettre et de poster des positions indéfiniment. Enfin `late final BffApiClient _apiClient` sur un singleton (`:10`) plantera en `LateInitializationError` si un callback arrive avant `initialize()`.

Conséquence immédiate : `POST /transporteur/position` n'est jamais appelé, donc aucune donnée pour la carte flotte ni pour le dispatch géospatial par proximité.

### 8. La capture photo n'existe pas dans l'app
`echango_delivery/lib/screens/transporteur/delivery_failure_screen.dart:133-155` est un placeholder explicite (« Photo capture will be available in future updates ») ; `screens/transporteur/order_detail_screen.dart:288` note que `require_pod` n'est pas honoré ; `pubspec.yaml` ne déclare ni `image_picker` ni `camera`.

La preuve de livraison est un élément central du produit, l'endpoint est validé, le contournement du bug amont Fleetbase a été payé — et rien ne peut l'appeler.

### 9. Les mises à jour optimistes inventent des statuts inexistants et ciblent la mauvaise liste
`echango_delivery/lib/state/order_state.dart:124` et `:127` posent `'accepted'`, `:152`/`:155` posent `'picked_up'` — aucun des deux n'existe côté Fleetbase (created/dispatched/started/enroute/completed/canceled, cf. `models/order.dart:11-14`). Pire, `:122` cherche la commande dans `_orders`, alors qu'une commande adhoc qu'on vient d'accepter vit dans `_adhocOrders` : l'index est toujours `-1` et **rien ne bouge à l'écran après un « Accepter » réussi**.

**Correction** : supprimer l'optimisme et enchaîner `selectOrder` + `loadOrders`, exactement comme `applyActivity` le fait déjà (`:182-183`).

### 10. Le module commerçant est le seul sans garde de rôle
`backend/bff/src/commercant/commercant.controller.ts` n'a aucun équivalent de `fleetId()` (`flotte.controller.ts:46`) ou `driverId()` (`transporteur.controller.ts:33`). Un jeton driver ou flotte est structurellement valide sur `/commercant/*` et `req.user.id` part chercher un cuid dans la mauvaise table. Aujourd'hui ça donne un 404 par chance (les cuid ne collisionnent pas) ; c'est une garantie probabiliste, pas une garantie de conception, et l'asymétrie invite à oublier le garde sur le prochain module.

**Correction** : un décorateur `@Roles('merchant')` + un garde partagé, appliqué aux trois contrôleurs — cela retire aussi les trois helpers dupliqués.

### 11. L'inscription commerçant crée un compte Fleetbase connectable dont personne ne se sert, sans rollback
`backend/bff/src/fleetbase/fleetbase-api.client.ts:135-141` : `createCustomer` poste `type: 'customer'` **sans** `create_login: false`, et le commentaire de la méthode reconnaît que Fleetbase provisionne alors un `User` (rôle Fleet-Ops Customer). Cela contredit frontalement la décision documentée de minimisation des credentials Fleetbase valides. Or le `fleetbaseCustomerUuid` obtenu n'est **jamais lu** : `commercant.service.ts:153` crée la commande avec `customer_uuid = fleetbaseVendorUuid`. Le champ `fleetbaseSanctumToken` (`schema.prisma:28`) est mort lui aussi, avec un commentaire « encrypted at rest » alors que rien ne chiffre.

Accessoirement, `auth.service.ts:44-85` enchaîne trois écritures (Vendor, Contact, Prisma) sans compensation : un échec en étape 2 ou 3 laisse un Vendor orphelin dans Fleetbase, et l'email est déjà « pris » côté Fleetbase au réessai.

### 12. Aucune limitation de débit sur `/auth/*`, et la connexion unifiée coûte trois bcrypt
`backend/bff/package.json` ne contient pas `@nestjs/throttler` ; tous les endpoints d'authentification sont `@Public()`. `auth.service.ts:130-152` compare le mot de passe dans les trois tables sans court-circuit : chaque tentative invalide coûte au serveur 3 bcrypt (~300 ms CPU) contre une requête HTTP à l'attaquant. Le rapport de forces est inversé — c'est un déni de service à faible coût autant qu'un bruteforce.

**Correction avant VPS** : `ThrottlerModule` (5 tentatives / 15 min / IP+email) ; le triple bcrypt peut rester, il est justifié, une fois le débit borné.

### 13. Le healthcheck Docker interroge une route qui n'existe pas
`backend/bff/Dockerfile:61` sonde `http://localhost:3001/health` ; aucune route `health` n'existe dans `src/` (vérifié par grep). Le conteneur de production sera marqué `unhealthy` en permanence — et selon l'orchestrateur retenu sur le VPS, redémarré en boucle.

**Correction** : un `@Public() @Get('health')` qui pingue Prisma (`SELECT 1`) et renvoie l'état de joignabilité de Fleetbase.

## MINEUR

### 14. Le désérialiseur Fleetbase existe en deux exemplaires déjà divergents
`echango_delivery/lib/models/order.dart` et `lib/models/merchant_order.dart` réimplémentent la même logique — `payload.pickup`/`payload.dropoff`, `tracking_number` tantôt chaîne tantôt objet, cascade `uuid`/`public_id`/`id`, GeoJSON à coordonnées inversées (`order.dart:223` vs `merchant_order.dart:134`, code identique dans trois classes : `Place`, `OrderPlace`, `SavedAddress`). Idem pour `order_state.dart`/`merchant_order_state.dart`, qui partagent le motif `_isLoading`/`_errorMessage`/`notifyListeners` au mot près.

Ce n'est pas une duplication esthétique : chaque quirk Fleetbase découvert devra être corrigé à deux endroits, et les deux ont **déjà** divergé (`merchant_order` gère `stale`/`missing`, `order` non). Un seul modèle `FleetbaseOrder` avec deux vues, ou au minimum une fonction de parsing partagée, coûte une heure aujourd'hui.

### 15. Le schéma Prisma porte une part importante de champs morts, dont un piège déjà déclenché
`schema.prisma` : `Commission` (`:232`) et `AuditLog` (`:261`) ne sont jamais écrits ; `Order.totalAmount`/`commission`/`failureReason`/`failureNotes`/`fleetbaseCreatedAt`/`fleetbaseUpdatedAt` sont inertes ; `DeviceToken` (`:177`) est alimenté mais jamais lu (aucun envoi FCM côté BFF, la dualité avec `DriverDeviceToken` est donc moins un doublon qu'une moitié inutilisée).

Le cas de `Order.status` (`:206`) est plus qu'un détail : la correction du 28/07 l'a retiré des lectures de liste, mais `cancelOrder` (`commercant.service.ts:210`) valide encore les transitions dessus — donc contre un statut figé à `'pending'`. Une commande déjà terminée dans Fleetbase passe le garde et part en annulation.

**Correction** : supprimer les colonnes non utilisées, et renommer `status` en `initialStatus` (ou l'ôter) pour que la prochaine lecture accidentelle soit impossible.

## Dette : à payer avant le VPS, ou après

**Avant le déploiement** (indispensable, sinon la mise en ligne est soit dangereuse soit non fonctionnelle) : constats 1 (secret JWT), 12 (rate limiting), 4 (limite de corps), 3 (annulation/suivi), 13 (healthcheck), 11 (le `create_login: false` au minimum), plus le point déjà tracé dans `CLAUDE.md` sur `FLEETBASE_PROOF_DISK`. À cela s'ajoutent deux absences non listées ci-dessus car hors périmètre du code : TLS devant le BFF (l'app parle HTTP en clair, `api_config.dart:23`) et un mécanisme de migration Prisma en production (`prisma/migrations/` est gitignoré et vide — `migrate deploy` n'a rien à déployer).

**Avant le premier vrai pilote, mais pas bloquant pour un VPS de recette** : constats 2 et 5 (les deux plafonds d'échelle — invisibles à 10 commandes, fatals à 200), 6, 7, 8 (les trois chaînes app inachevées : push, GPS, photo), 9, 10.

**Peut attendre** : 14 et 15, plus le nettoyage de `JwtStrategy` (code mort documenté).

## Avis d'ensemble

L'architecture est saine : la séparation BFF/Fleetbase est le bon choix, l'anti-IDOR côté BFF est correctement raisonné, et le niveau de documentation des découvertes Fleetbase est nettement au-dessus de la moyenne — c'est un vrai actif. Ce qui manque, c'est la couture entre les tranches : le serveur est en avance sur l'app (push, GPS et photo sont validés côté BFF et inexistants côté Flutter), et les patterns de chaque module divergent silencieusement (pagination, gardes de rôle, résolution d'identifiant). Deux défauts sont bloquants au sens strict — le secret JWT par défaut et l'annulation/suivi commerçant cassés à 100 % — et deux plafonds d'échelle (100 commandes, positions non paginées) casseront le produit dans sa première semaine d'usage réel, pas dans un an.

Trois chantiers prioritaires : **(1)** durcir le déploiement (secret obligatoire au boot, throttler, limite de corps, `/health`, TLS) ; **(2)** supprimer les deux plafonds en adressant les commandes unitairement et en stockant la dernière position dans le BFF ; **(3)** brancher les trois chaînes app inachevées, sans quoi le travail serveur déjà payé reste invisible pour l'utilisateur.
