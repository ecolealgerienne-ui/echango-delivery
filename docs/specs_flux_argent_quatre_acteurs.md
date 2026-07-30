# Les flux d'argent à quatre acteurs

*Rédigé le 30/07/2026. **Rien n'est implémenté.** Les trois questions qui
décidaient du modèle ont été tranchées le même jour (§6) ; le code peut donc
être écrit, dans l'ordre du §7.*

---

## 1. Les acteurs, et ce que chacun tient

| Acteur | Utilise | Tient de l'argent ? | Doit de l'argent ? |
|---|---|---|---|
| **Destinataire** | rien | non — il paie | non |
| **Transporteur** (driver) | app Echango | **oui**, les espèces à la porte | oui, à qui il doit remettre |
| **Commerçant** | app Echango | non | oui, la course |
| **Entreprise de transport** | app Echango (profil flotte) | non — son conducteur tient | **oui**, et elle répond de ses conducteurs (§6.3) |
| **Echango** | console Fleetbase | **jamais** (décision fondatrice, Voie B) | non |

L'entreprise de transport était le seul acteur dont les deux dernières colonnes
étaient vides. **C'est tout le sujet de ce document** — et depuis les décisions
du §6, elles sont remplies : elle ne tient jamais les espèces, mais c'est elle
qui doit.

## 2. Ce qui existe aujourd'hui : trois acteurs, deux parties

Le registre de caisse est construit sur une relation **binaire** :

```
CashCollection   ( driverId, merchantId, expectedAmount, collectedAmount )
DriverEarning    ( driverId, merchantId, grossAmount, commissionAmount, retainedFromCash )
CashRemittance   ( driverId, merchantId, amount, direction, confirmedAt )

debtBetween(driverId, merchantId)
```

Le flux :

```
Destinataire ──[espèces, livraison comprise]──▶ Transporteur
                                                   │
                                    retient sa rémunération
                                                   │
                                                   ▼
                                    remet la différence ──▶ Commerçant
                                                   │
                                    doit une commission ──▶ Echango  (non recouvrée)
```

Trois propriétés le tiennent, et il faut les nommer parce que **toute
extension doit les préserver** :

1. **Aucun solde n'est stocké** — la dette est une différence recalculée. Un
   compteur dériverait au premier échec partiel.
2. **Une remise ne compte qu'après confirmation de l'autre partie.** Déclarée
   d'un seul côté, elle n'est qu'une affirmation.
3. **Echango ne touche jamais l'argent.** C'est ce qui évite la question du
   statut de détenteur de fonds pour compte de tiers.

## 3. Ce qui casse dès qu'une entreprise de transport entre

### 3.1 Le trou structurel : elle ne reçoit aucune commande

Le commerçant ne pose **jamais** `facilitator_uuid` à la création — vérifié :
la seule occurrence dans `commercant.service.ts` est un commentaire historique.
Le module flotte lit `?facilitator=<son vendor>`, donc il ne voit que ce qu'un
opérateur lui a rattaché **à la main dans la console**.

Il n'existe donc aucun chemin produit entre « le commerçant commande » et
« l'entreprise X reçoit ». C'est le premier manque, et il précède toute
question d'argent : sans lui, l'entreprise n'a rien à encaisser.

### 3.2 Le registre n'a pas de place pour elle

`CashCollection(driverId, merchantId)` dit *un transporteur doit à un
commerçant*. Si le commerçant a contracté avec **l'entreprise**, cette ligne
décrit la mauvaise dette :

- le commerçant réclamerait à un transporteur qu'il n'a pas choisi ;
- l'entreprise, qui répond de ses conducteurs, n'apparaît nulle part ;
- et si le transporteur quitte l'entreprise avec les espèces, le commerçant
  n'a de recours contre personne dans nos données.

### 3.3 Le plafond de dette borne la mauvaise exposition

`COD_DEBT_CEILING` s'applique par couple transporteur↔commerçant. Une
entreprise de dix conducteurs peut donc accumuler **dix fois le plafond** chez
le même commerçant sans qu'aucune garde ne se déclenche — chaque conducteur
restant, individuellement, sous la limite.

C'est le défaut le plus coûteux des quatre : le seul garde-fou du paiement à
la livraison devient contournable par la structure même de l'acteur qu'on
ajoute.

### 3.4 La commission est assise sur un montant qu'on ne verra plus

