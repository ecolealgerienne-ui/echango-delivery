# Le facilitateur — entreprises de transport et leurs conducteurs

*Rédigé le 31/07/2026, après une revue par cinq agents spécialisés (conformité
Fleetbase, architecture, sécurité, métier, exactitude factuelle). **Rien n'est
implémenté.** Ce document décrit ce que Fleetbase porte déjà, ce qui reste à
notre charge, les défauts que ce cadrage a révélés dans le code existant, et
l'ordre dans lequel écrire.*

Il complète `docs/specs_flux_argent_quatre_acteurs.md`, qui a instruit la seule
question de l'argent.

> **Contrainte qui prime sur tout le reste, posée le 31/07/2026 : respecter le
> fonctionnement par défaut de Fleetbase.** Une proposition qui suppose de
> modifier une configuration Fleetbase, d'en dériver un état parallèle ou d'en
> détourner un champ est écartée, même quand elle est plus élégante. Le §4.4 en
> donne un exemple : une suggestion est retirée pour cette seule raison.

**Ce que la revue a changé dans ce document.** La première version affirmait
quatre choses fausses et en ignorait cinq. Elle déclarait `facilitator_type`
« vérifié par test réel » deux lignes avant de dire qu'il était déduit ; elle
annonçait que le garde de validation du commerçant « s'applique tel quel » à une
entreprise, alors qu'il n'est pas branché ; elle prévoyait un arbitrage entre
deux réclamants qui ne se disputent rien ; et son modèle de registre ne pouvait
structurellement pas porter la chaîne interne qu'il décrivait. Ces quatre
corrections sont intégrées ci-dessous, chacune à sa place.

---

## 1. Ce qu'est un facilitateur

Fleetbase distingue **deux entités commerciales sur une même commande** :

- `customer_*` — **qui commande** la course. Chez nous : le commerçant.
- `facilitator_*` — **qui la réalise**. Chez nous : l'entreprise de transport.

Ce sont deux rattachements polymorphes (`_uuid` + `_type`), déclarés dans le
`$fillable` du modèle `Order`. La distinction est native, antérieure à nous, et
porte exactement la sémantique dont nous avons besoin — ce qui explique que ce
chantier n'ajoute aucun champ à Fleetbase et ne demande aucun fork.

Le troisième acteur, le **conducteur**, n'est pas une entité commerciale : il est
désigné par `driver_assigned_uuid` et rattaché à son entreprise par
`Driver.vendor_uuid`.

## 2. Décisions prises le 31/07/2026

> ⚠️ **DÉCIDÉ, PAS ENCORE BRANCHÉ (vérifié dans le code le 01/08/2026).**
>
> Les cases ✅ de cette section marquent des décisions **prises**, pas des
> fonctionnalités livrées. À ce jour, `resolveFacilitator()` rend `null` dès que
> `facilitator_uuid` est absent, et **rien ne pose Echango comme facilitateur
> d'une course du pool** — les seuls écrivains de cette colonne sont la prise par
> une entreprise et la remise au pool qui l'efface.
>
> Conséquence : sur une course du pool, la chaîne reste à **deux** maillons
> (conducteur → commerçant), la commission reste non recouvrable, et c'est le
> commerçant qui porte le risque. Le §7.1 décrit donc l'état **cible**.
>
> Également décidés et non branchés : les **favoris polymorphes** (§6.1) et le
> **persona opérateur** (D21). `isPlatform` existe et fonctionne, mais reste
> dormant faute d'un facilitateur plateforme posé automatiquement.


### 2.1 ✅ Le facilitateur porte l'argent vis-à-vis du commerçant

> **Quand il y a un facilitateur dans la boucle, c'est le facilitateur qui porte
> l'argent vis-à-vis du commerçant, et le conducteur porte l'argent vis-à-vis de
> son facilitateur.**

Qui encaisse n'est pas qui doit. Le conducteur tient les espèces ; la dette est
celle de l'entité avec laquelle le commerçant a contracté. Voir §7 pour le
déroulé chiffré et ses conséquences.

### 2.2 ✅ Il y a toujours un facilitateur — Echango pour les indépendants

Le pool Echango n'est pas l'absence de prestataire : **Echango Delivery est le
facilitateur des courses du pool.** Un seul chemin de choix, un seul chemin de
dispatch, une seule table de favoris, un seul couple de parties dans le
registre. Le cas « indépendant » cesse d'être un cas particulier.

C'est une décision de **structure**. Le §2.3 en tire la conséquence financière,
et elle est acquise elle aussi.

### 2.3 ✅ Echango porte l'argent, y compris sur les courses du pool

**Décision du 31/07/2026, prise après objection et maintenue :**

> « Echango est aussi un facilitateur, on doit faire des contrats pour les
> drivers indépendants, on joue notre image, on ne peut pas laisser les
> commerçants à la merci des drivers non plus. »

C'est le modèle du transporteur intégré (Yalidine, ZR, Noest — dominant sur le
marché visé, `docs/comparaison_marche_commercant.md`) : le commerçant n'a qu'un
interlocuteur, et cet interlocuteur répond.

**L'objection que j'avais soulevée tombe sur son point principal.** Je disais
qu'une société répond de ses conducteurs *parce qu'elle les emploie* — contrat,
salaire, procédure — et qu'Echango se contente de *sélectionner*, sans moyen de
recouvrement. **Le contrat passé avec l'indépendant est précisément ce moyen.**
La différence que je croyais structurelle était contractuelle, et elle se comble
par un contrat.

**Ce que cette décision simplifie.** Si Echango répond de ses conducteurs comme
une entreprise répond des siens, le drapeau `answersForItsDrivers` que la
première version introduisait **n'a plus d'objet** : il vaudrait `true` partout.
Une seule règle, sans exception :

> **Le facilitateur doit au commerçant. Le conducteur doit à son facilitateur.**

Il reste **une** variation, et ce n'est pas une exception au principe mais une
différence d'information : **ce que le conducteur retient sur les espèces**.
Chez Echango il retient sa course, parce que sa rémunération est un montant que
nous connaissons (`meta.price`). Chez une entreprise réelle il retient 0, parce
que sa paie est interne et ne nous sera jamais communiquée. Voir §7.2.

**Ce que cette décision coûte, et qui doit être provisionné :**

1. **Echango devient une partie du registre et n'a aucun compte.** Personne ne
   peut confirmer la remise qu'un conducteur lui fait — donc sa dette ne
   s'éteint jamais et le registre se remplit indéfiniment. Il faut un **persona
   opérateur Echango** : voir le registre, confirmer les remises reçues,
   déclarer celles faites aux commerçants. Quatrième profil, pas une case à
   cocher. Défaut **D21**.
2. **Une exposition de trésorerie.** Echango doit au commerçant pendant qu'il
   recouvre auprès du conducteur : l'exposition est la somme des dettes
   conducteurs non soldées. Le plafond de dette (§7.6) devient l'instrument qui
   la borne — ce n'est plus le commerçant qu'il protège, c'est nous.
3. **La vérification juridique sur la détention de fonds pour compte de tiers**
   (`specs_paiement_livraison.md` §9) passe de « différée » à **bloquante avant
   le pilote**. Echango ne touche toujours pas physiquement l'argent — la Voie B
   tient sur ce point — mais il assume désormais une obligation de paiement,
   ce qui n'est pas le même objet.
4. **`scripts/test-parcours-argent.sh` change de forme sur son §5.** Le
   conducteur y déclare une remise **au commerçant**, que le commerçant
   confirme ; sa contrepartie devient Echango, et c'est l'opérateur qui
   confirme. C'est le seul endroit du script qui bouge, et il faut le remplacer
   par son équivalent plutôt que le supprimer — voir §14.

