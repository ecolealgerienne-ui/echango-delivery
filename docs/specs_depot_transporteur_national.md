# Specs — Dépôts de transporteur national, multi-collecte, multi-distribution

**Statut** : **Phase 1 IMPLÉMENTÉE et vérifiée** (08/09/2026) — §3.1 (CRUD des
dépôts), §3.2 (livrer vers un dépôt), §3.3 (le dépôt expédie), côté BFF **et**
app, avec trois bancs rejouables (`test-depot-crud`, `test-depot-livraison`,
`test-depot-expedition`) dans `run-all-scenarios.sh`, chacun prouvé par mutation.
Le noyau de création de commande est extrait en
`common/orders/order-creation.helpers.ts` (partagé commerçant/transporteur,
règle 5).

**Phase 2 — tournée transporteur : NOYAU LIVRÉ** (08/09/2026). Fait et vérifié :
`POST /flotte/tournees` (`CreateTourneeDto` + `OrderCreationHelpers.createTournee`
/ `buildTourneeMeta`) — une commande à `payload.waypoints[]` ordonné, un seul
`price`, `cod_amount` = **somme** des COD d'arrêt (champ personnalisé durable, lu
par le plafond de dette), `stop_cod_amounts` en portant le détail ;
`payload.entities[]` avec `destination_uuid` (colis collecté à un enlèvement →
routé vers le dernier arrêt). Les 3 projections lisent `payload.waypoints[]` avec
**expurgation par arrêt** (`projectWaypoint`, un enlèvement reste un commerce).
Banc `test-tournee-creation.sh` (dans `run-all-scenarios.sh`), 2 mutations
prouvées. App : `Order.waypoints` (additif), écran flotte « créer une tournée »
(`POST /flotte/tournees` a un appelant).

**Phase 2/3 — RESTE À FAIRE** (voir §4.6) : `POST /commercant/tournees` + la
ligne `Order` locale + l'écran commerçant ; la fiche/carte conducteur à N arrêts
(progression par waypoint — `getNextActivities(waypoint)` est déjà câblé) ; la
déclaration d'encaissement **par arrêt** (`declareCollection(waypointUuid)`) ; la
diffusion d'une tournée au pool (Phase 3, V1 = ciblage seul).
**Date** : 08/09/2026.
**Origine** : discussion produit sur le positionnement « transporteur national à
dépôts ». Reprend et débloque le sujet **multi-arrêt / multi-enlèvement** que
`docs/specs_localisation_client_et_optimisation_parcours.md` §3 avait identifié
techniquement mais gelé faute de décisions produit. **Ces décisions sont
désormais prises** (§1).

---

## 1. Les décisions produit — toutes prises

