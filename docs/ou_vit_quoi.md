# Où vit quoi — la carte, au 03/08/2026

Ce document répond à **une seule question** : pour une donnée donnée, où
est-elle rangée et pourquoi là.

Il existe parce que le partage BFF ↔ Fleetbase a changé trois fois en une
semaine, et qu'un lecteur d'aujourd'hui n'a pas à reconstituer l'histoire pour
savoir où écrire. L'histoire, elle, est dans
[`architecture_bff_fleetbase.md`](architecture_bff_fleetbase.md) (la décision du
29/07) et dans [`journal_travaux.md`](journal_travaux.md).

---

## La règle, en une phrase

> **Fleetbase porte tout ce qui décrit le monde ; le BFF ne garde que ce que
> Fleetbase ne peut pas porter — et le secret de connexion, que personne ne doit
> voir.**

Le critère opérationnel n'est pas doctrinal, il est concret : **la console
Fleetbase est utilisée en exploitation.** Une donnée qui n'existe que côté BFF
est absente de l'endroit où un opérateur la cherche. Un refus de course, un
échec de livraison, un favori expliquent chacun un blocage : les garder chez
nous, c'est obliger l'opérateur à nous appeler.

---

## 1. Ce qui vit chez Fleetbase

### 1.1 Sur la commande — 18 champs personnalisés

| clé | ce que c'est |
|---|---|
| `price`, `currency`, `price_source` | la rémunération du transporteur |
| `cod_amount`, `cod_goods_amount`, `cod_currency`, `cod_includes_delivery` | ce qui est réclamé à la porte |
| `vehicle_type`, `prefer_favourites` | les exigences de la course |
| `instructions`, `pickup_notes`, `dropoff_notes`, `items` | le contenu et les consignes |
| `collected_amount`, `collected_at`, `collection_reason` | **ce qui s'est passé à la porte** |
| `declines` | **les refus** : qui, quand, pourquoi, à quel prix |
| `delivery_failures` | **les échecs** : motif, précisions, preuve |

Les quatre dernières familles sont écrites **après** la création, par la clôture
ou par un refus. Les autres à la création.

⚠️ **Deux ne sont PAS projetées vers les applications** — `declines` et
`delivery_failures`. Un transporteur n'a pas à savoir qui d'autre a refusé la
course ni à quel prix. La liste des exceptions vit dans
`order-projection.spec.ts`, chacune avec son motif, et un test refuse qu'une
clé du catalogue soit oubliée dans un sens ou dans l'autre.

### 1.2 Sur le conducteur — 3 champs personnalisés

`zone_wilaya`, `zone_radius_km`, `vehicle_type`.

⚠️ Les définitions sont attachées **au conducteur lui-même** (`subject_uuid` =
son uuid), pas à une configuration partagée : il y en a donc trois **par
conducteur**. C'est ce que le modèle impose.

### 1.3 Sur le commerçant (son `Vendor`) — 1 champ personnalisé

`favourites` — la liste polymorphe de ses transporteurs et entreprises favoris.

### 1.4 Nativement, sans champ personnalisé

Nom, téléphone et raison sociale (`Vendor.name`, `Vendor.phone`,
`Driver`/`User.name`), les adresses (`Place`), les preuves photo (`Proof`), le
statut de la commande, le conducteur assigné, les positions.

---

## 2. Ce qui reste dans le BFF — 10 tables

### 2.1 L'identité — 3 tables

`MerchantAccount`, `FleetAccount`, `DriverAccount`.

Chacune ne porte plus que **le secret de connexion** — `email`, `password`,
`tokenVersion`, `active` — et **les liens** vers Fleetbase.

**Pourquoi ça reste** : Fleetbase n'a de compte pour aucun de nos trois
personas, et un hash de mot de passe rangé chez lui serait lisible par tout
utilisateur de la console. C'est le seul contenu qu'un opérateur ne doit
justement **pas** voir.

⚠️ **Mesuré le 03/08/2026** : sur 315 `User` Fleetbase de type `customer`,
**un seul** porte un mot de passe. Le secret n'est donc **pas dupliqué** — il
n'existe que chez nous. Migrer l'authentification n'en retirerait pas une copie,
elle en **créerait** 312.

### 2.2 Les relations que Fleetbase n'exprime pas — 1 table

`DriverMembership` — conducteur ↔ entreprise, avec un statut.

**Pourquoi ça reste** : `Driver.vendor_uuid` est un 1-n, il ne peut pas dire
« ce conducteur roule pour deux entreprises ». Et un champ personnalisé la
rendrait interrogeable dans **un seul sens** : « les conducteurs de l'entreprise
X » imposerait de balayer tous les conducteurs.

⚠️ Fleetbase a bien un `FleetDriver` natif, mais il lie `Driver` à `Fleet` — un
groupe de dispatch — quand nos entreprises sont des `Vendor`, et il ne porte
aucun statut. C'est un remodelage, pas un déplacement.

### 2.3 Les notifications — 3 tables

`DeviceToken`, `DriverDeviceToken`, `MerchantNotification`.

**Pourquoi ça reste** : le commerçant n'est délibérément **pas** un `User`
Fleetbase, donc le push natif (qui passe par `UserDevice`) ne peut pas le
joindre. Et un historique de notifications à croissance non bornée n'est pas un
champ personnalisé.

### 2.4 Le journal d'audit — 1 table

`AuditLog` — les **refus** d'accès.