`DriverEarning.commissionAmount` se calcule sur la rémunération du
**transporteur**. Avec une entreprise, ce que le conducteur touche est un
salaire ou une part interne — **une donnée qui ne nous regarde pas et que nous
n'aurons pas**. Le seul montant que nous connaissons est celui que le
commerçant paie pour la course.

## 4. Recommandations

### 4.1 La contrepartie financière est l'entreprise quand il y en a une

> **Qui encaisse n'est pas qui doit.** Le transporteur tient les espèces ; la
> dette est celle de l'entité avec laquelle le commerçant a contracté.

Concrètement : `facilitator` présent ⇒ la contrepartie du commerçant est
l'entreprise. Absent ⇒ c'est le transporteur, comme aujourd'hui — un
indépendant est sa propre entreprise, et ce cas ne doit pas devenir un cas
particulier.

Ce que ça implique dans le registre : les trois tables ne peuvent plus nommer
leurs colonnes `driverId`/`merchantId`. Il leur faut **un couple de parties**,
chacune typée (`driver` | `fleet` | `merchant`). Le calcul de dette, les
remises et leur confirmation ne changent pas d'un iota — seule l'identité des
deux bouts devient variable.

C'est une réécriture de schéma, pas une réécriture de logique. Et elle rend le
cas « indépendant » et le cas « entreprise » **identiques**, au lieu d'ajouter
une branche à chaque endroit qui touche à l'argent.

### 4.2 Deux chaînes de remise, pas une

Avec une entreprise, il y a **deux dettes distinctes**, et les confondre serait
l'erreur symétrique de celle qu'on a évitée entre `price` et `cod_amount` :

```
Destinataire ──espèces──▶ Transporteur ──remise──▶ Entreprise ──remise──▶ Commerçant
                              (interne)                        (contractuelle)
```

- **Transporteur → entreprise** : interne, et l'app la sert déjà — il suffit
  que la contrepartie affichée au conducteur soit son entreprise et non le
  commerçant.
- **Entreprise → commerçant** : c'est celle que le commerçant confirme.