| question | décision | ce que ça débloque |
|---|---|---|
| **répartition du prix** sur une tournée à N arrêts | il n'y en a pas : **un seul `price` par tournée**, pour toute la route. Les colis n'ont pas de prix. | le multi-arrêt natif Fleetbase (`payload.waypoints[]`) redevient viable — c'était la répartition qui l'interdisait |
| **qui fixe et paie le prix** | **le demandeur de la tournée** (celui qui la crée) | pas de négociation, pas de barème à inventer — un champ, une valeur |
| **espèces à N portes** (COD multi-arrêt) | **le demandeur décide**, arrêt par arrêt, à la création (`stops[i].codAmount`) | pas de règle de garde nouvelle : c'est le même `cod_amount` qu'aujourd'hui, posé par arrêt |
| **qui compose la tournée** | **le demandeur**, entièrement : liste ordonnée d'arrêts, colis par arrêt, prix, COD par arrêt. Le conducteur **accepte ou refuse en bloc** — pas d'acceptation partielle, pas de composition ni d'optimisation côté conducteur ou plateforme | une tournée = une course avec N arrêts au lieu de 2. Même machinerie : diffusion, `claim`/`accept`, zone, favoris, preuve |
| **le dépôt** | un **`Place` typé**, possédé par le `Vendor` du transporteur (`owner_type: 'fleet-ops:vendor'`, `meta.is_depot = true`) — exactement le patron du carnet d'adresses commerçant | aucun nouveau primitif Fleetbase, règle 1 tenue (rien en base BFF) |
| **le dépôt joue deux rôles** | un dépôt est un **nœud à double rôle** : `pickup` d'une course (il **expédie** → agit en commerçant) ou `dropoff` (il **reçoit** → agit en client). C'est la même polymorphie que le `Vendor` Fleetbase porte déjà (`customer` sur certaines commandes, `facilitator` sur d'autres) | un dépôt n'est pas qu'une adresse de livraison : c'est aussi une **origine** de course |

**Reste un seul point ouvert, mineur** : la **wilaya d'une tournée** pour le
filtre / la zone de service transporteur (§4.4). Recommandation retenue : la
wilaya du **premier enlèvement**, cohérente avec `pickupWilaya` d'une course
simple.

---

## 2. Le modèle

### 2.1 Trois gestes distincts, à ne pas confondre

1. **Livraison vers un dépôt** — un commerçant demande une livraison **à un
   dépôt de transporteur** au lieu d'une adresse client. **Course 1→1**, seule
   la destination change. *(Phase 1.)*
2. **Le dépôt expédie** — le transporteur crée une course **depuis son dépôt**
   vers un client (ou vers un autre dépôt). **Course 1→1**, l'origine est un
   dépôt. *(Phase 1.)*
3. **La tournée** — N arrêts en une commande. Multi-collecte (N enlèvements → 1
   dépôt) ou multi-distribution (1 dépôt → N livraisons), selon la position du
   dépôt dans la liste d'arrêts. *(Phases 2-3.)*

### 2.2 Le compte du transporteur national — décision Phase 1

⚠️ **`docs/specs_localisation_client_et_optimisation_parcours.md` pose déjà** :
*« un transporteur qui redistribue en dernier kilomètre est, du point de vue de
la plateforme, un commerçant — le rôle est transactionnel (qui crée et paie une
commande), pas une catégorie d'entreprise »*.

Un transporteur national a pourtant **deux besoins** :

| besoin | rôle plateforme | compte BFF |
|---|---|---|
| gérer des dépôts, une flotte de conducteurs, une zone de service | **entreprise de transport** | `FleetAccount` |
| créer et payer des courses/tournées depuis ses dépôts | **commerçant** | `MerchantAccount` |

Fleetbase supporte les deux sur **un seul `Vendor`** (polymorphie). Côté BFF, ce
sont deux tables (`MerchantAccount`, `FleetAccount`), chacune avec
`fleetbaseVendorUuid @unique` **sur sa propre table** — rien n'interdit deux
lignes pointant le même `Vendor`.

**Décision Phase 1** : les dépôts sont **gérés depuis l'espace `flotte`** (qui
porte déjà conducteurs + zone de service — foyer naturel de « mes dépôts »). La
création de courses **par** le transporteur (« le dépôt expédie », §2.1 cas 2 et
les tournées) passe par un **nouveau chemin `POST /flotte/commandes`** où
`customer_uuid = le Vendor du transporteur`. **Pas de second compte, pas de
nouveau persona** : on étend les droits du persona `fleet`, comme la note de
positionnement l'anticipe (« aucun nouveau persona à prévoir »).

⚠️ **Ce que ça implique et qu'il faut assumer** : aujourd'hui **seul le persona
`merchant` crée des commandes** (`POST /commercant/commandes`, `customer_uuid`
codé en dur sur `merchant.fleetbaseVendorUuid`). Le chemin `fleet` est un vrai
ajout de surface — DTO, service, contrôle d'appartenance du dépôt, projection.
Il est petit parce qu'il réutilise `createOrder` presque tel quel, mais c'est
une **nouvelle capacité d'écriture** pour ce persona, à traiter avec la
discipline des règles 12 et 13.

### 2.3 Le dépôt — structure

Un `Place` Fleetbase, `owner_uuid = <Vendor du transporteur>`,
`owner_type = 'fleet-ops:vendor'`, `meta.is_depot = true`.

| colonne `Place` | source | note |
|---|---|---|
| `name` | saisi | nom du dépôt (« Entrepôt Alger-Centre ») |
| `location` (GeoJSON Point) | carte ou géocodage | obligatoire — un dépôt sans point ne peut pas être une origine/destination de course |
| `street1`, `city`, `neighborhood`, `province`, `postal_code` | géocodage inverse | `province` sert au filtre wilaya |
| `phone` | saisi | contact du dépôt (le conducteur appelle en arrivant) |
| `meta.contact_name` | saisi | responsable du dépôt |
| `meta.is_depot` | **`true`** | le marqueur de type — `Place` n'a pas de colonne `type` native, on suit le patron de `meta.is_default` du carnet |

