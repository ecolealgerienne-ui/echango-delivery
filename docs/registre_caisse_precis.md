# Le registre de caisse — précis de reprise

**Retiré de `main` le 03/08/2026.** Implémentation complète figée sous le tag
**`registre-caisse-v1`** (`1130756`), qui a tourné contre un vrai Fleetbase et
passé dix scénarios de bout en bout.

Ce document existe parce que **le code parqué ne survit pas** : le client Prisma
se régénère, les codes d'erreur bougent, les widgets Flutter évoluent. Trois
mois plus tard un module désactivé ne compile plus — mais il *aurait l'air*
moins cher à reprendre qu'une réécriture, et c'est le piège. Ce qui se récupère,
c'est la **modélisation** ; le tag garde la plomberie pour référence.

---

## 1. Pourquoi c'est parti

**Tenir des soldes est de la trésorerie, pas de la logistique.**

L'argument par Fleetbase est fragile et il ne faut pas s'en servir : Fleetbase
porte `cod_amount` sur la commande, et son vendor embarque une extension
`ledger-api`. Le vrai argument est réglementaire :

> Les plateformes qui tiennent l'argent sont des **transporteurs à agences** —
> Yalidine, ZR, Noest. Elles ont des dépôts, des guichets, un agrément. Les
> agrégateurs ne touchent jamais l'argent. Nous sommes un agrégateur.

Trois choses avaient été confondues sous un seul mot. La séparation est le cœur
de la décision :

| | nature | sort |
|---|---|---|
| le **montant à encaisser** | une donnée du colis, elle voyage avec lui | **gardé** |
| la **déclaration à la porte** | un **évènement** de la livraison, comme la photo | **gardé** |
| **dette, remises, plafond, contrepartie, commission** | des **soldes** | **retiré** |

**La frontière : la plateforme enregistre des faits, elle ne tient pas de
soldes.** Un fait est daté, immuable, et un doublon se voit et se corrige. Un
solde demande une garde d'idempotence, une réconciliation, un avis juridique —
et il ment en silence quand il se trompe.

## 2. Ce qui a remplacé quoi

| avant | après |
|---|---|
| `CashCollection` (table) | champs personnalisés `collected_amount`, `collected_at`, `collection_reason` sur la commande Fleetbase |
| `CashRemittance` (table) | rien — la remise est physique et se règle entre les deux parties |
| `DriverEarning` (table) | rien — la commission se calcule sur un système externe, à partir du volume constaté |
| `settleCashIfDue()` | `recordCollectionIfDue()` — même garde, écriture différente |
| 5 points de vérification du plafond | rien (voir §4) |
| 23 routes | **1**, en lecture : `GET /commercant/encaissements` |
| écran de caisse à 3 personas (1 399 lignes) | `collections_screen.dart`, commerçant seul, lecture seule |
| 29 codes d'erreur `cash.*` | **5** |

**Gain structurel non prévu, et c'est le plus intéressant : l'idempotence
devient gratuite.** La table accumulait des lignes, donc une reprise après échec
réseau exigeait une garde explicite. Écrire la même valeur deux fois sur la même
commande donne le même état — il n'y a plus rien à garder.

## 3. Le modèle, si quelqu'un le reprend

Ce que le tag contient et qui vaut d'être relu avant de réécrire quoi que ce
soit :

- **Aucun solde stocké, jamais.** `CashCollection` et `CashRemittance`
  enregistraient des évènements ; la dette se déduisait par différence. Un
  compteur incrémenté dérive au premier échec partiel, et plus rien ne dit
  laquelle des deux valeurs est la bonne.
- **La chaîne à deux maillons.** Conducteur → facilitateur → commerçant. Une
  même ligne d'encaissement portait **deux** obligations, calculées depuis les
  trois parties nommées dessus (`driverId`, `facilitatorId`, `merchantId`).
- **Le facilitateur figé à l'écriture.** Si un admin change `facilitator_uuid`
  demain, la dette d'hier ne doit pas changer de débiteur.