**Pourquoi ça reste** : ce ne sont pas des données métier, et aucun opérateur
n'a à voir nos refus d'accès. Une revue antérieure les avait délibérément
sortis des journaux pour cette table.

### 2.5 Le cache et le curseur — 1 table

`Order` — 7 colonnes :

| colonne | rôle |
|---|---|
| `merchantId` | **à qui est cette commande** — la racine de toute l'autorisation |
| `status`, `driverAssignedUuid`, `lastSyncedAt` | la mémoire du réconciliateur |
| `id`, `fleetbaseOrderId`, dates | le lien |

⚠️ **Plus une seule donnée métier.** `specMeta`, qui portait une copie de ce que
le commerçant avait demandé, a été retiré le 03/08/2026.

---

## 3. Les pièges Fleetbase, tous mesurés

Ils ne sont pas documentés en amont, et chacun a coûté au moins une heure.

### 3.1 La LISTE ne porte aucun champ personnalisé

```
GET /int/v1/orders?limit=2&with[]=customFieldValues.customField
  → meta = {"_index_resource": true} · custom_field_values ABSENT
GET /int/v1/orders/{uuid}
  → meta réel · 4 valeurs
```

⚠️ **Tout chemin qui lit par `fetchEveryOrder` doit recharger** —
`FleetbaseApiClient.hydrateOrders`, par lots de huit, **après** les filtres que
la liste sait porter. Sinon le champ est **toujours vide** et rien ne le
signale.

### 3.2 Les enveloppes d'écriture

| ressource | corps attendu | identifiant accepté |
|---|---|---|
| commande | `{order: {custom_field_values}}` | `public_id` |
| conducteur | `{driver: {…}}` | `public_id` **seulement** |
| vendor | `{vendor: {custom_field_values}}` | `public_id` |

À plat, Laravel rend un **500** dont le message nomme un fichier du framework et
ne dit rien du contrat.

### 3.3 Le `PUT` FUSIONNE, il ne remplace pas

Mesuré : trois champs posés, un `PUT` n'en portant qu'un — les trois survivent,
et `meta` reste intact. C'est ce qui rend l'écriture de clôture sûre.

⚠️ Il fallait **poser** le témoin : lire une commande qui ne porte qu'un champ
ne distingue pas « les autres ont été détruits » de « elle n'en avait pas ».

### 3.4 La chaîne vide est refusée

Sur tout champ personnalisé, quel que soit son type. D'où `ZONE_UNSET = '-'`
pour dire « effacé ».

### 3.5 Une valeur `array` revient DÉJÀ désérialisée

Pas en chaîne JSON. Un `JSON.parse` inconditionnel échoue et fait passer une
liste pleine pour une liste vide.

### 3.6 Les collisions de noms sont silencieuses

Un champ personnalisé qui porte un nom déjà servi par Fleetbase — `currency`,
`notes`, `transaction_amount`… — ne produit **aucune erreur** : la valeur de
Fleetbase l'emporte. Les 56 clés servies par `Order.php` et `Index/Order.php`
sont épinglées dans `order-custom-fields.spec.ts`, et un test refuse toute
collision non déclarée.

⚠️ **À reprendre à chaque montée de version.**

### 3.7 Un filtre inconnu est abandonné SANS RIEN DIRE

`query=` sur les vendors est honoré — **mesuré avec témoin** : 456 vendors, un
fragment réel en rend 1, un fragment inventé **0**. Sans le témoin, un filtre
ignoré aurait rendu les 456 comme si c'était la réponse.

### 3.8 Ce qui a été ÉCARTÉ par la mesure

⚠️ **Fleetbase ne met PAS en cache une lecture faite juste après une écriture.**
Trois lectures successives voient le marqueur. C'était l'hypothèse la plus
naturelle pour expliquer un défaut, et elle aurait condamné toute la mécanique
lire-modifier-écrire. Elle est fausse — ça ferme la question ouverte du §6
d'`architecture_bff_fleetbase.md`.

---

## 4. La reprise de données

`scripts/backfill-order-custom-fields.sh` — **idempotent, prouvé par un second
passage**, et il tolère d'avoir déjà tourné (une table absente veut dire
« déjà migré », pas « échec »).

Il monte : `Order.specMeta`, `OrderDecline`, `DriverFavourite`,
`DeliveryFailure`, `DriverAccount.vehicleType`.

⚠️ **Il refuse de bénir un passage incomplet.** Un script de reprise qui lit des
lignes et n'en traite aucune n'a pas « rien à faire » : il a échoué sans le
dire. Trois versions ont menti avant que ce garde existe.

**À lancer avant `prisma db push` sur tout autre déploiement.**

---

## 5. Ce qui reste ouvert

- **L'accès console des conducteurs.** Un `User` de type `driver`, vérifié, se
  connecte à la console et **lit les commandes de toute l'organisation**. L'IAM
  ferme `vendors`, `contacts`, `places` — pas `orders`. Rien n'est exposé
  aujourd'hui (aucun de ces comptes n'a de mot de passe), mais c'est le
  préalable à toute migration d'authentification.
- **Le nom `meta` sur le contrat**, alors que la source est
  `custom_field_values`.
- **`customer_type` porte deux formes du même type** dans `orders`
  (`Fleetbase\FleetOps\Models\Contact` et `\Fleetbase\FleetOps\Models\Contact`).
  Un filtre polymorphe n'en verrait qu'une moitié — sans erreur.