Réutilise **tel quel** `createOwnedPlace` / `getOwnedPlaces` / `updateOwnedPlace`
/ `deletePlace` du client Fleetbase. `getOwnedPlaces(vendorUuid)` rend **tous**
les lieux du `Vendor` ; on filtre `meta.is_depot === true`.

⚠️ **Le `Vendor` d'un transporteur porte donc potentiellement deux familles de
`Place`** : ses dépôts (`is_depot`) et — s'il a aussi un `MerchantAccount` un
jour — un carnet d'adresses classique. Le filtre `meta.is_depot` les sépare.
Aucun risque en Phase 1 : un `FleetAccount` n'a pas de carnet.

---

## 3. Phase 1 — le dépôt comme nœud

### 3.1 Gérer ses dépôts (espace flotte)

Nouvelles routes, persona `fleet`, sous `/flotte` :

| route | rôle |
|---|---|
| `GET /flotte/depots` | la liste des dépôts du transporteur — `getOwnedPlaces(vendorUuid)` filtré `meta.is_depot` |
| `POST /flotte/depots` | créer un dépôt — `createOwnedPlace(vendorUuid, { …, meta: { is_depot: true, contact_name } })` |
| `PUT /flotte/depots/:id` | modifier — `assertOwnsDepot` d'abord (le `Place` appartient à ce `Vendor` **et** porte `is_depot`), puis `updateOwnedPlace` (⚠️ `ownerUuid` repassé — Fleetbase remplace l'objet entier, cf. `updateOwnedPlace`) |
| `DELETE /flotte/depots/:id` | supprimer — `assertOwnsDepot` puis `deletePlace`. ⚠️ Refuser si des commandes **en cours** pointent ce dépôt (une course orpheline d'adresse est pire qu'un dépôt qu'on ne peut pas supprimer) |

**DTO** (`SaveDepotDto`) : `name` (obligatoire), `latitude`/`longitude`
(obligatoires — `@IsNumber`), `phone` (obligatoire — le conducteur doit pouvoir
appeler), `contactName` (obligatoire), `city`/`neighborhood`/`province`/
`postalCode` (optionnels, du géocodage). Décorés (règle 13). **Pas de liste
fermée de wilayas** (comme `transporteur.dto.ts` / `SaveServiceZoneDto`).

**`assertOwnsDepot(fleetId, placeId)`** : lit `getOwnedPlaces(vendorUuid)`,
cherche l'uuid, vérifie `meta.is_depot === true`. Introuvable **ou** pas un
dépôt ⇒ `notFound('depot.not_found')` — jamais « la ressource de quelqu'un
d'autre » (règle 12).

**App** : un onglet ou une carte « Dépôts » dans l'espace flotte (à côté de
Conducteurs / Zone de service). Liste + formulaire (nom, point sur carte,
contact). Réutilise le sélecteur de carte existant (`MapPickerScreen`).

### 3.2 Livrer vers un dépôt (commerçant)

`CreateOrderDto` gagne :

```ts
@IsOptional() @IsIn(['client', 'depot'])
destinationType?: string;              // défaut : 'client' (comportement actuel)

@IsOptional() @IsString() @Matches(FLEETBASE_ID_PATTERN)
depotUuid?: string;                    // requis si destinationType === 'depot'
```

Quand `destinationType === 'depot'` :

- `depotUuid` doit être **résolu et validé** avant le `try` de `createOrder`
  (comme `resolveTargetFavourite` : le refus tombe avant la première écriture
  Fleetbase, sinon `Place` d'enlèvement orphelin). Validation : le dépôt existe,
  porte `is_depot`, et **appartient à un transporteur du réseau** du commerçant.
  ⚠️ **Décision** : « du réseau » = un transporteur que le commerçant a en
  favori (`party_type: 'fleet'`), OU n'importe quel dépôt actif du réseau ?
  Recommandation : **favori d'abord** en V1 (surface réduite, cohérent avec le
  ciblage), élargir si le pilote le demande. → §4.5.
- `dropoff_uuid` = **l'uuid du dépôt** (pas de `createPlace` pour la livraison).
  Les champs `dropoff*Contact*`, `dropoff*City*` etc. du DTO deviennent
  **ignorés** (le dépôt porte les siens). Le DTO les garde `@IsOptional` déjà —
  rien à changer côté validation, mais `createOrder` ne les lit plus sur cette
  branche.