- **`onDelete: Restrict` partout**, jamais `Cascade` ni `SetNull`. En `Cascade`,
  supprimer un conducteur effaçait la dette que son facilitateur doit au
  commerçant. En `SetNull` sur `facilitatorId`, toutes les dettes portées par
  une entreprise basculaient sans trace en dettes personnelles du conducteur.
- **`earnerType`** décidait qui encaisse la course : le conducteur sur une
  course du pool, l'entreprise sinon. Sans cette distinction, un salarié
  empochait le chiffre d'affaires de son employeur.
- **La base de commission est ce que le commerçant paie**, pas la rémunération
  interne du conducteur — que nous n'aurons jamais.

Les trois specs restent au dépôt et restent justes :
`docs/specs_flux_argent_quatre_acteurs.md`, `docs/specs_facilitateur.md`,
`docs/specs_paiement_livraison.md`.

## 4. ⚠️ Le défaut connu, NON corrigé, qui vit dans le tag

**Les remises ne sont pas idempotentes.**

Mesuré le 03/08/2026 : sur une dette de **7 300**, trois déclarations successives
ont été acceptées pour **14 600** au total. Une remise en attente ne réduit pas
le solde, donc le garde `remittance_exceeds_debt` ne voit jamais le cumul. Un
double appui sur un réseau instable suffit.

⚠️ **Le remède évident est pire que le mal** : faire qu'une remise en attente
réduise la dette laisserait l'effacer sans remettre un billet. Il faut une garde
d'idempotence propre, et c'est une décision sur l'argent.

**Ne pas reprendre ce code sans traiter ce point.**

## 5. Ce que le retrait déplace, et qu'il faut assumer

**Le plafond de dette disparaît, et il ne pouvait pas survivre seul.** Ce qu'un
transporteur détient, c'est l'argent encaissé **et pas encore remis** — sans
registre des remises, ce nombre n'est pas calculable. Un plafond assis sur autre
chose (par exemple le nombre de courses COD en cours) bornerait les colis
portés, pas les billets en poche.

Le risque n'a pas disparu, il a changé de porteur :

| conducteur | qui répond des espèces |
|---|---|
| rattaché à une **entreprise** | l'entreprise — elle a contrat, salaire et sanction, moyens que nous n'avons pas |
| **indépendant** (pool) | le **commerçant**, directement |

⚠️ **Conséquence sur une décision antérieure** : « Echango répond des espèces
pour les indépendants » (02/08/2026) devient intenable — répondre de l'argent
suppose de le suivre. Soit on l'abandonne, soit les courses avec encaissement
sont réservées aux conducteurs d'entreprise et aux favoris du commerçant. C'est
un arbitrage produit, pas technique, et il reste ouvert.

**La commission sort entièrement.** Elle était calculée, écrite en base, et
**jamais perçue** : sur une course du pool la dette allait directement au
commerçant, donc il n'existait aucun flux conducteur → Echango sur lequel
retenir quoi que ce soit. Le volume à facturer, lui, survit intégralement —
courses, prix, dates de clôture — et reste lisible par les routes existantes.

## 6. Comment retrouver le code

```
git show registre-caisse-v1 --stat
git show registre-caisse-v1:backend/bff/src/cash/cash.service.ts      # 1 968 lignes
git show registre-caisse-v1:backend/bff/prisma/schema.prisma          # les 3 modèles
git show registre-caisse-v1:echango_delivery/lib/screens/cash/cash_screen.dart
git diff registre-caisse-v1 -- backend/bff/src backend/bff/prisma     # tout ce qui a bougé
```

Les cinq scénarios shell retirés — `test-parcours-argent`,
`test-parcours-argent-flotte`, `test-plafonds-dette`,
`test-ecart-et-dette-negative`, `test-regularisation-commercant` — sont au même
endroit, avec `reset-test-ledger.sh`, `verify-facilitator.sh`,
`provision-platform.sh` et `scripts/lib/ledger.sh`.