## 3. Le logement natif — état de vérification

Quatre catégories, et elles ne se confondent pas. La quatrième a été ajoutée par
la revue : **déduit par analogie** n'est pas *lu dans le source*, et c'est
exactement le mode de raisonnement qui a coûté trois reconstructions à ce projet
(`architecture_bff_fleetbase.md` §10.3 : « ne jamais généraliser d'un endpoint à
l'autre »).

| Besoin | Mécanisme | Statut |
|---|---|---|
| L'entreprise comme entité | `Vendor` | ✅ **appel réel** — le persona flotte en est déjà un |
| Lister les courses d'une entreprise | `GET /orders?facilitator=<uuid>` | ✅ **appel réel avec témoin** (Lot 0 : réel 2, témoin 0) |
| Rattacher un conducteur | `POST /vendors/{uuid}/assign-driver` | ✅ **appel réel** (28/07) |
| Affecter un conducteur | `driver_assigned_uuid` | ✅ **appel réel**, isolation deux flottes (A 201 / B 403) |
| Valider / suspendre | `Vendor.status` ∈ {`active`,`inactive`,`suspended`} | ✅ **appel réel** (Lot 4, sur le commerçant) |
| Écrire `facilitator_uuid` à la création | colonne `$fillable` | ⚠️ **vérifié indirectement** — voir §3.1 |
| `facilitator_type` | colonne polymorphe | ✅ **appel réel** — la valeur stockée est `fleet-ops:vendor`, voir §12 C1 |
| Lister les conducteurs d'une entreprise | `GET /drivers?vendor=<uuid>` | ⚠️ **lu dans le source**, jamais testé — absent de `verify-fleetbase-filters.sh` |
| `Fleet` = groupe de conducteurs | — | ❌ **déduit d'un nom de filtre** relevé dans l'onglet réseau |

**Conclusion inchangée : il n'y a rien à ajouter à Fleetbase.** Ce qui manque
n'est pas un champ, c'est un chemin produit entre « le commerçant commande » et
« l'entreprise reçoit ».

### 3.1 `facilitator_type` — l'hypothèse la plus fragile du chantier

Le journal §2.9 est le récit d'une **fausse alerte** (une variable shell vide) et
conclut « fonctionnent parfaitement dès le premier essai » — **sans consigner
aucune relecture**. Le contraste avec §2.10, qui écrit explicitement « puis
vérification directe côté Fleetbase — `customer_uuid` correctement peuplé,
`customer_type: "vendor"` », est la preuve que la relecture n'a pas eu lieu.

Et l'analogie avec `customer` est **affaiblie par sa propre source** : le même
§2.9 note que `customer` a un résolveur dédié (`normalizeCustomerType()`) et que
la clé `facilitator` **n'en a pas**. Les deux colonnes ne sont pas traitées
pareil en amont.

**Le contrôle doit prouver la résolution, pas le stockage.** Relire la valeur ne
suffit pas : `specs_echango_delivery.md` §3.1 raconte le cas d'un
`customer_type` stocké `\Fleetbase\FleetOps\Models\Vendor` — **un backslash
initial en trop, valeur bien présente en base et relisible, et pourtant la
commande était invisible**. La même source recommande mot pour mot de
« vérifier/normaliser systématiquement le format de `customer_type` (et
`facilitator_type`) ». Contrôle **C1**, §12.

## 4. Pourquoi `Vendor`, et pas `Fleet` ni `Entities`

| Candidat | Ce que c'est | Verdict |
|---|---|---|
| `Entities` de l'`OrderConfig` | les **marchandises** — `weight`, `dimensions`, `barcode`, `sku` | ❌ y loger une société ferait porter au champ un second sens, l'erreur que `meta` nous a coûtée |
| `Fleet` (fleet-ops) | un **groupe de conducteurs** dans une compagnie (`GET /drivers?fleet=`) | ⚠️ outil d'organisation, pas d'identité — et sa description reste une déduction |
| `Vendor` | entité commerciale, statut, conducteurs rattachés | ✅ |

**L'argument porteur est un seul, et il est solide : `facilitator_*` pointe vers
un `Vendor`, et rien d'autre.** La première version de ce document ajoutait que
« `Vendor` est la seule des trois à porter un statut modifiable en console » —
affirmation **non sourcée** : rien dans le dépôt ne décrit les colonnes de
`Fleet`. Elle est conservée comme observation à vérifier (contrôle **C6**), pas
comme fondement ; si `Fleet` portait un statut, la conclusion ne changerait pas.

**Conséquence assumée : commerçant et entreprise de transport sont le même type
d'objet chez Fleetbase.** Ce qui les distingue est leur **rôle sur la commande**.
C'est une propriété, pas une limite : une même société pourrait un jour être les
deux.

`Fleet` redeviendra pertinent quand une entreprise voudra grouper ses
conducteurs (zone, catégorie de véhicule) — ce serait alors le foyer naturel de
`DriverAccount.vehicleType`. Hors périmètre.

## 5. Le cycle de vie d'une course confiée

### 5.1 Les quatre temps

```
créée ──▶ publiée ──▶ confiée à l'entreprise ──▶ affectée ──▶ démarrée ──▶ livrée
          dispatched   facilitator_uuid          driver_assigned_uuid
```

### 5.2 L'état se lit sur **trois** champs natifs, pas deux

La première version disait deux (`facilitator_uuid`, `driver_assigned_uuid`).
C'est insuffisant : depuis le lot brouillon/publier du 30/07, une commande naît
`dispatched: false, adhoc: false` et n'est diffusée qu'à la publication. Une
lecture à deux champs afficherait « confiée à l'entreprise » **un brouillon que
le commerçant n'a jamais publié**.

- non publiée (`dispatched` faux) ⇒ brouillon, invisible de tous sauf du commerçant ;
- publiée, `facilitator_uuid` nul ⇒ au pool ;
- publiée, `facilitator_uuid` posé, `driver_assigned_uuid` nul ⇒ **confiée, non affectée** ;
- les deux posés ⇒ affectée.

**Ce n'est pas une dérivation interdite.** Ce que la règle 1 proscrit est
d'inventer un second vocabulaire — calculer un état et le renvoyer comme un
champ à part, ce qui a produit la divergence de `is_draft`. Le précédent exact
est inscrit dans le code : `order.projection.ts` documente le retrait de
`is_draft` par « le statut Fleetbase fait foi […] il est déjà dans
`ORDER_FIELDS`, l'application en déduit ce qu'elle a besoin d'afficher ». Ici,
les trois champs sont servis en direct et l'écran en déduit son libellé ; un
écran qui se trompe se corrige sans qu'aucune donnée n'ait à être réparée.

⚠️ `projectOrderForMerchant` **n'expose pas** `ORDER_LINK_FIELDS`
(`order.projection.ts`). Si le commerçant doit voir « confiée à X, pas encore
affectée », la projection est à modifier — voir défaut **D19**.

### 5.3 ❌ Retiré : ajouter une activité `assigned` au flux

Une version antérieure proposait une activité native `assigned`, conditionnée
par `Activity.logic` sur l'existence de `facilitator_uuid`.

**Retiré en application de la contrainte du 31/07** : modifier l'`OrderConfig`
est une modification de configuration Fleetbase, et c'est le seul point où cette
vision s'en écartait.

*Le motif technique invoqué d'abord était faux et la revue l'a corrigé* :
« une activité déplacée rend tout dispatch muet » ne s'applique pas — *ajouter*
une activité ne renomme ni ne retire `dispatched`, que
`getDispatchActivity()` retrouverait quoi qu'il arrive. Le vrai risque est
ailleurs et il est plus fort : **on ne sait pas si la console et
`getDefaultOrderConfigUuid()` (`configs.find(c => c.key === 'transport') ||
configs[0]`) désignent la même configuration.** Modifier un flux qu'on ne sait
pas identifier, c'est modifier au hasard.

Le coût du retrait est nul : les trois champs natifs suffisent (§5.2).

### 5.4 Précision sur le dispatch

`Order::dispatch()` pose `dispatched`/`dispatched_at` sans écrire `status` — les
deux sont des faits distincts. **Mais la route que nous utilisons,
`PATCH /int/v1/orders/dispatch`, appelle `dispatchWithActivity()`, qui écrit les
deux** (validé en réel, journal §29.1). Ne pas conclure de la première phrase que
le statut ne bouge jamais à la publication.

## 6. Les deux portes d'entrée

Une course arrive chez une entreprise par deux chemins. **Ils écrivent la même
chose**, et c'est ce qui évite une branche conditionnelle en aval.

### 6.1 Porte 1 — le commerçant choisit l'entreprise

À la création, `facilitator_uuid` est posé et **`driver_assigned_uuid` ne l'est
pas** : confier la course à une société *et* nommer son conducteur serait décider
à sa place. L'entreprise désigne le sien avec
`POST /flotte/commandes/:id/assigner`, qui existe déjà.

Suppose des **favoris polymorphes** (`specs_flux_argent_quatre_acteurs.md` §6.1)
— une entreprise se met en favori comme un transporteur, la recherche rend les
deux types en disant lequel est lequel. C'est la porte principale à terme, et la
plus tardive.

⚠️ **Le filtre de `GET /flotte/commandes` doit exclure les non publiées**
(`flotte.service.ts` ne filtre aujourd'hui que sur `facilitator_uuid` plus un
`status` facultatif **venant du client**). Sans quoi une entreprise voit — et
peut affecter un conducteur à — un brouillon.

### 6.2 Porte 2 — l'entreprise prend une course du pool

L'entreprise réclame une course diffusée en posant `facilitator_uuid`.
C'est la porte la plus importante au démarrage : elle donne un rôle à
l'entreprise **sans obliger le commerçant à la connaître**, donc sans dépendre
des favoris polymorphes.

**Trois choses que la première version ignorait, et qui changent la conception.**

**(a) Il n'y a aucune course critique à arbitrer, parce que les deux populations
n'écrivent pas la même colonne.** Un indépendant réclame par
`POST /v1/orders/{id}/start` avec `assign` — qui pose `driver_assigned_uuid` — ;
une entreprise poserait `facilitator_uuid`. **Les deux écritures réussissent.**
Résultat : la course est confiée à l'entreprise F **et** démarrée par
l'indépendant D. F affecte alors son conducteur, `assignOrderToDriver` écrase
`driver_assigned_uuid`, et D — déjà en route avec le colis — disparaît de la
commande. Sur une course encaissée, `settleCashIfDue` s'appuie sur `isAssignedTo`
et **refusera sa clôture** : il tient les espèces et l'argent sort du registre.

Le prédicat de prise doit donc exiger **les deux colonnes libres, dans les deux
sens** : un indépendant ne prend pas une course qui porte un facilitateur, une
entreprise ne prend pas une course qui porte un conducteur.

**(b) Fleetbase n'offre aucun arbitrage natif sur `facilitator_uuid`.** Poser la
colonne passe par un `PUT /int/v1/orders/{uuid}`, sans mise à jour
conditionnelle, sans verrou optimiste : dernier écrivain gagne, le perdant reçoit
un 2xx. La seule parade compatible avec le comportement par défaut est un
**compare-and-set applicatif** — écrire, **relire**, et si le facilitateur relu
n'est pas le nôtre, refuser (`order.already_taken`) sans rien compenser d'autre.
C'est une écriture multiple au sens de la règle 2 : la fenêtre est nommée, elle
n'est pas fermée. ⚠️ La relecture peut être servie par le **cache Redis**
(`architecture_bff_fleetbase.md` §6) — à vérifier, contrôle **C3**.

**(c) Le dispatch adhoc relance tout seul, et c'est le point le plus important de
cette section.** `specs_echango_delivery.md` §3.2, **confirmé par test réel le
26/07** : `adhoc: true` déclenche une recherche géospatiale, un `OrderPing` à
tous les conducteurs disponibles dans le rayon, et **une relance automatique
toutes les ~4 minutes tant que personne n'accepte**. Le broadcast n'est filtré ni
par `Fleet`, ni par zone — seulement par un rayon.

Poser `facilitator_uuid` ne touche ni `adhoc` ni `driver_assigned_uuid` :
**Fleetbase continuerait de proposer aux indépendants une course déjà réclamée
par une entreprise**, et notre filtre de liste (défaut D4) n'y peut rien — les
pings partent de Fleetbase. La prise doit donc écrire **`adhoc: false` dans le
même geste** que le facilitateur, ce que `withdrawFromDispatch()` fait déjà.

⚠️ Deux pièges du `PUT` sur une commande, à écrire noir sur blanc : tout client
qui inclut une clé `meta` **remplace `meta` en entier** — n'envoyer que les clés
voulues, jamais une commande re-sérialisée ; et poser `adhoc` par un `PUT`
déclenche le drapeau `dispatched` **sans** l'activité, ce qui bloque ensuite la
route `v1` de dispatch.

### 6.3 Une fois prise

La course **disparaît du pool pour tout le monde** — ce qui exige les trois
mesures ci-dessus, et non le seul filtre de liste.

## 7. L'argent

### 7.1 Le déroulé chiffré

Course de référence : marchandise 1300 + course 650 = **1950 réclamés à la
porte**, commission Echango 20 %.

**Aujourd'hui, sans facilitateur** (vérifié en réel, journal §29) :

| | montant |
|---|---|
| destinataire → conducteur | 1950 |
| le conducteur retient sa course | 650 |
| **il doit au commerçant** | **1300** |
| il doit à Echango (commission, non recouvrée) | 130 |

**Demain, facilitateur Echango (pool)** — la décision du §2.3 :

| | montant |
|---|---|
| destinataire → conducteur | 1950 |
| le conducteur retient sa course | 650 |
| il doit à Echango, espèces du commerçant | 1300 |
| il doit à Echango, commission | 130 |
| **total qu'il remet à Echango** | **1430** |
| **Echango doit au commerçant** | **1300** |
| ce qui reste à Echango | 130 |

Le montant des **espèces** dues par le conducteur ne change pas — 1300 hier,
1300 demain. Seule change la personne en face. Echango est un passage : il doit
exactement ce qu'on lui doit, et son risque est l'écart de temps entre les deux.

**Effet de bord favorable, et il n'est pas mince : la commission devient
recouvrable.** Son recouvrement était jusqu'ici « non construit » et assumé
comme tel (`cash.service.ts`, `platformCommissionOwed`) — parce qu'aucun flux
d'argent n'existait entre le conducteur et Echango, et qu'on n'allait pas
facturer un indépendant course par course. Dès lors que le conducteur doit une
remise à Echango, la commission se **compense sur cette remise** : elle cesse
d'être une créance à réclamer pour devenir une déduction sur une dette qui
existe déjà. C'est un gain que la décision du §2.3 apporte et que la version
« place de marché » ne permettait pas.

**Avec une entreprise réelle** :

| | montant |
|---|---|
| destinataire → conducteur | 1950 |
| le conducteur retient | **0** |
| **il doit à son entreprise** | **1950** |
| **l'entreprise doit au commerçant** | 1950 − 650 = **1300** |
| l'entreprise doit à Echango | 130 |

Chaque nœud **externe** est identique. C'est la bonne propriété, et elle est
réelle.

### 7.2 Le conducteur d'entreprise ne retient rien — et sans cette phrase, le code décide seul

`settleCashIfDue()` appelle inconditionnellement
`recordEarning(driverId, merchantId, uuid, price, collected)`, et `recordEarning`
pose `retained = min(gross, collected)`. Sur une course d'entreprise, cela
donne :

| | |
|---|---|
| `retainedFromCash` posé sur le conducteur | **650** |
| chiffre d'affaires de l'entreprise sur cette course | **0** |
| ce que le conducteur salarié a empoché en plus de sa paie | **650** |
| commission de 130 facturée à | **le conducteur** (`platformCommissionOwed(driverId)`) |

Un salarié empoche le chiffre d'affaires de son employeur, et Echango facture
l'employeur au conducteur. C'est le comportement **par défaut** du code une fois
la partie ajoutée, et il fallait l'écrire pour l'empêcher.

**La règle** : le conducteur retient la course **uniquement quand sa
rémunération est un montant que nous connaissons** — c'est-à-dire quand le
facilitateur est Echango, où la course vaut `meta.price`. Avec une entreprise
réelle, ce que le conducteur touche est un salaire interne : nous ne le
connaissons pas, il retient 0, et la course se règle entre l'entreprise et le
commerçant.

Ce n'est pas une branche de plus : c'est une seule expression, lue sur le
`isPlatform` du facilitateur (§7.4) —
`retenu = isPlatform ? min(price, perçu) : 0`.

### 7.3 Le couple de parties — **les deux bouts typés**

La première version ne typait qu'un seul bout et gardait `merchantId` en dur.
**C'était structurellement impossible**, et la revue l'a démontré :
`CashRemittance.merchantId` est **obligatoire avec clé étrangère** vers
`MerchantAccount` — une remise conducteur → entreprise n'a aucun commerçant à y
mettre, **elle n'a pas de forme de ligne**. Le lot « remise interne » n'aurait
pas été mécanique, il aurait été impossible.

`specs_flux_argent_quatre_acteurs.md` §4.1 disait bien « un couple de parties,
**chacune** typée » ; la première version avait rétréci la recommandation sans
s'en apercevoir.

**Forme retenue** — sur `CashCollection`, `CashRemittance`, `DriverEarning` :

```
fromType / fromId     // qui doit      ('driver' | 'fleet')
toType   / toId       // à qui         ('fleet'  | 'merchant')
```

`driverId` reste : c'est un **fait** — qui a physiquement encaissé — et non la
relation financière. `merchantId` devient **nullable** sur `CashRemittance`.

**Une seule ligne d'encaissement par commande, deux lectures.** `CashCollection`
reste le fait (qui a perçu, combien, sur la commande de qui) ; les deux dettes en
sont deux lectures, ce qui préserve « aucun solde n'est stocké » :

```
dette(conducteur → facilitateur) = Σ perçu − Σ retenu + Σ commission
                                 = 1950 − 650 + 130 = 1430   (Echango, isPlatform)
                                 = 1950 −   0 +   0 = 1950   (entreprise réelle)

dette(facilitateur → commerçant) = Σ perçu − Σ rémunérations
                                 = 1950 − 650       = 1300   (dans les deux cas)
```

La commission n'apparaît que sur le premier maillon et seulement chez Echango :
c'est la compensation du §7.1. Chez une entreprise réelle, elle est due par
l'entreprise et se règle sur le second maillon, pas par son conducteur.

**Additif, jamais un renommage.** `backend/bff/.gitignore` ignore
`prisma/migrations/` et `prisma:migrate` vaut `prisma migrate dev` : les
migrations sont régénérées depuis le schéma chez l'utilisateur, aucun fichier
écrit à la main ne peut être livré, et un renommage y serait vu comme un `DROP`
suivi d'un `ADD` **sur les trois tables qui portent de l'argent**.

**Quatre propriétés à tenir :**

1. **La partie est figée à l'écriture, jamais recalculée** — exception §3.3
   d'`architecture_bff_fleetbase.md`, la même que `expectedAmount`. Si un admin
   change `facilitator_uuid` demain, la dette d'hier ne bouge pas.
2. **Colonnes nullables plus reprise de données**, une colonne obligatoire sur
   une table non vide faisant échouer la migration. ⚠️ **Le repli ne doit pas
   confondre deux populations** : un `fromId` nul sur une ligne **antérieure** à
   la migration vaut `driverId` (fait historique correct) ; sur une ligne
   **postérieure**, c'est un bug du chemin d'écriture, et l'y résoudre en silence
   attribuerait la dette d'une entreprise à un conducteur personnellement. Le
   repli est borné par date de migration, et tout cas postérieur est journalisé
   en `error`. C'est la leçon du §30.4 appliquée correctement : la clause y
   portait sur le **déclarant**, pas sur un coalesce générique.
3. **`debtBetween` reste le seul endroit où une dette se calcule** — deux façons
   de calculer la même dette finissent par en donner deux valeurs.
4. **L'autorisation se lit sur la partie, jamais sur `driverId`** — voir §8.3,
   c'est un défaut de sécurité, pas un détail d'implémentation.

Trois énumérations et deux gardes d'appartenance doivent accepter un troisième
type : `CashRemittance.direction`, `declaredBy`, et le `persona` de
`loadRemittanceFor`. Dire que « rien ne change d'un iota » était vrai de
l'arithmétique et faux du reste.

### 7.4 Pas de drapeau de responsabilité — un seul prestataire marqué « plateforme »

La première version introduisait `FleetAccount.answersForItsDrivers` pour dire
qui répond. **La décision du §2.3 le rend inutile** : tout facilitateur répond de
ses conducteurs, Echango compris. Un drapeau qui vaut `true` partout n'est pas un
drapeau, c'est un commentaire — et il aurait fini par être lu comme une
permission de mettre `false`.

Ce qui reste à distinguer n'est pas la responsabilité mais **l'information** :

```
FleetAccount { isPlatform: bool }   // Echango lui-même — exactement un enregistrement
```

`isPlatform` ne décide **que** de ce que le conducteur retient (§7.2) :

- `true` (Echango) — la rémunération du conducteur est `meta.price`, montant qui
  nous appartient. Il la retient, et remet la différence augmentée de la
  commission.
- `false` (entreprise réelle) — la rémunération est interne à l'entreprise. Il
  retient 0 et remet tout.

**Ce champ relève de la catégorie primaire** — une donnée métier qu'aucun champ
Fleetbase ne porte, comme douze de nos quinze modèles — **et non d'une des trois
exceptions nommées**. Ne pas chercher à le faire entrer dans l'exception §3.3.

Il est **posé par un admin Echango uniquement**, jamais par un compte flotte ni
par une route du BFF, et son changement est journalisé (`AuditLog`). Un compte
flotte qui pourrait se déclarer plateforme ferait retenir à ses conducteurs une
rémunération qui ne leur revient pas.

**L'enregistrement Echango doit exister avant tout le reste** — c'est le lot 0.
Sans lui, une course du pool n'a pas de facilitateur, et toute la règle « le
facilitateur doit au commerçant » n'a personne à désigner. C'est l'étape que
`specs_flux_argent_quatre_acteurs.md` §7 appelait « poser le prestataire
Echango », et que la première version de ce document avait perdue en route.

### 7.5 Le facilitateur répond de ses conducteurs — et de quoi exactement

Si un conducteur disparaît avec les espèces, **le solde que voit le commerçant ne
bouge pas**. La perte bascule sur la chaîne interne — chez une entreprise, sur
son contrat de travail ; chez Echango, sur le contrat passé avec l'indépendant
(§2.3). C'est ce contrat qui rend la position tenable, et il est donc un
**prérequis d'exploitation**, pas une formalité à régulariser après coup : sans
lui, Echango doit au commerçant sans recours contre le conducteur.

⚠️ **Le modèle substitue le débiteur (qui doit), il ne garantit pas le montant
(combien).** Sur un écart à la porte — client n'ayant que 1500 sur 1950 — la
formule donne 1500 − 650 = 850 dus au commerçant, avec ou sans facilitateur :
**personne n'absorbe la différence**. Qui supporte la perte reste une règle non
tranchée (`specs_paiement_livraison.md` §9.2), et ce document ne la tranche pas
par sous-entendu. À ne pas confondre avec la garantie du §2.3, qui porte sur la
**défaillance du conducteur**, pas sur la **défaillance du destinataire**.

### 7.6 Le plafond de dette change de bénéficiaire

C'est la conséquence la plus saine de la décision du §2.3, et elle mérite d'être
dite dans ce sens-là : **le plafond ne protège plus le commerçant d'un
conducteur, il protège le facilitateur.** Sur une course du pool, c'est donc
Echango qui borne sa propre exposition — ce qui est exactement le rôle d'un
plafond, et non plus un service rendu à un tiers.

Deux plafonds distincts en découlent, et il faut les nommer séparément :

- **conducteur → facilitateur**, le seul instrument dont nous disposions sans
  dépôt physique : cesser de confier des espèces à qui en doit déjà trop.
- **facilitateur → commerçant**, qui borne ce qu'un commerçant confie à une
  entreprise donnée. Sans objet quand le facilitateur est Echango : le
  commerçant n'a pas à se protéger de nous, c'est nous qui garantissons.

⚠️ **La valeur doit être recalibrée**, et la première version le taisait :
`COD_DEBT_CEILING` vaut 20 000 par défaut. Une entreprise de dix conducteurs
partagerait **un seul** plafond de 20 000 sur le second, soit **quinze courses de
référence** pour toute la société — bloquée après une journée et demie. Les deux
plafonds n'ont aucune raison d'avoir la même valeur.

Et ce n'est pas « mécaniquement résolu » : `canTakeCashOrder` prend aujourd'hui
un `DriverAccount.id` chez ses deux appelants. Il y a **quatre points
d'application** à écrire, voir défaut **D8**.

### 7.7 Les écrans de caisse font partie du même lot

Le jour où la contrepartie bascule sur le facilitateur — c'est-à-dire dès la
première course, puisque Echango en est un (§2.2) :

- **le conducteur** voit sa caisse à 0 alors qu'il a 1950 en poche, tant que la
  chaîne interne n'existe pas ;
- **l'entreprise** n'a aucun écran — le persona flotte affiche « Espace non
  disponible » (`FlottePlaceholderScreen`) ;
- **Echango** n'a ni écran ni compte, donc personne ne peut confirmer la remise
  qu'un conducteur lui fait (D21).

L'argent serait invisible des trois côtés. **La lecture du registre par les trois
parties, le persona opérateur, et la chaîne interne conducteur → facilitateur
appartiennent donc au même lot que la généralisation**, pas à un lot ultérieur.
`CashScreen(persona:)` en sert déjà deux ; c'est le troisième qui manque, et
c'est celui sans lequel aucune dette de conducteur ne s'éteint.

⚠️ La **régularisation par le commerçant** (journal §30) n'a pas d'équivalent
facilitateur : `resolveDriverForRegularisation` ne sait résoudre qu'un
`DriverAccount`. Une course close en console et facilitée par une entreprise ne
pourrait être régularisée contre personne — la généralisation creuserait un trou
là où le §30 venait d'en boucher un.

### 7.8 Le cycle effectif s'allonge

`specs_paiement_livraison.md` vend la Voie B sur « le cycle le plus court du
marché — la remise a lieu au prochain enlèvement ». Avec une entreprise il y a
**deux remises au lieu d'une**, chacune avec sa confirmation. Ce n'est pas un
défaut, c'est un arbitrage — interlocuteur solvable et identifié contre délai —
mais non énoncé, il serait découvert par un commerçant.

## 8. Le conducteur

### 8.1 Ce qui ne change pas — hypothèse, pas certitude

Une course affectée par son entreprise arrive dans sa liste par
`GET /orders?driver=<uuid>`, comme une course acceptée au pool. Transitions,
preuve photo, signalement d'échec, présence, position : identiques.

⚠️ **Un point n'est pas couvert, et la première version l'affirmait sans le
savoir.** Une course prise au pool est assignée **et démarrée** d'un seul geste ;
une course affectée par une entreprise est **seulement assignée**. Le conducteur
doit donc emprunter `demarrer` sur une commande **pré-assignée** — que CLAUDE.md
liste explicitement comme *non couvert*. Contrôle **C4**, dix minutes, à passer
avant le lot des écrans.

### 8.2 Ce qui change

- **Sa contrepartie de caisse devient son facilitateur.** Même écran, même
  mécanisme de confirmation à deux, autre nom en face.
- **Il n'accepte pas** une course que son entreprise lui a affectée. Reste à
  trancher s'il peut la **refuser** (§11.3).

### 8.3 Le provisionnement — en place, avec un trou

La chaîne existe : l'entreprise crée le `Driver` (`POST /flotte/drivers`), émet
une invitation (`POST /auth/transporteur/invitation`, déjà `@Persona('fleet')`),
le conducteur crée son compte avec le jeton.

⚠️ **Le garde de persona dit qui a le droit d'émettre, jamais pour quel
conducteur.** `createDriverInvitation` ne lit même pas `req.user` et ne vérifie
que l'absence de compte existant — jamais que `Driver.vendor_uuid` est celui de
la flotte appelante. Voir défaut **D9**.

⚠️ `addDriver()` fait **deux écritures Fleetbase sans compensation** : si le
rattachement échoue après la création, un `Driver` orphelin reste dans la
compagnie, invisible de toutes les flottes. Règle 2. Voir défaut **D10**.

## 9. Défauts du code existant, révélés par ce cadrage

Vérifiés le 31/07/2026, fichier et ligne à l'appui. Numérotés pour être cités
par les lots du §13.

### Accès et identité

- **D1 — L'inscription flotte est libre, et chaque entreprise naît validée.**
  `POST /auth/flotte/register` est `@Public()`, `registerFleet()` appelle
  `createVendor()` **sans statut** (le modèle amont applique `$status ??
  'active'`), et **renvoie un JWT immédiatement**. `loginFleet()` ne lit que
  `fleet.active`, booléen local à `@default(true)` — **jamais `Vendor.status`**.
  Ce sont les deux trous exacts que le Lot 4 a fermés côté commerçant, restés
  ouverts côté flotte. N'importe qui s'inscrit comme entreprise de transport et
  entre. **C'est le défaut le plus grave de la liste**, et tout ce que ce
  document ajoute au persona serait offert à un inconnu.
  ⚠️ La première version écrivait que le garde du Lot 4 « s'applique tel quel ».
  Le mécanisme est réutilisable ; **il n'est pas branché**. C'est le genre de
  phrase qui fait qu'on ne vérifie jamais.
- **D2 — `FleetAccount.active` est un état parallèle à `Vendor.status`.**
  Règle 1. À trancher en même temps que D1.
- **D9 — Une flotte peut inviter n'importe quel conducteur du réseau.**
  `createDriverInvitation` ne contrôle pas l'appartenance ; les
  `fleetbaseDriverUuid` sortent dans `ORDER_LINK_FIELDS`. Combiné à D1 : un
  compte auto-créé invite un conducteur non encore inscrit, crée son compte à sa
  place, et obtient ses courses, ses preuves et son registre. Le correctif C2 du
  28/07 avait fermé « uuid lu sur une commande » ; D1 le rouvre.
- **D12 — `getVendorByUuid()` se désarme quand le réseau grandit.**
  `GET /vendors/{uuid}` ignore son paramètre de chemin et rend la collection ; la
  parade cherche l'uuid **sur une seule page, sans `limit`**. Au-delà, elle rend
  `null` — et §26.6 a décidé qu'un `Vendor` introuvable **laisse passer**. Le
  garde sur lequel repose toute la validation s'éteint silencieusement.

### Le chemin de la course

- **D3 — Aucune course ne peut atteindre une entreprise.** Le commerçant ne pose
  jamais `facilitator_uuid` (seule occurrence : un commentaire). Le module flotte
  ne voit que ce qu'un opérateur lui a rattaché à la main en console.
- **D4 — Une course confiée fuirait dans le pool de tous, à quatre endroits plus
  un.** Le prédicat `adhoc === true && !driver_assigned_uuid && status !==
  'canceled'` est **redérivé quatre fois** — liste (`listOrders`), fiche
  (`getOrder`, `claimableAdhoc`), refus (`declineOrder`), et **acceptation**
  (`acceptOrder`) — et aucun ne teste le facilitateur. C'est la leçon du 28/07
  (liste **et** fiche) reproduite à l'identique : corriger la liste seule laisse
  la fiche et **la prise** ouvertes à qui connaît l'uuid, que la liste donnait la
  veille. Le cinquième site n'est pas chez nous : c'est le **re-broadcast natif**
  du §6.2(c).
  ⚠️ Ce n'est pas un accident : le dispatch exige un conducteur assigné **ou**
  `adhoc` posé, donc une course confiée et non affectée **doit** porter
  `adhoc: true` pour être dispatchée. La correction ne peut pas être un filtre.
- **D18 — Les brouillons seraient visibles de l'entreprise** si le facilitateur
  est posé à la création (§6.1).
- **D17 — `demarrer` sur commande pré-assignée n'est pas couvert** (§8.1).

### Ce que l'entreprise voit

- **D6 — L'entreprise ne voit ni le prix ni le montant à encaisser.** Depuis la
  migration du 30/07, ces valeurs vivent dans `custom_field_values`. Les modules
  transporteur et commerçant hydratent (`withSpecMeta()`) ; **le module flotte,
  jamais** — `projectOrderForFleet` sert `meta` brut. La donnée est pourtant déjà
  dans la réponse. On demanderait à une entreprise de décider de prendre une
  course, puis de répondre des espèces, **sans lui montrer aucun des deux
  montants**.
- **D7 — `projectOrderForFleet` n'a aucun mode expurgé.** Il fait
  `projectPlace(dropoff, 'full')` sans condition — rue, étage, contact,
  téléphone. Le côté transporteur, lui, réduit une course non réclamée à sa
  commune. Ouvrir le détail aux entreprises pour la porte 2 (§6.2) livrerait
  **l'adresse exacte et le téléphone du destinataire de toute course en attente
  de tout commerçant** à tout compte flotte — auto-créé, cf. D1.
  **Règle proposée : le niveau de détail suit l'engagement, pas le persona.**
  Tant que la course n'est engagée par personne, tout lecteur voit la version
  expurgée — enlèvement complet (c'est un commerce), livraison réduite à sa
  commune, `price` et `cod_amount` conservés (ce sont eux qui permettent de
  décider), notes et instructions retirées. `facilitator_uuid` posé ⇒ l'entreprise
  passe en complet ; conducteur affecté ⇒ le conducteur aussi.

  > ⚠️ **Ce que ce paragraphe propose a été appliqué, puis corrigé par
  > l'usage (31/07/2026).** Mis à l'écran, il donnait une liste de huit courses
  > toutes titrées « Destinataire » — le libellé anonyme que la réduction à la
  > commune posait à la place du nom du lieu —, sans adresse, sans détour
  > estimable, et sans fiche à ouvrir. La question de l'utilisateur devant cet
  > écran est celle qui tranche : *« sur quels critères je dois accepter cette
  > course ou non ? »*
  >
  > **Décision produit : on protégeait la mauvaise chose.** L'adresse est le
  > critère de décision — elle dit le détour, le quartier, l'étage — et elle
  > n'identifie personne à elle seule. Ce qui identifie, ce sont **le nom et le
  > téléphone**. La règle devient donc : *tout est servi, sauf l'identité du
  > destinataire, jusqu'à l'engagement.*
  >
  > **Ce qui rend l'arbitrage tenable** n'est pas un pari : c'est le même fait
  > qui a levé la réservation aux favoris le 29/07 — transporteurs et
  > entreprises **ne s'inscrivent pas d'eux-mêmes**, ils sont invités
  > nominativement par Echango. Le contrôle a lieu à l'entrée du réseau, sur
  > l'identité réelle, et il est plus fort que ce qu'une expurgation par écran
  > peut offrir.
  >
  > **Risque résiduel nommé** : `instructions` et `dropoff_notes` sont du texte
  > libre, donc un commerçant peut y écrire « demander Karim, 0555… ». Le
  > masquage porte sur les champs structurés ; il ne peut rien contre une saisie
  > libre. Accepté, parce que « sonner au 3e, porte gauche » est justement
  > l'information sans laquelle un conducteur tourne dix minutes dans une cage
  > d'escalier — et que la retirer ne retirait pas le nom, elle retirait
  > l'utilité.
  >
  > ⚠️ **Le piège de la mise en œuvre, à retenir pour toute règle de
  > confidentialité future.** Retirer `name`, `phone`, `contact_name` et
  > `contact_phone` **ne suffit pas** : `Place.address` n'est pas une colonne
  > mais un **accesseur** qui recompose « nom, rue, commune, code postal ». Il
  > contient le nom. Et sur le chemin de création de l'application,
  > `createPlace()` ne pose jamais `street1` — l'adresse tapée part dans
  > `meta.dropoff_notes` —, donc le lieu de livraison n'a **que** son nom et
  > `address` *est* le nom du destinataire, sans rien d'autre.
  >
  > L'adresse servie sur une course non réclamée est donc **recomposée à partir
  > des seules colonnes structurées** (`street1`, `street2`, `neighborhood`,
  > `city`, `postal_code`, `province`). Vides, il ne reste rien — et c'est
  > correct : la porte est dans `location`, l'adresse dans les précisions.
  >
  > Le fait était écrit **trois fois dans le dépôt**, dont une observation réelle
  > (« un lieu portant `street1: "test1"` renvoie `address: "BOULANGERIE TEST"`,
  > le nom seul »). Il n'a pas été cherché parce que le champ portait le bon nom
  > — c'est la même erreur que `facilitator_uuid`, où un nom plausible a fait
  > conclure trop vite.
  >
  > ❓ **Question ouverte, à trancher — l'identité du COMMERÇANT n'est pas
  > protégée.** `payload.pickup` est servi en entier sur une course libre
  > (décision du 28/07 : « l'enlèvement est un commerce »), enseigne et
  > **téléphone du magasin** compris, avec un bouton pour composer le numéro
  > depuis la fiche. Le retrait de `customer_uuid` sur une course non réclamée
  > ne change rien à cela : il retire un identifiant exploitable, pas un nom.
  >
  > Les deux positions se défendent. **Garder** : le transporteur décide aussi
  > en fonction de qui l'attend — une pharmacie connue, un restaurant à l'heure
  > du coup de feu — et l'adresse d'enlèvement est de toute façon publique.
  > **Masquer le contact** (nom du magasin gardé, téléphone retiré jusqu'à
  > l'engagement) : avant de s'engager il n'y a rien à appeler, et le flux
  > d'opportunités devient sinon un annuaire de commerçants actifs avec leurs
  > numéros, rafraîchi en continu — c'est-à-dire la matière exacte d'un
  > contournement de la plateforme.
  >
  > Non tranché ici parce que ce n'est pas la question que la décision du 31/07
  > posait (elle portait sur le **client**), et qu'un masquage ajouté de ma seule
  > initiative irait à l'inverse de ce qui a été demandé. Le commentaire de
  > `projectOrderForDriver` a en revanche été corrigé : il affirmait une
  > protection que la ligne suivante défaisait.
- **D5 — `facilitator_uuid` est projeté au transporteur sur une course non
  réclamée.** `ORDER_LINK_FIELDS` sort même quand `unclaimed: true` — la branche
  d'expurgation ne touche que `meta` et `payload`. Chaque indépendant apprendrait
  en continu quelle entreprise a pris quelle course de quel commerçant. Sur une
  course non réclamée, `links` doit valoir `false`.
- **D19 — `projectOrderForMerchant` n'expose pas `ORDER_LINK_FIELDS`**, donc le
  commerçant ne peut pas afficher « confiée à X » (§5.2).

### L'argent

- **D8 — Le plafond de dette a cinq entrées et deux gardes.** `canTakeCashOrder`
  n'est appelé que par `assertCashCeiling` (depuis `acceptOrder`) et
  `pickAvailableFavourite`. Ne sont couverts ni **`flotte.assignDriver`**, ni
  **`startOrder`** sur une course pré-assignée (le contrôle a eu lieu à la
  création ; entre-temps le conducteur a pu encaisser dix courses), ni
  **l'affectation depuis la console**, ni la future prise au pool.
  **La garde ne se pose pas sur un chemin, elle se pose sur le fait** — ici : un
  conducteur devient porteur d'une course dont `cod_amount > 0`.
  ⚠️ Fenêtre restante : le plafond se vérifie à l'acceptation, la ligne naît à la
  clôture. Entre les deux, un opérateur peut poser `facilitator_uuid` en console
  et la dette s'écrit sur une partie qui n'a jamais été contrôlée.
- **D13 — Un conducteur peut confirmer les remises de son employeur.**
  `loadRemittanceFor`, `confirmCollection` et `disputeCollection` filtrent sur
  `driverId`, et `confirmRemittance` n'interdit que l'auto-confirmation par
  comparaison de **types**. Une remise entreprise → commerçant porte `driverId`
  (le conducteur qui a encaissé) : il ouvre son app, confirme, et **la dette de
  son entreprise s'éteint sans que le commerçant ait rien vu**. C'est le principe
  fondateur du registre retourné contre lui.
- **D14 — `onDelete: Cascade` sur `driverId` effacerait la dette de
  l'entreprise**, précisément dans le scénario que le §7.5 met en avant. Latent
  (aucun chemin de suppression n'existe), mais armé.
- **D15 — Le nom de la contrepartie est lu dans une table en dur.**
  `merchantBalances` interroge `driverAccount` : une partie de type flotte
  donnerait `driver_name: null` **sans erreur** — un montant dû par personne,
  sans moyen d'appeler qui que ce soit pour organiser la remise.

### Divers

- **D10 — `addDriver()` : deux écritures Fleetbase sans compensation** (§8.3).
- **D11 — `getAllDrivers({vendor})` n'est pas paginé.** Au-delà de la page par
  défaut, des conducteurs d'une flotte disparaissent sans erreur — la famille de
  défaut des §21.5/§22.
- **D16 — La régularisation commerçant n'a pas d'équivalent entreprise** (§7.7).
- **D21 — Echango devient une partie du registre et n'a aucun compte.** Décidé
  au §2.3 : le conducteur du pool doit à Echango. Or `CashRemittance` se confirme
  **par l'autre partie**, et cette autre partie n'a ni compte, ni écran, ni
  route. Une remise faite à Echango ne serait **jamais confirmable**, donc la
  dette du conducteur ne s'éteindrait jamais et le registre grossirait sans fin —
  une panne silencieuse, qui ne se manifesterait que par des soldes qui ne
  baissent pas. Il faut un **persona opérateur** : lire le registre, confirmer
  les remises reçues des conducteurs, déclarer celles faites aux commerçants.
  Quatrième profil applicatif, à traiter dans le même lot que la généralisation.
- **D20 — Le profil flotte n'a aucune interface.** Six routes BFF, dont cinq
  validées par test réel avec deux flottes distinctes ; `GET /flotte/drivers/
  positions` n'a jamais été éprouvée de bout en bout (la compagnie de test n'a
  jamais eu de position réelle). Côté app : « Espace non disponible ».

## 10. Sécurité — ce qui protège déjà, et ce qu'il faut y ajouter

Deux principes en vigueur, rappelés parce que ce chantier les met à l'épreuve :

- **Le filtre serveur allège, il n'autorise pas.** Fleetbase abandonne en silence
  un paramètre qu'il ne reconnaît pas : une régression de nom doit produire une
  liste **vide**, jamais une fuite. Les vérifications d'appartenance en mémoire
  restent, toutes.
- **Anti-IDOR sur tout accès unitaire**, déjà vérifié entre deux flottes.

Trois surfaces neuves : la prise au pool (§6.2, compare-and-set + `adhoc:false`),
l'affectation d'un conducteur (vérifier que le conducteur **et** la course
appartiennent à l'entreprise — `flotte.assignDriver` le fait, ne pas le perdre),
et le registre côté entreprise (D13).

## 11. Questions ouvertes — décisions produit

1. **Le conducteur d'entreprise voit-il le pool ?** Peut-il prendre une course en
   son nom propre ? *Recommandation : **la course décide** — facilitateur réel
   ⇒ l'entreprise règle, facilitateur Echango ⇒ le conducteur. Aucune table
   d'appartenance côté BFF.*
   ⚠️ `Driver.vendor_uuid` est un scalaire, mais rien n'établit que ce soit le
   **seul** rattachement : `DriverFilter::vendor()` délègue à `facilitator()`, ce
   qui suggère un lien lui-même polymorphe. L'argument « Fleetbase ne sait porter
   qu'une appartenance » est plus fragile qu'il n'y paraît.
2. **Les conducteurs se servent-ils, ou l'entreprise affecte-t-elle ?** Une course
   confiée et non affectée peut être proposée aux conducteurs maison comme une
   opportunité restreinte, ou attendre un dispatcher. Décide de l'écran principal
   du profil.
3. **Un refus par un conducteur d'entreprise retombe-t-il chez son entreprise ou
   au pool ?** *Recommandation : chez l'entreprise* — sans quoi une société
   perdrait une course qu'elle a acceptée.
4. **Plafond interne conducteur → entreprise ?** *Ne bloque rien.*
5. **Rythme de compensation de la commission.** Le **débiteur** est décidé —
   poser la partie sur `DriverEarning` fait du facilitateur le débiteur — et son
   **recouvrement** cesse d'être ouvert dès lors qu'il se compense sur la remise
   (§7.1). Reste le rythme : à chaque remise, ou périodiquement. *Ne bloque
   rien.*
6. **La vérification juridique** sur l'obligation de paiement assumée par
   Echango (§2.3) — **bloquante avant le pilote**, et par le droit plus que par
   le code.
7. **Le contrat type avec les conducteurs indépendants** (§2.3, §7.5) : c'est ce
   qui rend la garantie tenable, donc un prérequis d'exploitation. Hors du
   périmètre logiciel, dans le chemin critique.

## 12. Contrôles à passer — chacun débloque un lot

Aucun ne prend plus de trente minutes, et chacun remplace une hypothèse.

- **C1 — `facilitator_type` : ✅ PASSÉ le 31/07/2026**
  (`scripts/verify-facilitator.sh`). Résultat, et il corrige ce document :
  **Fleetbase stocke `fleet-ops:vendor`**, son alias de morphologie polymorphe,
  et non `vendor`. La valeur `vendor` est acceptée puis normalisée — la relation
  `with[]=facilitator` résout le bon Vendor, et `?facilitator=` rend la commande
  avec un **témoin à 0** — mais le code écrit désormais la forme canonique
  plutôt que de dépendre d'une normalisation observée une seule fois.
  ⚠️ Asymétrie relevée au passage : nous envoyons `customer_type: 'vendor'` et
  le journal §2.10 l'a relu tel quel. Les deux colonnes ne sont donc peut-être
  pas traitées à l'identique — raison de plus pour ne jamais raisonner de l'une
  vers l'autre, ce que la première version de ce document faisait.
- **C2 — `GET /drivers?vendor=`** avec témoin, à ajouter à
  `scripts/verify-fleetbase-filters.sh`, qui n'en teste que quatre.
- **C3 — Écriture concurrente de `facilitator_uuid`.** Deux `PUT` rapprochés,
  puis relecture : qui gagne, et le perdant reçoit-il quoi que ce soit ?
  Observer au passage si la relecture est servie par le cache Redis.
- **C4 — `demarrer` sur commande pré-assignée.** Affecter depuis le compte
  flotte, démarrer depuis l'app conducteur (§8.1).
- **C5 — Re-broadcast adhoc.** Poser `facilitator_uuid` sur une course diffusée
  et observer si les `OrderPing` continuent (§6.2(c)). Confirme que
  `adhoc: false` est bien la parade.
- **C6 — `Fleet` porte-t-il un statut ?** Trente secondes en console (§4).

## 13. Ordre de mise en œuvre

**Lot 0 — refermer l'accès, et poser Echango.** D1 (validation flotte :
`assertFleetApproved` sur `loginFleet`, `Vendor` créé `inactive`, inscription
sans jeton), D2, D9, D12, **et l'enregistrement du prestataire Echango**
(`isPlatform`, §7.4) sans lequel rien de ce qui suit n'a de facilitateur à
désigner. *Rien de ce document ne doit être livré avant.* Contrôles : aucun.

**Lot 1 — la fondation du registre.** Couple de parties aux deux bouts (§7.3),
reprise de données bornée par date, autorisation lue sur la partie (D13), D14,
D15, retenue selon `isPlatform` (§7.2), les deux plafonds sur les quatre chemins
(D8), **les écrans de caisse des trois parties et la chaîne interne** (§7.7),
D16, **et le persona opérateur Echango** (D21) — sans lui aucune remise faite à
Echango ne peut être confirmée.
*Prouvé par* : `test-parcours-argent.sh`, dont seul le §5 change de forme (§14).

**Lot 2 — fermer la fuite, avant toute porte.** D4 sur les quatre sites par un
**prédicat unique et partagé**, D5, D6, D7. Contrôle : C5.

**Lot 3 — la prise d'une course au pool** (§6.2) : compare-and-set, `adhoc:
false` dans le même geste, refus du perdant. Contrôles : C1, C3.

**Lot 4 — les écrans du profil flotte** (D20), D17, D11.
⚠️ Ne pas livrer le Lot 3 sans au moins le bouton « prendre cette course » du Lot
4, ou dire explicitement que le Lot 3 est validé par script en attendant :
« le serveur savait, l'app ignorait » est un fil rouge déjà rencontré deux fois.
Règle 4 applicable : FR + AR, codes traduits, `tool/check_error_codes.dart`.

**Lot 5 — le commerçant choisit une entreprise** (§6.1) : favoris polymorphes,
recherche rendant les deux types, D18, D19. Rouvre le profil commerçant,
délibérément en dernier. Règle 4 applicable.

**Codes d'erreur nouveaux à déclarer** (règle 3 — un code absent du registre est
un refus de compiler, mais seulement si quelqu'un pense à l'ajouter) : refus de
connexion d'une entreprise non validée (Lot 0), refus du perdant d'une prise
concurrente si le cas diffère de `order.already_taken` (Lot 3), et refus de
confirmer une remise par une partie qui n'est pas la contrepartie (D13, Lot 1).

## 14. Contrat constant — ce qui ne doit pas bouger

`scripts/test-parcours-argent.sh` reste le contrôle de référence, et la règle ne
change pas : **il ne doit pas être modifié pour accommoder le code.** S'il casse
là où rien ne devait bouger, c'est le code qui a changé de comportement.

Ce qu'il fige, et qui doit rester vrai au mot près : marchandise + course =
montant réclamé à la porte ; retenue de la rémunération ; **dette inchangée tant
que la remise n'est pas confirmée** ; les deux chemins de clôture écrivant tous
deux au registre.

⚠️ **Une seule partie du script change de forme, et c'est une conséquence assumée
de la décision du §2.3, pas une régression : son §5.** Le conducteur y déclare
une remise **au commerçant**, que le commerçant confirme. Sa contrepartie devient
Echango, et c'est l'opérateur qui confirme. Trois exigences pour que ce
remplacement ne dégrade pas la preuve :

1. **Remplacer, jamais supprimer.** Le contrôle qui compte — la dette
   **inchangée** entre la déclaration et la confirmation — doit être rejoué
   à l'identique sur la nouvelle paire conducteur ↔ Echango. C'est le principe
   fondateur du registre ; le perdre en le déplaçant serait le pire résultat
   possible.
2. **Ajouter le second maillon** : Echango → commerçant, déclaré par l'opérateur
   et confirmé par le commerçant. Le §5 actuel devient deux §5, et c'est ce qui
   prouvera que la chaîne à deux maillons fonctionne réellement.
3. **Écrire la version nouvelle avant de toucher au code**, et vérifier qu'elle
   échoue sur le code actuel. Un contrôle écrit après coup décrit ce qu'on a
   fait, pas ce qu'on voulait.

Le reste du script — §1 à §4 et §6 — ne doit pas bouger d'une ligne.

**Les noms sont gelés autant que les comportements**, et la première version ne
le disait pas : les corps `{merchantId, amount}` et `{driverId, amount}` des deux
routes de remise, `balances[].debt`, `details[].retained_amount`,
`details[].net_amount`. Toute forme nouvelle est **acceptée en plus**, jamais à
la place. Seul `balances[].counterparty_id` est déjà anticipé par le script.

⚠️ **Et ce contrat prouve la non-régression, jamais la correction.** Le script
joue un indépendant sur une course sans facilitateur : il restera vert quelle que
soit l'issue de D4, D8 ou D13. Les Lots 2 et 3 doivent apporter leurs propres
contrôles — une course confiée **invisible et imprenable** par un indépendant,
et une prise concurrente dont un seul écrivain ressort gagnant.

---

## Sources internes

- `docs/specs_flux_argent_quatre_acteurs.md` — l'argent à quatre acteurs
- `docs/specs_paiement_livraison.md` — Voie B, plafond, §9 non tranché
- `docs/architecture_bff_fleetbase.md` — Fleetbase fait foi, les trois exceptions, §10 méthode
- `docs/specs_echango_delivery.md` §3.1, §3.2 — le format de `customer_type`, le dispatch adhoc et sa relance
- `docs/specs_app_transporteur.md` §2.1 — provisionnement des conducteurs
- `docs/journal_implementation_bff.md` §2.8 à §2.13, §16, §21, §23, §26, §29, §30
- `backend/bff/src/flotte/`, `src/cash/`, `src/transporteur/`, `src/common/projections/`
