# Architecture BFF ↔ Fleetbase — décision et faits vérifiés

**Date : 29 juillet 2026.** Document de décision, écrit après une discussion qui a
produit une correction majeure d'une hypothèse fondatrice du projet.

**Statut : décision prise, mise en œuvre non commencée.** Aucune ligne de code n'a
été modifiée en conséquence. Trois vérifications restent à faire avant de toucher
au schéma (§9).

Ce document remplace, sur le sujet du partage des données, ce que disaient
`docs/journal_implementation_bff.md` §2.8 et les commentaires de code qui s'y
référaient. **§2.8 reste vrai comme observation et faux comme conclusion** — voir
§4.3.

---

## 1. Le problème posé

Question de l'utilisateur, le 29/07/2026 :

> « On fait de la double écriture, BFF et Fleetbase ? D'un point d'archi ce n'est
> pas propre. »

Elle est fondée. Mais trois choses différentes se cachaient sous « double
écriture », et elles n'ont ni la même gravité ni le même remède.

### 1.1 Ce qui n'existe que chez nous — 12 modèles Prisma sur 15

`MerchantAccount`, `FleetAccount`, `DriverAccount`, `DriverDeviceToken`,
`DriverInvitation`, `DeliveryFailure`, `DeviceToken`, `AuditLog`,
`DriverFavourite`, `OrderDecline`, `CashCollection`, `CashRemittance`,
`DriverEarning`, `MerchantNotification`.

Fleetbase n'en connaît rien et n'a pas vocation à en connaître. **Ce n'est pas de
la duplication, c'est notre métier.** Personne ne s'attend à trouver « ce
commerçant a mis ce transporteur en favori » dans un logiciel de flotte.

### 1.2 Ce qui doit aboutir des deux côtés — une transaction distribuée

Créer une commande **et** sa ligne de rattachement. Enregistrer un encaissement
**et** clôturer la course. Créer un compte commerçant **et** son `Vendor`.