Le mécanisme est le même des deux côtés (déclaration, confirmation par
l'autre, contestation). **Aucune primitive nouvelle n'est nécessaire** — c'est
ce qui rend la recommandation 4.1 payante.

### 4.3 Le plafond s'applique à la contrepartie, donc à l'entreprise

Mécaniquement résolu par 4.1 : si la dette est celle de l'entreprise,
`assertCashCeiling()` la borne à l'échelle de l'entreprise, tous conducteurs
confondus. C'est l'exposition réelle du commerçant.

Reste à trancher s'il faut **aussi** un plafond interne par conducteur
(§6bis.1) — ce qui ne bloque rien, l'entreprise disposant de moyens de
contrainte que nous n'avons pas.

### 4.4 La commission porte sur le prix de la course, pas sur la rémunération

`grossAmount` doit désigner **ce que le commerçant paie pour la livraison** —
un montant que nous fixons ou validons, donc que nous connaissons toujours.
Ce que l'entreprise reverse à son conducteur lui appartient.

Effet de bord favorable : le calcul devient identique pour un indépendant,
chez qui les deux montants coïncident.

### 4.5 Le destinataire : hors périmètre, et il faut le dire

**Décision du 30/07/2026 : le client final n'entre pas dans la plateforme
aujourd'hui.** Le point reste noté parce qu'il ne disparaît pas en étant
différé — il paie, et rien dans le système ne vient de lui. Sur un écart, la
parole du transporteur est la seule source, et la chaîne s'allonge encore à
quatre acteurs : commerçant → entreprise → transporteur → destinataire.

À rouvrir quand un litige réel se produira, pas avant.

## 5. Ce qu'il ne faut PAS faire

- **Ajouter une branche « si flotte » dans chaque fonction d'argent.** Le
  registre compte aujourd'hui une douzaine d'endroits qui nomment
  `driverId, merchantId` ; les dupliquer produirait deux modèles à garder
  synchronisés, c'est-à-dire le défaut que la règle 1 du projet interdit.
- **Faire transiter l'argent par Echango** pour simplifier la répartition. Ça
  rouvre la question du statut réglementaire, que la Voie B a été choisie pour
  éviter (`docs/specs_paiement_livraison.md` §6).
- **Stocker un solde par entreprise** pour éviter d'agréger. Même raison
  qu'aujourd'hui : une différence recalculée ne dérive pas.

## 6. Décisions prises le 30/07/2026

### 6.1 ✅ Le commerçant choisit une entreprise **ou** un transporteur du pool

Les deux, au même endroit et au même moment. Ce ne sont pas deux
fonctionnalités : c'est un seul choix, « à qui je confie cette course », dont
la réponse est tantôt une personne, tantôt une société.

**Ce que ça impose, et qui n'était pas prévu :**

- `DriverFavourite` ne suffit plus. Un commerçant doit pouvoir mettre une
  entreprise en favori comme il met un transporteur — donc la table doit porter
  un **type de partie**, exactement comme le registre de caisse (§4.1). Deux
  tables de favoris feraient deux écrans, deux recherches et deux logiques de
  repli pour un seul geste utilisateur.
- La recherche de l'écran « Mes transporteurs » doit rendre les deux, et dire
  lequel est lequel : on n'appelle pas une entreprise comme on appelle un
  conducteur.
- À la création, `pickAvailableFavourite()` doit pouvoir répondre une
  entreprise. Et dans ce cas **on ne pose pas `driver_assigned_uuid`** — on
  pose `facilitator_uuid` et on laisse l'entreprise désigner le sien. Confier
  la course à une société *et* nommer son conducteur serait décider à sa place.

### 6.2 ✅ Une entreprise peut prendre une course du pool et l'attribuer en interne

C'est ce qui lui donne un rôle sans obliger le commerçant à la choisir.

**Ce que ça impose :**

- Une action de **prise en charge** côté flotte, qui n'existe pas : aujourd'hui
  `flotte.service.ts` ne fait que *lire* `?facilitator=<son vendor>`, donc elle
  ne voit que ce qu'un opérateur lui a déjà rattaché. Il faut l'équivalent
  d'`acceptOrder()` du transporteur, qui pose `facilitator_uuid`.
- Une **course diffusée est donc visible par deux populations** — les
  transporteurs indépendants et les entreprises — qui peuvent la réclamer en
  même temps. Le premier arrivé l'emporte, et le second doit recevoir un refus
  explicite : `order.already_taken` existe déjà pour ce cas côté transporteur.
- Une fois prise, la course **disparaît du pool** pour tout le monde, y compris
  des transporteurs indépendants qui l'avaient sous les yeux.

### 6.3 ✅ L'entreprise répond de ses conducteurs

C'est la réponse qui rend le modèle du §4.1 tenable : **la dette envers le
commerçant est celle de l'entreprise**, et elle le reste si l'un de ses
conducteurs disparaît avec les espèces. Le commerçant a un interlocuteur
solvable et identifié ; l'entreprise assume le risque qu'elle est seule à
pouvoir maîtriser, puisqu'elle recrute et paie ses conducteurs.

**Conséquence directe** : la perte d'un conducteur ne change **rien** au solde
que le commerçant voit. Elle bascule en interne, sur la chaîne
conducteur → entreprise, où l'entreprise dispose de moyens que nous n'avons pas
— contrat, salaire, procédure.

### 6.4 ✅ Le destinataire reste hors plateforme

Voir §4.5.

## 6bis. Ce qui reste ouvert

1. **Plafond de dette interne, conducteur → entreprise ?** L'entreprise a des
   moyens de contrainte que nous n'avons pas. Le lui imposer par logiciel peut
   être un service autant qu'une gêne. *Ne bloque rien : le plafond envers le
   commerçant, lui, est tranché.*
2. **La commission d'Echango est-elle facturée à l'entreprise** en une fois ou
   course par course ? *Ne bloque rien : son recouvrement n'est de toute façon
   pas construit.*
3. **Un conducteur peut-il travailler pour deux entreprises**, ou en
   indépendant *et* pour une entreprise ? Si oui, sa dette n'est plus unique et
   l'écran « ce que vous détenez » doit la ventiler par contrepartie.
   *Celle-ci compte* : elle décide si le couple de parties du §4.1 suffit, ou
   s'il faut aussi une notion d'appartenance multiple.

## 7. Ordre de mise en œuvre

Les trois questions qui décidaient du modèle sont tranchées (§6.1, §6.2, §6.3).
Le code peut être écrit, dans cet ordre — chaque lot rendant le suivant
mécanique :

0. **Poser le drapeau `answersForItsDrivers`** sur les comptes flotte (§8.3),
   et créer le prestataire « Echango » avec ce drapeau à `false`. C'est ce qui
   permet aux lots suivants de ne connaître qu'un seul cas.
1. **Généraliser le couple de parties** (§4.1) dans les trois tables du
   registre **et dans les favoris** (§6.1). À contrat constant : le cas
   transporteur↔commerçant continue de fonctionner à l'identique, et le cas
   entreprise devient le *même* cas. C'est la fondation ; tout le reste en
   découle sans branche conditionnelle.
2. **Choisir une entreprise à la création** : favoris polymorphes, recherche
   qui rend les deux types, et `facilitator_uuid` posé sans
   `driver_assigned_uuid` (§6.1).
3. **Prise en charge d'une course du pool par une entreprise** (§6.2), avec le
   refus du second arrivant.
4. **Basculer la base de commission** sur le prix de la course (§4.4) — sans
   quoi une entreprise serait taxée sur un salaire que nous ne connaissons pas.
5. **Remise interne** conducteur → entreprise (§4.2). Sans code nouveau si 1
   est fait : c'est le même mécanisme, avec une autre contrepartie.

⚠️ **Le lot 1 touche des tables d'argent.** Les lignes existantes portent
toutes un couple transporteur↔commerçant : la reprise de données les recopie en
`debtorType = 'driver'`, sans changer un seul solde. Le vérifier avant de
migrer, pas après.

---

## Sources internes

- `docs/specs_paiement_livraison.md` — Voie B, plafond de dette, §9 non tranché
- `docs/architecture_bff_fleetbase.md` — Fleetbase fait foi, exceptions nommées
- `backend/bff/src/cash/cash.service.ts` — le registre actuel
- `backend/bff/src/flotte/flotte.service.ts` — `?facilitator=`, vérifié par appel réel

---

## 8. La proposition « Echango comme entité de transport » (30/07/2026)

*Proposition de l'utilisateur : ajouter l'entreprise de transport dans le
**flux** de la configuration de commande, et traiter les transporteurs Echango
comme une entité de transport parmi d'autres — pas de facilitateur ⇒ pool
Echango, facilitateur ⇒ ses conducteurs. Évaluée contre le source de `fleetops`.*

### 8.1 « Entités » n'est pas ce qu'on croit — vérifié

L'onglet **Entités** de la configuration de commande ne désigne pas des
organisations mais **les marchandises transportées**. `Entity::$fillable` porte
`weight`, `weight_unit`, `length`, `width`, `height`, `dimensions_unit`,
`barcode`, `qr_code`, `sku`, `price`, `destination_uuid`. Le composant console
`order-config-manager/entities.js` crée des `custom-entity` avec
`dimensions_unit: 'cm'` et `weight_unit: 'kg'`.

C'est le catalogue des **types de colis** d'une configuration. Y ranger une
entreprise de transport ferait porter au champ un second sens — précisément
l'erreur que `meta` nous a coûtée aujourd'hui.

### 8.2 Le logement natif existe déjà, et nous l'utilisons

`Order.$fillable` contient `facilitator_uuid` **et** `facilitator_type` : c'est
un rattachement polymorphe, prévu pour l'entité qui *réalise* la course, par
opposition à `customer` qui la *commande*. Le module flotte filtre déjà dessus
(`?facilitator=`, vérifié par appel réel : 2 commandes sur 29, 0 pour un uuid
inventé).

Il n'y a donc rien à ajouter à Fleetbase — seulement à s'en servir à la
création, ce que le commerçant ne fait jamais aujourd'hui (§3.1).

### 8.3 « Pas de facilitateur ⇒ Echango » : à retenir, avec une correction

**L'idée est juste, et elle vaut mieux que ma formulation initiale.** Je disais
« un indépendant est sa propre entreprise » ; la proposition va plus loin et
supprime le cas nul : il y a toujours un prestataire, Echango étant le
prestataire par défaut. Un seul chemin de choix, un seul chemin de dispatch,
une seule table de favoris.

**Mais la responsabilité ne doit PAS suivre cette uniformité.** Si Echango
devenait le facilitateur des courses du pool, alors la contrepartie du
commerçant serait Echango — donc :

- Echango devrait au commerçant les espèces qu'un conducteur détient, ce qui
  est **exactement la détention de fonds pour compte de tiers** que la Voie B a
  été choisie pour éviter (`specs_paiement_livraison.md` §6) ;
- Echango répondrait de la disparition d'un conducteur du pool, alors qu'il ne
  l'emploie pas — il l'a sélectionné, ce qui n'est pas la même chose (§6.3 ne
  vaut que pour une entreprise qui *emploie*).