- `codAmount` : **interdit** vers un dépôt en V1 (`badRequest('order.cod_to_depot_forbidden')`).
  Un encaissement à un dépôt (le transporteur paie le commerçant à réception ?)
  est une règle de trésorerie non tranchée — même prudence que le retrait du
  registre de caisse.
- `facilitator` : le `Vendor` du transporteur propriétaire du dépôt est posé
  `facilitator_uuid` **d'office** — la course lui est confiée, elle ne part pas
  au pool. C'est cohérent : livrer « au dépôt de X » veut dire « X s'en
  occupe ».
- Wilaya : `dropoff_province` = celle du dépôt (déjà sur le `Place`).

**App commerçant** : dans le formulaire de commande, un choix
« Livrer à : ○ un client  ○ un dépôt de transporteur ». Si « dépôt » → sélecteur
de dépôt (ses favoris entreprise → leurs dépôts). Le bloc « adresse de
livraison » est remplacé par la fiche du dépôt choisi (lecture seule).

### 3.3 Le dépôt expédie (transporteur → client)

`POST /flotte/commandes` — persona `fleet`. `CreateFleetOrderDto` : proche de
`CreateOrderDto` mais `pickupDepotUuid` (un dépôt du transporteur, `assertOwnsDepot`)
remplace les 12 champs `pickup*`, et `dropoff*` décrit un client normal.

`createFleetOrder(fleetId, dto)` :
- `customer_uuid = fleet.fleetbaseVendorUuid`, `customer_type = 'vendor'`.
- `payload.pickup_uuid = <dépôt>`, `payload.dropoff_uuid = createPlace(client)`.
- Le transporteur peut cibler **un de ses conducteurs** (favori) ou diffuser au
  pool. `price` obligatoire (il paie).
- Réutilise `buildOrderMeta`, `assertCustomFieldsComplete`,
  `createOrderOrCleanUp`, la compensation — le seul changement est l'origine du
  `customer_uuid` et du `pickup_uuid`.

⚠️ **Contrôle d'appartenance** : `createFleetOrder` doit refuser un
`pickupDepotUuid` qui n'est pas un dépôt de **ce** transporteur — sinon un
transporteur expédie « depuis » le dépôt d'un concurrent (règle 12).

### 3.4 Impacts Phase 1 sur l'existant