Ce ne sont pas des copies d'un même fait, ce sont **deux faits différents qui
doivent tous les deux atterrir**, sans transaction commune entre MySQL (Fleetbase)
et PostgreSQL (BFF). Le remède n'est pas l'atomicité — indisponible — mais trois
propriétés : **ordre** (écrire d'abord le côté récupérable), **idempotence** (une
reprise après échec partiel doit être sûre) et **compensation** (défaire l'amont
si l'aval échoue).

Deux défauts réels de cette famille ont été trouvés et corrigés ce jour-là,
commit `e390a3b` — voir `journal_implementation_bff.md` §20.1.

### 1.3 La vraie duplication — deux endroits

Le cache `Order` (`status`, `driverAssignedUuid`, `driverName`, `trackingNumber`,
`codAmount`, `codIncludesDelivery`, `fleetbaseCreatedAt/UpdatedAt`) et le miroir de
position sur `DriverAccount` (`lastLatitude`, `lastLongitude`, `lastPositionAt`).

C'est de ça, et uniquement de ça, que parlait la question.

---

## 2. La décision

> **Fleetbase est la source de vérité.** Les admins Echango y accomplissent leurs
> tâches — inscription des transporteurs, validation des commerçants, dispatch,
> supervision. La console est donc une **interface de production légitime**, pas un
> outil de dépannage.
>
> **Le BFF ne conserve que ce que Fleetbase ne peut pas porter**, et fait le lien
> par identifiant Fleetbase. **Jamais de double écriture.**

Conséquence directe et immédiate : la console étant légitime, une valeur modifiée
par un admin dans `meta` **fait autorité**. L'objection d'intégrité qui justifiait
de miroiter `codAmount` (« `meta` est modifiable depuis la console ») tombe — c'est
un admin qui fait son travail, pas une altération.

---

## 3. Les trois exceptions nommées

Une règle sans vocabulaire pour ses exceptions se réérode en quelques semaines :
quelqu'un a besoin d'un cache, ne sait pas comment l'appeler autrement qu'un
doublon, et ajoute une colonne « juste celle-là ». C'est exactement ainsi que
`Order.status` s'est retrouvé avec trois écrivains.

**Trois choses ressemblent à un doublon sans en être un.**

### 3.1 Un cache éphémère n'est pas une écriture

Test : *si on vide ce cache, perd-on une information ?* Non → cache légitime, en
mémoire, avec durée de vie. Oui → second registre, interdit.

C'est ce qui autorise à garder les positions des transporteurs en mémoire pour la
carte de flotte, sans colonne en base.

### 3.2 Un curseur n'est pas la donnée

Retenir « j'ai traité les évènements jusqu'à telle date » n'est pas une copie de
l'état : c'est un filigrane de lecture. Une date, pas un fait métier.

### 3.3 Une écriture comptable fige ses entrées

`CashCollection.expectedAmount` conserve le montant attendu **au moment de
l'encaissement** ; `DriverEarning` conserve le taux de commission **appliqué à
cette course**.

Si un admin corrige le montant dans la console demain, l'encaissement d'hier ne
doit pas bouger — sinon la dette d'un transporteur changerait rétroactivement sans
que personne n'ait rien fait. **C'est un invariant comptable, pas une commodité
technique**, et il ne se négocie pas.

---

## 4. Correction majeure — Fleetbase sait filtrer côté serveur

### 4.1 Le mécanisme réel

`Fleetbase\Http\Filter\Filter::apply()` (package `core-api`) parcourt **tous** les
paramètres de la requête, moins `$skipParams`, et pour chacun cherche une méthode
du même nom sur la classe de filtre — d'abord tel quel, puis en camelCase :

```php
$methodNames = [$name, Str::camel($name)];
foreach ($methodNames as $methodName) {
    if (method_exists($this, $methodName)) { /* … */ break; }
}
```

**Il n'y a aucun repli** : ni filtre générique par colonne, ni liste blanche
alternative. Un paramètre sans méthode correspondante est **abandonné en silence**,
sans erreur ni code 400.

Les classes de filtre sont résolues par convention de nommage à partir du modèle
(`…\Models\Order` → `…\Http\Filter\OrderFilter`) : ni le contrôleur ni le modèle ne
déclarent explicitement la classe.

### 4.2 Les noms exacts, relevés sur la console

Capturés dans l'onglet réseau du navigateur, console Fleetbase → Commandes →
Filtres (29/07/2026) :

```
GET /int/v1/orders
  ?customer=<uuid>        &facilitator=<uuid>     &driver=<uuid>
  &pickup=<uuid>          &dropoff=<uuid>         &payload=<id>
  &public_id=14           &internal_id=52         &type=<uuid>
  &status=completed       &scheduled_at=…         &created_at=… &updated_at=…
  &created_by=<uuid>      &updated_by=<uuid>      &without_driver=true
  &sort=-created_at       &page=1                 &bulk_query=
```

```
GET /int/v1/drivers
  ?name=…                 &phone=…                &public_id=…
  &internal_id=…          &drivers_license_number=…
  &vendor=<uuid>          &fleet=<uuid>
  &created_at=2026-07-29,2026-07-30    (intervalle séparé par une virgule)
  &sort=-created_at       &page=1
```

Les trois qui nous intéressent — `customer`, `facilitator`, `driver` — prennent un
**uuid nu, sans suffixe**. `public_id` et `internal_id` sont des recherches
partielles.

**Preuve que le filtrage s'applique réellement** : la réponse de la requête
commandes ci-dessus est un `200 OK` avec `content-length: 110` — une enveloppe vide
— alors que le tableau contient 29 commandes. Les filtres combinés ne matchent
rien, ce qui est le comportement attendu. S'ils étaient ignorés, les 29 commandes
seraient revenues.

À noter : `layout=table` est un paramètre d'affichage de la console Ember, pas un
filtre. Il traverse `apply()`, ne trouve aucune méthode, et disparaît sans bruit.
**La console s'appuie elle-même sur le comportement qui nous a induits en erreur.**

### 4.3 Ce que le journal §2.8 avait réellement observé

§2.8 rapportait, à juste titre, que `GET /orders?facilitator_uuid=<x>` renvoie
toute la compagnie quelle que soit la valeur de `<x>`, et de même pour
`GET /drivers?vendor_uuid=<x>`.

**L'observation est exacte. La conclusion ne l'était pas.**

Les méthodes du filtre s'appellent **`facilitator`** et **`vendor`**, pas
`facilitator_uuid` ni `vendor_uuid` :

```php
public function facilitator(string $facilitator)
{
    $this->builder->where('facilitator_uuid', $facilitator);
}
```

`facilitator_uuid` → essai de `facilitator_uuid`, puis de `facilitatorUuid` →
aucune des deux n'existe → paramètre jeté. **On avait envoyé le mauvais nom.**

Le défaut de Fleetbase est donc réel mais ailleurs, et bien plus banal : **il
ignore en silence un paramètre inconnu au lieu de refuser la requête**, ce qui
transforme une faute de frappe en fausse limitation permanente. Un
`400 Unknown filter` nous aurait épargné trois reconstructions.

Ironie utile à retenir : §2.9 du même journal note que `facilitator` (sans suffixe)
avait été essayé — mais lors de la session où la variable shell était vide. Le bon
nom a été testé avec une mauvaise valeur, le mauvais nom avec une bonne valeur, et
les deux ont échoué pour des raisons différentes.

### 4.4 Ce que la correction change

Si confirmé par appel réel (§9), le filtrage revient côté serveur pour les trois
personas :

| Persona | Appel | Remplace |
|---|---|---|
| Commerçant | `GET /orders?customer=<vendor_uuid>` | filtrage mémoire sur le cache `Order` |
| Petite flotte | `GET /orders?facilitator=<vendor_uuid>` | `flotte.service.ts` — `fetchAllOrders` + filtre mémoire |
| Transporteur | `GET /orders?driver=<uuid>` | filtrage mémoire dans `transporteur.service.ts` |
| Recherche transporteur | `GET /drivers?query=<texte>` | `searchDrivers()` — rapatriement complet + filtre mémoire |

Trois conséquences :

1. **Le plafond de 100 cesse d'être un problème** : on ne pagine plus sur toute la
   compagnie pour en garder trois lignes.
2. **La table `Order` perd sa justification principale.** L'anti-IDOR unitaire se
   fait en comparant `customer_uuid` de la commande au `fleetbaseVendorUuid` du
   commerçant authentifié — le lien vit déjà chez Fleetbase.
3. **La règle de non-duplication devient bien moins coûteuse** que ce qui était
   annoncé au début de la discussion.

⚠️ **Cette section est issue de la lecture du code et de l'observation de la
console — exactement comme la conclusion fausse d'origine.** Rien ne doit être
supprimé avant les tests du §9.

---

## 5. État des filtres — vérifiés, cassés, absents

| Filtre | État | Détail |
|---|---|---|
| `orders?customer` | ✅ code + console | `where('customer_uuid', …)` |
| `orders?facilitator` | ✅ code + console | `where('facilitator_uuid', …)` |
| `orders?driver` / `driver_assigned` | ✅ code + console | accepte uuid **ou** public_id (`Str::isUuid()`) |
| `orders?without_driver` | ✅ code + console | non assignées et non terminées |
| `drivers?query` | ✅ code | `searchWhere(['name','email','phone'])` via la relation `user` |
| `drivers?name` | ✅ code | `whereHas('user', …)` |
| `drivers?vendor` / `fleet` / `status` | ✅ code | `vendor()` délègue à `facilitator()` |
| `places?owner_uuid` | ✅ **test réel** | journal §2.7 — vraie exception, ce n'est pas un nom de méthode mais il fonctionne |
| **`drivers?phone`** | ❌ **500** | voir §5.1 |
| `positions?driver_uuid` | ❌ **absent** | `PositionFilter` n'expose que `query` et `createdAt` (journal §2.11) — l'absence est réelle, pas une erreur de nom |
| `orders?time_window_start/end` | ❌ absent | aucun créneau natif (specs §7) |

### 5.1 Bug amont — le filtre `phone` des conducteurs renvoie 500

Reproduit depuis la console Fleetbase elle-même (29/07/2026, `500 Internal Server
Error` sur `GET /int/v1/drivers?…&phone=fgf&…`).

`DriverFilter::phone()` fait :

```php
$this->builder->whereHas('phone', function ($query) use ($phone) {
    $query->search($phone);
});
```

Or `phone` **n'est pas une relation** sur le modèle `Driver` : c'est un attribut
calculé, déclaré dans `$appends`, servi par un accesseur qui traverse
l'utilisateur lié :

```php
public function getPhoneAttribute() { return data_get($this, 'user.phone'); }
```

`whereHas()` exige une relation Eloquent ; sur un accesseur, Laravel lève
`RelationNotFoundException` → 500. **Le filtre téléphone de la console des
conducteurs est cassé pour tout le monde**, pas seulement chez nous — même famille
que le bug `capturePhoto()` (journal §6.12).

Les méthodes voisines montrent ce qu'il aurait fallu écrire : `name()` et `query()`
passent tous deux par `whereHas('user', …)`, la bonne relation.

**Conséquence pratique : utiliser `query`, jamais `phone`.** `query()` couvre le
téléphone de toute façon, à travers la relation `user`. On ne perd aucune
fonctionnalité en évitant le filtre cassé.

**Troisième famille de défauts amont identifiée à ce jour**, après le bucket de
`capturePhoto()` et la résolution non uniforme des identifiants. À reporter en
amont si le dépôt rouvre la création d'issues ; le correctif tient en une ligne.

---

## 6. Découverte non résolue — les lectures passent par un cache Redis

En-têtes relevés sur les deux requêtes console :

```
x-cache-driver: redis
x-cache-key:    {api_query}:orders:company_<uuid>:v357:<hash-des-paramètres>
x-cache-status: MISS
```

```
x-cache-key:    {api_query}:drivers:company_<uuid>:v66:<hash>
```

Les résultats de requête sont **mis en cache**, avec une clé à quatre étages :
ressource, compagnie, **numéro de version**, hachage des paramètres. C'est une
invalidation par génération — on n'expire pas les entrées, on incrémente le
compteur et les anciennes clés deviennent inatteignables.

Le compteur est **par ressource** (`v357` commandes, `v66` conducteurs) : une
écriture sur une commande n'invalide pas le cache des conducteurs. Bonne nouvelle
pour la granularité.

**C'est la première objection sérieuse à « on lit tout en direct ».** Si les
colonnes miroir disparaissent, il faut savoir :

1. **Quand le compteur est incrémenté** — à chaque écriture sur la ressource, ou
   seulement sur certaines opérations ?
2. **La durée de vie des entrées**, si le compteur ne bouge pas systématiquement.
3. **Si le cache s'applique aussi à l'API publique `v1`**, par laquelle passent
   toutes les opérations transporteur.

Scénario qui fait mal : le transporteur clôture une course, l'app recharge la
liste, Fleetbase ressert l'entrée d'avant. Aujourd'hui la colonne locale masque ce
décalage. En la retirant, on s'y expose — et un cache écriture-puis-lecture produit
exactement le type de bug qu'on ne reproduit jamais à la main, parce qu'on clique
trop lentement.

Détail au passage : les en-têtes de cache sont posés **avant** l'exécution du
handler — la réponse 500 du §5.1 en portait aussi.

---

## 7. Santé de Fleetbase — état au 29/07/2026

Recherche menée pour décider si l'outil mérite qu'on s'y attache durablement.

**Signaux favorables**

- Dernier commit le **17/07/2026**. Cadence soutenue : **v0.7.43 (5 juin) →
  v0.7.52 (17 juillet)**, dix versions en six semaines.
- 2,1 k étoiles, **723 forks** — un ratio de 34 %, typique d'un logiciel qu'on
  déploie plutôt qu'on admire.
- Issues fermées régulièrement, certaines en quelques jours.
- **Fleetbase Pte Ltd, fondée en 2018 à Singapour**, toujours active huit ans plus
  tard. **Bootstrapped, aucune levée.** Revenu par double licence AGPL/FCL : pas de
  dépendance à un prochain tour de table, donc pas le profil de mort subite d'une
  startup financée.

**Signaux défavorables**

- **Facteur bus ≈ 1.** `roncodes` (Ronald A. Richardson, cofondateur et CTO) écrit
  l'essentiel. Sur `fleetops` — l'extension dont nous dépendons entièrement — les
  dix derniers commits sont de lui. Les contributions extérieures observées sont
  des traductions.
- **5 employés** au total.
- **Huit ans et toujours en 0.7.x** : les API ne sont pas déclarées stabilisées par
  leurs propres auteurs.
- **`fleetops` a 17 étoiles** quand la plateforme en a 2 100 : le module métier
  qu'on utilise a très peu d'yeux dessus.
- Les chiffres d'adoption (**« 8 000+ instances, 10 M+ commandes »**) sont
  **auto-déclarés sur leur page investisseurs**, sans vérification indépendante
  trouvée. Signal externe le plus sérieux : référencement au catalogue open source
  de la Banque Interaméricaine de Développement.
- **Notre propre expérience**, qui vaut plus que tout le reste : Navigator
  abandonné après échec de compilation reproductible ; le bug `capturePhoto()` qui
  casse tout upload de preuve hors S3 ; la résolution d'identifiant non uniforme
  entre `v1` et `int/v1` ; et maintenant le filtre `phone`. Ce ne sont pas des cas
  tordus.

**Conclusion : socle ET tremplin.** Le risque n'est pas que Fleetbase disparaisse —
AGPL, 723 forks, le code est à nous. Le risque est qu'il **gèle** : plus de
correctifs de sécurité sur les dépendances Laravel, plus de mises à jour de
compatibilité, et un gros socle Laravel + Ember à reprendre sans mainteneur. Nous
n'en aurions pas les moyens.

**Donc : garder Fleetbase, rester capable de le quitter.** Trois attaches à
surveiller, aucune à défaire aujourd'hui :

1. **Les uuid Fleetbase comme clés étrangères** partout dans notre schéma — le lien
   le plus profond.
2. **L'app transporteur qui navigue selon `next-activity`** — la machine à états
   vit chez eux.
3. **La console comme seule interface d'administration** — c'est elle qui rend la
   réconciliation nécessaire.

Ce sont ces trois-là, et non le nombre de colonnes dupliquées, qui décideront du
coût d'une sortie.

---

## 8. Décisions découlant, non implémentées

### 8.1 Validation du commerçant — retenue

Décidée pour éviter les abus à l'inscription. Le commerçant est un `Vendor` ;
`VendorFilter` expose bien un `status` (`whereIn('status', …)`), donc le champ
existe et est filtrable. L'admin valide dans la console, le BFF lit ce statut à la
connexion et refuse tant qu'il n'est pas actif. **Aucune donnée dupliquée, la
décision reste chez Fleetbase.**

Change ce qui existe : l'inscription est aujourd'hui en libre-service et crée le
`Vendor` immédiatement. Elle devient une **demande** — compte et `Vendor` créés,
connexion refusée jusqu'à validation. Prévoir un écran « demande en cours » plutôt
qu'un refus de connexion, sinon le commerçant croira s'être trompé de mot de passe.

À vérifier : le nom exact du champ de statut sur `Vendor` et sa modifiabilité
depuis la console.

### 8.2 Invitation transporteur — conservée

Elle ne crée pas le `Driver` — c'est l'admin, en console — elle **rattache le
compte applicatif** à un `Driver` existant, par jeton haché à usage unique. C'est
précisément la pièce que Fleetbase ne peut pas porter, puisqu'on a délibérément
choisi de ne pas donner de credential Fleetbase aux transporteurs
(`specs_app_transporteur.md` §2.1). Reste côté BFF, sans doublon.

### 8.3 Webhooks plutôt que réconciliation — à évaluer

Fleetbase expose des webhooks (console → Developers → Webhooks), évènements en
`resource.action`, payload JSON **signé** POSTé vers un endpoint de notre choix.

Ce que ça apporterait : suppression du miroir `status` et du sondage périodique ;
Fleetbase devient source y compris pour les **évènements**, alors qu'aujourd'hui il
ne nous dit rien et qu'on le devine en le regardant ; et surtout, couverture du cas
qui rend la réconciliation obligatoire — **un admin qui assigne un transporteur
depuis la console**, hors de toutes nos routes.

`MerchantNotification` resterait : c'est une notification Echango, Fleetbase ne
connaît pas nos commerçants. Mais elle naîtrait d'un évènement reçu au lieu d'une
comparaison.

À vérifier avant de s'engager : la politique de relance en cas d'échec de
livraison du webhook, et si `fleetops` émet bien ses évènements (les webhooks sont
documentés au niveau plateforme). Si les relances sont faibles, garder un sondage
**de rattrapage** — filet, et non mécanisme central.

---

## 9. À vérifier avant de supprimer quoi que ce soit

Par ordre de conséquence. Tout ce qui précède repose sur de la lecture de code et
de l'observation de la console ; c'est précisément la méthode qui a produit
l'erreur d'origine.

1. **Les trois filtres, par appel réel** sur nos données :
   `orders?customer=`, `orders?facilitator=`, `orders?driver=`, plus
   `drivers?query=`. Comparer systématiquement un filtre **valide** et un filtre
   **inexistant** — c'est la seule façon de distinguer « filtre appliqué » de
   « filtre ignoré », les données cherchées étant incluses dans les deux cas
   (leçon du journal §2.8).
2. **Le comportement du cache après écriture** : modifier une commande, relire
   immédiatement, observer `x-cache-status` et le numéro de version de
   `x-cache-key`. Deux requêtes suffisent. Décide de l'ampleur de la suppression
   des miroirs.
3. **`$filterParams`** sur le modèle `Order` — couche non explorée qui pourrait
   restreindre ce qui passe.
4. **Le champ de statut du `Vendor`** (§8.1).
5. **Les webhooks `fleetops`** : émission réelle et politique de relance (§8.3).

Confirmer aussi que `phone` seul renvoie 500 alors que `name` seul renvoie 200
(§5.1) — bisection en deux requêtes.

---

## 10. Méthode — ce que la séquence a appris

**Trois fois, on a construit côté BFF ce qui existait déjà en amont** — isolation
par commerçant, isolation par flotte, recherche de transporteur — parce qu'un
paramètre au mauvais nom est mort en silence et qu'on en a tiré une règle générale.

Quatre règles en découlent :

1. **Avant d'écrire un filtre côté BFF, regarder ce que la console envoie pour la
   même question.** L'onglet réseau du navigateur donne les noms exacts en trente
   secondes. La console est l'implémentation de référence.
2. **Un filtre qui « a l'air » de marcher ne prouve rien.** Toujours comparer un
   filtre valide à un filtre inexistant : les données cherchées sont présentes dans
   les deux réponses, simplement noyées dans l'une.
3. **Ne jamais généraliser d'un endpoint à l'autre.** `places?owner_uuid`
   fonctionne, `positions?driver_uuid` n'existe pas, `drivers?phone` renvoie 500 —
   trois comportements différents sur la même API.
4. **Une conclusion tirée de la lecture du code reste une hypothèse.** Cette
   correction-ci a été obtenue par lecture, exactement comme l'erreur qu'elle
   corrige. Elle n'est pas acquise tant que le §9 n'est pas fait.

---

## Sources

Code Fleetbase (lu le 29/07/2026, branche `main`) :

- `core-api/src/Http/Filter/Filter.php` — `apply()` / `applyFilter()`
- `fleetops/server/src/Http/Filter/OrderFilter.php` — 27 méthodes
- `fleetops/server/src/Http/Filter/DriverFilter.php` — dont `phone()`, cassée
- `fleetops/server/src/Models/Driver.php` — `getPhoneAttribute()`
- `fleetops/server/src/Models/Order.php` — `$filterParams`, non exploré
- `core-api/src/Traits/HasApiControllerBehavior.php` — résolution du filtre

Observations console (instance locale, 29/07/2026) : requêtes réseau
`GET /int/v1/orders` (200, `content-length: 110`) et `GET /int/v1/drivers` (500),
avec leurs en-têtes de cache.

Santé du projet : dépôts GitHub `fleetbase/fleetbase` et `fleetbase/fleetops`,
page investisseurs de fleetbase.io, profils Crunchbase et Tracxn, catalogue open
source de la BID.