**La différence entre le pool Echango et une entreprise n'est pas
structurelle, elle est contractuelle.** Il faut donc l'écrire comme telle :

```
FleetAccount { answersForItsDrivers: bool }

  pool Echango       → false → la contrepartie financière est le CONDUCTEUR
  entreprise réelle  → true  → la contrepartie financière est l'ENTREPRISE
```

On garde l'uniformité proposée là où elle est bonne — le choix, le dispatch,
les favoris — et on nomme la seule chose qui diffère au lieu de la cacher dans
une absence de ligne. Un drapeau qui dit « celle-ci se porte garante » est plus
honnête qu'un `null` dont il faut deviner le sens.

### 8.4 Ce que le flux peut réellement faire — et c'est plus que je ne pensais

`Activity` porte un attribut **`logic`** : une liste de `Logic`, chacune
portant des `Condition{field, operator, value}`. `Activity::getNext()` ne
propose que les activités dont **toutes** les logiques passent :

```php
foreach ($children as $childActivity) {
    if ($childActivity->passes($order)) $nextActivities->push($childActivity);
}
```

Et `Condition::eval()` résout son champ par `Order::resolveDynamicValue()`, qui
cherche dans cet ordre : **attribut de la commande** (donc `facilitator_uuid`),
puis **champ personnalisé**, puis **clé de `meta`**.