| zone | impact |
|---|---|
| client Fleetbase | **aucun nouveau** — `createOwnedPlace`/`getOwnedPlaces`/`deletePlace` existent |
| `flotte.controller` / `flotte.service` | +4 routes dépôts, +1 `POST /flotte/commandes`, +`assertOwnsDepot` |
| `flotte/dto` | +`SaveDepotDto`, +`CreateFleetOrderDto` |
| `CreateOrderDto` (commerçant) | +2 champs (`destinationType`, `depotUuid`) |
| `commercant.service.createOrder` | +branche « dropoff = dépôt » (résolution + validation avant le `try`, `facilitator` d'office, COD interdit) |
| **3 projections** | **inchangées** — c'est toujours `payload.pickup` / `payload.dropoff`. Un dépôt en `dropoff` se projette comme n'importe quel `Place`. |
| **modèle app `Order`** | **inchangé** |
| écran conducteur | inchangé — il voit une course 1→1 dont un bout est un dépôt |
| filtre wilaya / zone | inchangé (le dépôt a une `province`) |
| `cod_amount`, `price`, preuve | inchangés (1 par course) |
| app | +écran « Dépôts » (flotte), +choix destination (formulaire commerçant), +écran « expédier depuis un dépôt » (flotte) |
| i18n | clés dépôt FR + AR |
| scénarios | `test-depot-livraison.sh` (commerçant livre à un dépôt), `test-depot-expedition.sh` (le dépôt expédie), `test-depot-crud.sh` |

**Aucune projection touchée, aucun modèle app cassé** : c'est ce qui fait de la
Phase 1 un préalable sûr.

---

## 4. Phases 2-3 — la tournée

### 4.1 Modèle

Une tournée = **une commande Fleetbase** avec `payload.waypoints[]` (liste
ordonnée de `Place`) et `payload.entities[]` (colis, chacun rattaché à son
waypoint par `destination_uuid`). **Un `price`** sur la commande.
**Implémenté ainsi** : `cod_amount` (champ personnalisé) porte le **total** des
espèces de la tournée — lu par le plafond de dette sans changement —, et
`stop_cod_amounts` (champ personnalisé, `[{ place_uuid, amount }]`) porte le
détail par arrêt. Les deux sont durables (une affectation console écrase `meta`,
pas les champs personnalisés) ; `payload.waypoints` l'est aussi.

Composée **entièrement par le demandeur** (commerçant via `POST /commercant/tournees`,
ou transporteur via `POST /flotte/tournees` — même DTO). Offerte en bloc,
acceptée en bloc.

### 4.2 Ce qu'il faut construire

| zone | travail | état (08/09/2026) |
|---|---|---|
| `CreateTourneeDto` | `stops[]` : `{ place | depotUuid, items[], codAmount?, type? }` ordonnés · `price` · `scheduledAt?` · ciblage optionnel | ✅ `common/orders/dto/create-tournee.dto.ts` |
| `createTournee` (BFF) | construit `payload.waypoints[]` + `entities[]`, `price` unique, COD par waypoint · compensation | ✅ `OrderCreationHelpers.createTournee` / `buildTourneeMeta` ; `POST /flotte/tournees`. `cod_amount` = **somme** (champ perso durable), `stop_cod_amounts` = détail. Colis d'un enlèvement → `destination_uuid` = dernier arrêt |
| client Fleetbase | **élargir `createOrder`** pour accepter `waypoints` | ✅ union `{ pickup_uuid, dropoff_uuid } | { waypoints[], entities[] }` |
| **3 projections** | projeter `payload.waypoints[]`, expurgation **par arrêt** | ✅ `projectPayload` / `projectWaypoint` / `projectEntities` — enlèvement servi entier, livraison expurgée de l'identité ; `structuredAddress` extrait (règle 5) |
| **modèle app `Order`** | `+List<Waypoint>` ; `pickupPlace`/`dropoffPlace` = 1ᵉʳ / dernier arrêt | ✅ **additif** — `Order.waypoints`, `Waypoint`, `TourneeParcel` ; corrélation cod/colis dans `Order.fromJson` |
| app demandeur (flotte) | écran « créer une tournée » | ✅ `CreateTourneeScreen` + route `/flotte/tournees` + `createFleetTournee` |
| scénarios | création tournée, cod cumulé, colis rattachés, appartenance, forme | ✅ `test-tournee-creation.sh` (2 mutations prouvées) + jest (`tournee-creation.spec`, `waypoint-projection.spec`) + `order_tournee_test.dart` |
| **app conducteur** | fiche + carte à N arrêts, progression **par waypoint** — `getNextActivities(waypoint)` / `updateActivity(waypointUuid)` **déjà câblés** | ⬜ **RESTE** |
| déclaration d'encaissement | **par arrêt** : `declareCollection(waypointUuid, …)` | ⬜ **RESTE** — le plafond de dette est déjà correct (il lit `meta.cod_amount` = somme) ; ce qui manque est la déclaration indexée par waypoint |
| `POST /commercant/tournees` | même noyau, + la ligne `Order` locale (`merchantId`) + écran commerçant | ⬜ **RESTE** |

### 4.3 Ce qui NE bloque plus

Les deux décisions qui gelaient le sujet (`specs_localisation… §3`) sont
tranchées (§1). Le noyau (création, projection, modèle, écran flotte) est livré ;
ce qui reste est l'**app conducteur à N arrêts** et l'encaissement par arrêt.

### 4.6 Ce qui reste, dans l'ordre

1. **Fiche + carte conducteur à N arrêts.** L'app conducteur affiche
   aujourd'hui une course 1→1. Une tournée doit montrer la liste ordonnée des
   arrêts, l'avancement par waypoint, et faire progresser via
   `getNextActivities(waypoint)` / `updateActivity(waypointUuid)` (déjà câblés
   côté client). Le modèle `Order.waypoints` est prêt. À éprouver par un
   scénario d'intégration émulateur (les parcours joués à l'écran, cf.
   `docs/status_v1.md`).
2. **Encaissement par arrêt.** `declareCollection` devient
   `declareCollection(waypointUuid, …)` — `collected_amount/at/reason` indexés
   par waypoint. Le plafond de dette n'a pas à changer (il somme déjà).
3. **`POST /commercant/tournees`.** Même `OrderCreationHelpers.createTournee`,
   mais `customer` = le `Vendor` du commerçant, `targetUuid` = un favori
   (driver/fleet), **et** une ligne `Order` locale (`createOrderCache`) — le
   modèle Prisma exige un `merchantId`. Puis l'écran commerçant.
