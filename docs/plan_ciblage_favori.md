# Plan — ciblage d'un favori nommé, et redirection réversible

**Statut** : plan validé en discussion le 03/08/2026, **pas encore implémenté**.
À formaliser ici avant la première ligne de code, parce que ça touche le **cœur
du dispatch**.

## La décision produit

Un commerçant publie une course dans **l'un de deux modes explicites** :

- **Large** — diffusée au pool réseau (comportement actuel).
- **Ciblée** — confiée à **un favori nommé**, conducteur **ou** entreprise.

⚠️ **Ça remplace le modèle actuel « n'importe quel favori en ligne »**
(`pickAvailableFavourite`, qui prend le premier disponible et, à défaut,
diffuse automatiquement). Il n'y a plus de repli automatique.

### Le comportement quand le favori est indisponible

**La course attend.** Elle est **assignée au favori nommé même hors-ligne**,
invisible au pool, jusqu'à ce qu'il l'accepte — ou que le commerçant change de
cible.

⚠️ **Tradeoff assumé** : une course ciblée sur un favori hors-ligne est
potentiellement **plus lente** qu'une diffusion. C'est le prix du choix, et il
est conscient. Le déblocage n'est pas un délai automatique : c'est le
commerçant (voir Redirection).

## La redirection est réversible

Tant que **personne n'a pris la course** (statut Fleetbase non `started`, pas
d'acceptation), le commerçant peut **changer sa cible dans les deux sens** :

- ciblé → **large** (« diffuser en large ») ;
- large → **ciblé** (« re-cibler un favori ») ;
- ciblé A → ciblé B.

Une fois la course **acceptée ou démarrée**, la cible est **verrouillée** :
toute redirection est refusée (`conflict('order.already_taken')`).

⚠️ **La réversibilité a une fenêtre de course** : entre le moment où le
commerçant décide de re-cibler et l'écriture chez Fleetbase, un conducteur du
pool peut avoir accepté. La redirection **relit le statut** juste avant d'agir
et refuse si la course a été prise entre-temps. On ne mémorise rien à côté du
statut Fleetbase (règle 1).

## Ce qui change dans le code

### 1. Donnée (DTO + stockage)

- `create-order.dto.ts` : remplacer `preferFavourites?: boolean` par
  `targetFavourite?: { uuid: string; kind: 'driver' | 'fleet' }` (absent = large).
- **Validation** : `uuid` doit appartenir aux **favoris du commerçant** —
  `badRequest('order.target_not_favourite')` sinon. On ne cible pas un inconnu.
- **Stockage durable** : champs personnalisés `target_favourite_uuid` +
  `target_favourite_kind` (règle 1), `meta` en doublon pour l'historique.

### 2. Publication (`publishOrder` + création)

- Lire la cible dans `meta`.
- **Cible présente** → assignation directe, **en ligne ou non** :
  conducteur → `assignOrderToDriver`, entreprise → `attachFacilitator`
  (`adhoc: false`), puis `dispatchOrder`.
- **Pas de cible** → `releaseOrderToPool` (large), comme aujourd'hui.
- **On SUPPRIME** le repli « aucun favori en ligne → diffusion auto ».
- `pickAvailableFavourite` (choix du premier favori en ligne) disparaît : la
  cible est désormais **désignée**, pas devinée.

### 3. Redirection — un endpoint, deux sens

- `POST /commercant/commandes/:id/rediriger`, corps
  `{ target: 'large' | { uuid, kind } }`.
- **Précondition** : course **non acceptée / non démarrée** (relue chez
  Fleetbase). Sinon `conflict('order.already_taken')`.
- **Action** : détacher la cible actuelle (dé-assigner conducteur / retirer
  facilitateur, ou retirer du pool) → poser la nouvelle (assigner favori, ou
  `releaseOrderToPool`) → re-dispatcher. Mettre à jour les champs personnalisés.
- ⚠️ **Écriture multiple non atomique** (règle 2) : nommer la fenêtre d'échec,
  compenser, journaliser la redirection (`audit`) — c'est une décision, pas un
  drapeau silencieux (règle 12).

### 4. État & visibilité (règle 1 — aucun état parallèle)

- Course ciblée-non-acceptée = statut `dispatched` + `driver_assigned_uuid` =
  la cible + `adhoc: false`. **Invisible au pool** : `isClaimableAdhoc` exige
  déjà `adhoc` sans conducteur assigné. ✅ Tient sans champ nouveau.
- « En attente de [favori] » côté commerçant = **dérivé de l'affichage**.

### 5. Application Flutter

- **Création** : choisir « large » ou « ce favori » (sélecteur depuis la liste
  de favoris — conducteur ou entreprise).
- **Course non prise** : action **« Rediriger »** (vers large, ou vers un
  favori).
- Écrans partiellement existants — à mesurer avant.

## Le scénario qui le prouve

`scripts/test-visibilite-ciblage.sh` — deux conducteurs (favori X, non-favori Y) :

1. commerçant cible X → course **assignée à X**, **absente** des opportunités de
   Y, **absente** du pool, `Y → GET :id` = **404** ;
2. X **la voit** en « assigné » — **témoin positif** (sans lui, un filtre qui
   cache tout à tout le monde passerait) ;
3. commerçant **rediriger → large** → **maintenant visible** dans les
   opportunités de Y ;
4. commerçant **rediriger → X** de nouveau → réservée à X, invisible à Y ;
5. rediriger une course **déjà acceptée** → **refusée** (`order.already_taken`).

Ce scénario **est** la couverture de visibilité croisée demandée au départ,
plus la redirection.

## Ce que ça touche

`commercant.service.ts` (création + publication + `redirectOrder`),
`commercant.controller.ts` (+1 route), `create-order.dto.ts`, les champs
personnalisés, l'app Flutter (2 écrans), 1 scénario.

## Socle vérifié en réel (03/08/2026)

✅ **Assigner un conducteur hors-ligne** — testé sur Ahmed (`online=false`) :
`POST /int/v1/drivers/{uuid}/assign-order` pose `driver_assigned_uuid`, la
commande reste `created`, `adhoc: false`. La présence GPS n'est pas exigée.

✅ **Attacher une entreprise** — `PUT /int/v1/orders/{uuid}` avec
`facilitator_uuid` + `facilitator_type: fleet-ops:vendor` + `adhoc: false`
fonctionne quel que soit l'état du vendor.

Donc « la course attend, assignée à un favori hors-ligne » tient. Implémentation
en cours.