**Le flux peut donc se brancher sur `facilitator_uuid` — et sur nos treize
champs personnalisés.** Ce n'était pas acquis, et ça ouvre une possibilité
réelle.

### 8.5 Mais le flux n'est pas un moteur d'affectation

Il décide **quelles activités sont proposées ensuite**, pas **à qui la course
est confiée**. Aucune activité ne signifie « affecter aux conducteurs de
l'entreprise X » : le dispatch passe par `facilitator_uuid` et
`driver_assigned_uuid`, pas par le flux.

Utiliser le flux pour router serait détourner une machine à états en table de
routage — même famille d'erreur qu'au §8.1.

### 8.6 En revanche, le flux résout un vrai manque : l'état intermédiaire

Le flux actuel est `created → dispatched → started → enroute → completed`. Avec
une entreprise, il existe un état que rien ne nomme : **la course est confiée à
l'entreprise, qui n'a pas encore désigné son conducteur.**

C'est exactement le trou qu'on a rebouché à la main dans l'app aujourd'hui, en
dérivant « Transporteur affecté » de deux champs (`status` + `driver_assigned`)
parce que le statut reste `dispatched` après l'affectation. Une activité native
`assigned`, avec pour logique `facilitator_uuid` `exists`, ferait porter cet
état **par Fleetbase** au lieu de le faire déduire par chaque écran — ce qui
est la règle 1 du projet, dans le bon sens.

**Suggestion retenue** : ajouter une activité entre `dispatched` et `started`,
et supprimer la dérivation côté app.

### 8.7 ⚠️ Toucher au flux n'est pas anodin

`OrderConfig::getDispatchActivity()` fait
`$this->activities()->firstWhere('code', 'dispatched')`. **Une activité
renommée ou retirée rend tout dispatch muet** — pas en erreur, muet. C'est déjà
inscrit comme piste dans CLAUDE.md. Toute modification du flux doit donc être
faite en connaissance de cause, et vérifiée par une vraie publication.

Deux précautions supplémentaires, lues dans `Condition::eval()` :

- il fait `strtolower($order->resolveDynamicValue($field))`. Comparer un uuid
  fonctionne, mais **une condition d'égalité sur un uuid d'entreprise fige la
  configuration sur cette entreprise**. Les conditions doivent tester
  l'**existence** (`facilitator_uuid` / `exists`), jamais l'égalité avec un
  acteur nommé ;
- `strtolower()` sur une valeur non textuelle (un tableau, `items`) est au
  mieux inutile, au pire une erreur PHP 8. Ne brancher que sur des scalaires.

### 8.8 Ce que je retiens de la proposition

| Élément | Verdict |
|---|---|
| Ajouter l'entreprise dans les **Entités** | ❌ `entities` = marchandises |
| Utiliser le flux pour **router** vers une entreprise | ❌ machine à états, pas routage |
| **`facilitator`** comme logement de l'entreprise | ✅ natif, déjà utilisé, rien à ajouter |
| **Toujours un prestataire**, Echango par défaut | ✅ à retenir — un seul chemin partout |
| Faire suivre la **responsabilité financière** | ❌ un drapeau `answersForItsDrivers`, pas l'absence de facilitateur |
| Une **activité native** pour « confiée, pas encore affectée » | ✅ suggestion ajoutée, elle supprime une dérivation côté app |
