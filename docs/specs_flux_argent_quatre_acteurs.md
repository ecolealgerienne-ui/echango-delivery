# Les flux d'argent à quatre acteurs

*Rédigé le 30/07/2026. **Analyse et recommandations — rien n'est implémenté.** Les
questions du §6 sont des décisions produit, pas des choix techniques.*

---

## 1. Les acteurs, et ce que chacun tient

| Acteur | Utilise | Tient de l'argent ? | Doit de l'argent ? |
|---|---|---|---|
| **Destinataire** | rien | non — il paie | non |
| **Transporteur** (driver) | app Echango | **oui**, les espèces à la porte | oui, à qui il doit remettre |
| **Commerçant** | app Echango | non | oui, la course |
| **Entreprise de transport** | app Echango (profil flotte) | ? | ? |
| **Echango** | console Fleetbase | **jamais** (décision fondatrice, Voie B) | non |

L'entreprise de transport est le seul acteur dont les deux dernières colonnes
sont vides. **C'est tout le sujet de ce document.**

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

Reste à trancher s'il faut **aussi** un plafond interne par conducteur (§6.3).

### 4.4 La commission porte sur le prix de la course, pas sur la rémunération

`grossAmount` doit désigner **ce que le commerçant paie pour la livraison** —
un montant que nous fixons ou validons, donc que nous connaissons toujours.
Ce que l'entreprise reverse à son conducteur lui appartient.

Effet de bord favorable : le calcul devient identique pour un indépendant,
chez qui les deux montants coïncident.

### 4.5 Le destinataire n'a toujours aucune voix

Il paie, et **rien dans le système ne vient de lui**. Sur un écart, la parole
du transporteur est la seule source. À quatre acteurs, la chaîne s'allonge
encore : commerçant → entreprise → transporteur → destinataire, soit trois
intermédiaires entre celui qui paie et celui qui constate le manque.

Un accusé de réception au destinataire — SMS ou page de suivi — est le seul
contrepoids possible. Écarté jusqu'ici comme confort ; à quatre acteurs, c'est
un élément de preuve.

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

## 6. À trancher — ce sont des décisions produit

1. **Le commerçant choisit-il une entreprise, ou seulement un transporteur ?**
   S'il la choisit, il faut la lui présenter (recherche, favoris au niveau
   entreprise) et poser `facilitator` à la création. S'il ne la choisit pas,
   l'entreprise ne peut recevoir que ce qu'un opérateur lui attribue — et le
   §3.1 reste un manque assumé.
2. **L'entreprise peut-elle prendre une course diffusée au pool** et
   l'attribuer ensuite à l'un de ses conducteurs ? C'est le mode qui donne un
   sens à son existence sans obliger le commerçant à la choisir.
3. **Plafond de dette interne, conducteur → entreprise ?** L'entreprise a des
   moyens de contrainte que nous n'avons pas (contrat, salaire). Le lui imposer
   par logiciel peut être une gêne autant qu'un service.
4. **Qui supporte la perte si un conducteur disparaît avec les espèces ?**
   L'entreprise répond-elle de ses conducteurs vis-à-vis du commerçant ? C'est
   la question la plus lourde, et la réponse détermine si le modèle « la dette
   est celle de l'entreprise » est acceptable pour elle.
5. **La commission d'Echango est-elle facturée à l'entreprise** en une fois, ou
   course par course comme aujourd'hui ?
6. **Un conducteur peut-il travailler pour deux entreprises**, ou en
   indépendant *et* pour une entreprise ? Si oui, sa dette n'est plus une, et
   l'écran « ce que vous détenez » doit la ventiler par contrepartie.

## 7. Ordre de mise en œuvre suggéré

Aucune ligne ne devrait être écrite avant les réponses 1, 2 et 4 — elles
décident du modèle, pas du code. Ensuite, dans cet ordre :

1. **Généraliser le couple de parties** dans les trois tables du registre
   (§4.1) — à contrat constant, sans changer une règle métier. C'est la
   fondation ; tout le reste en découle mécaniquement.
2. **Poser `facilitator` à la création** quand le commerçant choisit une
   entreprise (§6.1).
3. **Basculer la base de commission** sur le prix de la course (§4.4).
4. **Écran de remise interne** conducteur → entreprise (§4.2) — sans code
   nouveau si 1 est fait.
5. **Accusé au destinataire** (§4.5), qui vaut aussi pour le modèle à trois
   acteurs.

---

## Sources internes

- `docs/specs_paiement_livraison.md` — Voie B, plafond de dette, §9 non tranché
- `docs/architecture_bff_fleetbase.md` — Fleetbase fait foi, exceptions nommées
- `backend/bff/src/cash/cash.service.ts` — le registre actuel
- `backend/bff/src/flotte/flotte.service.ts` — `?facilitator=`, vérifié par appel réel