4. **Diffusion d'une tournée au pool** (Phase 3). V1 = ciblage conducteur seul.

### 4.4 Point ouvert — la wilaya d'une tournée

Pour le filtre wilaya (côté conducteur) et la zone de service (côté
transporteur) : une tournée traverse plusieurs wilayas par nature.
**Recommandation** : `pickupWilaya(tournée)` = wilaya du **premier enlèvement**,
cohérent avec une course simple (« là où le conducteur commence »). À figer
avant la phase 2.

### 4.5 Point ouvert — portée du sélecteur de dépôt (Phase 1)

Un commerçant qui livre vers un dépôt (§3.2) le choisit parmi : **ses favoris
entreprise → leurs dépôts** (V1, surface réduite) ou **tout dépôt actif du
réseau**. Recommandation : favoris d'abord.

---

## 5. Critères de vérification (style du dépôt)

### Phase 1 — bancs `scripts/`

- **`test-depot-crud.sh`** : le transporteur crée un dépôt (`meta.is_depot`
  posé, relu chez Fleetbase), le modifie (l'`owner_uuid` survit — piège
  `updateOwnedPlace`), le supprime. Un dépôt **d'un autre transporteur** :
  `GET/PUT/DELETE` refusés (`depot.not_found`, pas la ressource). Témoin
  positif à chaque pas.
- **`test-depot-livraison.sh`** : un commerçant crée une course
  `destinationType: 'depot'` → `payload.dropoff` = le dépôt (uuid exact),
  `facilitator_uuid` = le `Vendor` du transporteur, `adhoc: false`, la course
  n'apparaît **pas** au pool. `codAmount` vers un dépôt → refusé
  (`order.cod_to_depot_forbidden`). Témoin : la même course avec
  `destinationType: 'client'` part bien au pool (contraste).
- **`test-depot-expedition.sh`** : le transporteur crée une course via
  `POST /flotte/commandes` depuis un de ses dépôts → `customer_uuid` = son
  `Vendor`, `payload.pickup` = le dépôt. Un `pickupDepotUuid` **d'un autre
  transporteur** → refusé. La course est visible à son conducteur ciblé.
- **Mutation du vrai code** pour chacun (règle 8) : neutraliser
  `assertOwnsDepot`, ou le filtre `is_depot`, doit faire échouer le banc.
- `npm run build` + `tsc` ; jest (specs des helpers purs) ; `flutter analyze` +
  `flutter test` ; `dto-hygiene` couvre les nouveaux DTO ; `check_server_rules`
  si une borne du `SaveDepotDto` est recopiée côté app (a priori non).

### Cohérence règles `CLAUDE.md`

- **Règle 1** : le dépôt est un `Place` Fleetbase, **zéro donnée en base BFF**.
  Le marqueur `meta.is_depot` suit le patron `meta.is_default` existant.
- **Règle 9** : `POST /flotte/depots` n'est pas fini tant que l'app ne l'appelle
  pas **et** qu'une course ne peut pas pointer un dépôt (§3.2/§3.3). La Phase 1
  livre les deux — un dépôt qu'on ne peut que créer serait « du code sans
  appelant ».
- **Règle 12** : `assertOwnsDepot` refuse la ressource d'autrui ; `depotUuid` /
  `pickupDepotUuid` traversent `FleetbaseIdPipe` (`@Param`/`@Body` interpolés
  dans une URL Fleetbase).
- **Règle 13** : `SaveDepotDto`, `CreateFleetOrderDto` sont des classes
  décorées ; pas de type en ligne.
- **Règle 2** : `createFleetOrder` et `createOrder`-vers-dépôt réutilisent la
  compensation existante (`createOrderOrCleanUp`) — un `Place` d'enlèvement créé
  puis un échec de création de commande le nettoie.

---

## 6. Ce qui reste à trancher avant la phase 2

1. La **wilaya d'une tournée** (§4.4) — recommandation : premier enlèvement.
2. La **portée du sélecteur de dépôt** côté commerçant (§4.5) — recommandation :
   favoris d'abord.
3. Le **compte du transporteur** (§2.2) si un jour il lui faut un
   `MerchantAccount` distinct — différé, Phase 1 s'en passe.
4. **Diffusion d'une tournée au pool** vs ciblage seul — Phase 3 ; V1 (phase 2)
   peut se limiter au ciblage sur un conducteur du transporteur.
