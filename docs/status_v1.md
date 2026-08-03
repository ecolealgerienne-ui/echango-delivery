# Suivi des travaux — v1

**Ce fichier remplace la section « Prochaines étapes » de `CLAUDE.md`.**

⚠️ **Pourquoi la déplacer** : elle occupait **542 lignes sur 1020**, soit plus de
la moitié d'un fichier dont le rôle est de porter des **règles**. Une règle et
un état d'avancement n'ont ni la même durée de vie ni le même lecteur : la
première se lit avant d'écrire du code, le second avant de choisir quoi faire.
Les mélanger fait relire mille lignes pour trouver ce qui reste à faire — et
fait passer une case cochée pour une règle.

**Ce qui reste dans `CLAUDE.md`** : les treize règles, leur justification, et
l'état de l'environnement. **Ce qui vient ici** : ce qui n'est pas fait, ce qui
est décidé mais pas branché, et ce qui a été écarté avec son motif.

**Où trouver le reste** :

| | |
|---|---|
| les règles de développement | [`../CLAUDE.md`](../CLAUDE.md) |
| où vit chaque donnée, et les pièges Fleetbase | [`ou_vit_quoi.md`](ou_vit_quoi.md) |
| les travaux achevés, avec leurs défauts | [`journal_travaux.md`](journal_travaux.md) |

---

## Les manques constatés — ce qui n'a JAMAIS été éprouvé

Cette section est en tête parce que c'est celle qu'on oublie : elle ne décrit
pas un travail à faire, elle décrit **ce qu'on ne sait pas**. Un banc vert sur
dix sujets ne dit rien du onzième.

### ✅ Le parcours Flutter d'intégration diverge après la suppression du registre (03/08/2026)

Trouvé en **rejouant le parcours 3 personas sur émulateur** — ni les scénarios
`curl`, ni `flutter test` (unitaire) ne pouvaient le voir. Après la suppression
du registre de caisse, `parcoursEcartALaPorte` vérifiait encore un **net**
(`short − codGapFee`) sur une **caisse conducteur qui n'existe plus**, en restant
connecté au mauvais persona. `openCaisse` échouait « 3 onglets ».

**Corrigé** : aligné sur le motif +2/+3 déjà migré — le conducteur déclare
l'écart (le cœur, « le tiroir refuse sans motif », intact), la somme **perçue**
se relit côté commerçant sur le nouvel écran collections. Parcours **11/11**.

⚠️ **La leçon** : le chantier de suppression du registre avait mis à jour le
backend, les docs, les scénarios `curl` **et** deux des trois tests d'argent
Flutter — mais pas le troisième, et **le parcours d'intégration n'avait pas été
rejoué** (il exige un émulateur). Il était cassé en silence depuis ce matin.
C'est l'angle mort nommé dans `CLAUDE.md` : les scénarios ne touchent jamais
l'application.

⚠️ **Observation, PAS un bug** : le run révèle un `notifyListeners()` après
`dispose` dans `CollectionsState.load()`. C'est un **artefact de teardown de
test** — le provider est app-scoped (`main.dart:241`), jamais disposé à la
navigation, donc l'erreur n'apparaît qu'entre deux `app.main()` du test. Toutes
les classes d'état partagent ce motif latent ; aucune ne se déclenche en
production. Non corrigé : le corriger ici seul serait du cargo-cult et une
divergence de convention (règle 5). Si un jour on veut des logs de test
propres, ce serait un mixin de garde partagé, pas un rustine locale.

### ✅ La frontière de sortie — comblée le 03/08/2026, et voici ce qu'elle cachait

Ce manque-ci n'était pas listé, et c'est justement pourquoi il mérite d'ouvrir
la section : **personne ne vérifiait qu'une route APPELLE la projection.**

Trois contrôles portaient sur le sujet et aucun ne posait cette question. Les
tests Jest accordaient le catalogue des champs personnalisés avec la liste
d'autorisation — **deux listes cohérentes** — pendant que deux chemins sautaient
les deux. Les cinq scénarios composaient leurs requêtes en `curl` et
regardaient les codes de retour, pas la forme des réponses.

Résultat : `GET /transporteur/commandes/:id` a servi la commande Fleetbase
**entière** pendant une journée — `meta.declines[]` compris, c'est-à-dire l'uuid
Fleetbase, le motif, les notes libres et le **prix offert** à chaque
transporteur ayant refusé la course. Trouvé en vérifiant une revue de sécurité,
pas par un contrôle du dépôt.

⚠️ **Ce lot l'avait créé.** Les refus vivaient dans une table Prisma jusqu'au
03/08 ; les déplacer vers les champs personnalisés les a fait entrer dans un
`meta` que ce chemin recopiait tel quel. Le déplacement était juste, la
recopie ne l'était plus — et rien ne relie les deux.

**Comblé par `scripts/test-frontiere-projection.sh`** : la même commande lue
deux fois, chez Fleetbase et par le BFF. Prouvé par mutation du vrai code.

⚠️ **Sa limite, dite maintenant** : il vérifie la **forme** de ce qui sort des
routes qu'il connaît. Un chemin neuf qui oublie de projeter le laissera vert.
La question « toute route projette-t-elle ? » reste sans mécanisme — c'est un
manque, et il est ici plutôt que découvert.

### La concurrence — aucun banc, aucun scénario, rien

⚠️ **Vérifié le 03/08/2026 : il n'existe aucun test parallèle dans le dépôt.**
Pas un `&`, pas un `wait`, pas un script de charge. Ce qui a été mesuré, c'est
la **disponibilité** — Fleetbase coupé — et ce n'est ni la concurrence ni la
charge.

**Trois fenêtres sont nommées dans le code et n'ont jamais été constatées.** Les
deux premières ont été **créées par le chantier du 03/08** : la table portait un
`@@unique`, le champ personnalisé ne l'a plus.

| où | ce qui peut se perdre |
|---|---|
| `appendToOrderList` (`declines`) | deux transporteurs refusant la **même course diffusée** — un refus écrasé, la course réapparaît une fois |
| `appendToOrderList` (`delivery_failures`) | idem, mais un seul conducteur par course : peu probable |
| `MerchantFavouritesService.add` | deux ajouts du même commerçant depuis deux appareils |
| clôture d'une commande | deux clôtures simultanées de la même course |

⚠️ **Sur une course en diffusion large, plusieurs refus quasi simultanés ne sont
pas un cas de laboratoire.** La conséquence est documentée — « la course
réapparaît une fois » — mais **documentée n'est pas constatée**.

**Ce qu'il faut** : un banc qui lance N appels en parallèle sur la même
ressource, puis **compte ce qui a survécu**. Une demi-heure, et il répond aux
quatre lignes d'un coup. C'est cheap et décisif ; la charge, elle, est un autre
sujet.

### La charge — jamais mesurée, et un appelant non borné

⚠️ **`hydrateOrders` fait une lecture unitaire par commande**, par lots de huit.
Sur les listes c'est borné — une page de 25, ou un ensemble déjà filtré.

**Sauf un appelant** : `collectionsOnMyOrders` passe **toutes** les commandes du
commerçant. Trois cents commandes font une quarantaine d'aller-retours. C'est
écrit dans le code plutôt que tu — mais **le temps que ça prend n'a pas été
mesuré**.

⚠️ Le borner tronquerait la liste en silence, ce qui serait pire. La réponse
est probablement une pagination de la route, pas un plafond.

### Le comportement sous LENTEUR, distinct de la panne

Le délai d'appel Fleetbase est à **30 s**. C'est très long pour un écran, et
personne n'a regardé ce que fait l'application entre la seconde 3 et la
seconde 30. La panne franche est mesurée ; la lenteur ne l'est pas.

### `GET /health` ne peut pas échouer

Il rend 200 alors que Fleetbase est à terre. Derrière un répartiteur de charge,
il continuerait d'envoyer du trafic sur un BFF incapable de servir.

⚠️ **Non corrigé délibérément** : faire échouer `/health` peut déclencher une
boucle de redémarrage en orchestration. La bonne forme est probablement de
**rapporter l'état de la dépendance sans échouer**, et le choix appartient au
déploiement.

### Un refus amont sort en 400, pas en 503

`order.fetch_failed` dit « votre requête est fautive » là où l'amont est en
panne. Un client peut en conclure qu'il est inutile de réessayer. **Le code est
juste, le statut ment.**

---

## Ce qui reste à faire

Plan d'action d'origine, priorisé : `specs_echango_delivery.md` §9.


> **Ce qui vit ici : ce qui n'est PAS fait.** Une case cochée n'a plus rien à
> apprendre à qui écrit du code aujourd'hui ; une case vide, si.

- [x] ✅ **Vider le BFF de ce que Fleetbase peut porter — les 4 déplacements faits (03/08/2026)**

  **Le critère est la console.** Elle est utilisée en exploitation : une donnée
  qui n'existe que côté BFF est **absente de l'endroit où un opérateur la
  cherche**. Un refus de course, un échec de livraison, un favori expliquent
  chacun un blocage — les garder chez nous, c'est obliger l'opérateur à nous
  appeler.

  | | où c'est maintenant | fait |
  |---|---|---|
  | `Order.specMeta` | champs personnalisés déjà en place | ✅ |
  | `OrderDecline` | `declines` sur la commande | ✅ |
  | `DriverFavourite` | `favourites` sur le `Vendor` du commerçant | ✅ |
  | `DeliveryFailure` | `delivery_failures` sur la commande | ✅ |

  **Tables : 16 → 10.** Donnée métier de commande en base : **zéro**. Et
  `DriverAccount` ne porte plus que le **secret de connexion** — email, mot de
  passe, `tokenVersion`, `active` — plus les liens Fleetbase. C'est le seul
  contenu qu'un opérateur ne doit justement pas voir.

  ⚠️ **Et une propriété gagnée, pas seulement une table perdue** : la route de
  preuve porte désormais l'uuid de la **commande**
  (`GET commandes/:orderId/preuves/:id`). Servir une preuve exige donc de
  résoudre la commande, donc de traverser le contrôle d'appartenance qui existe
  déjà. Elle reposait avant sur un filtre qu'il fallait **penser** à écrire, sur
  un chemin que le code décrivait lui-même comme anti-IDOR. L'application suit
  sans changement : elle traite `photo_url` comme une chaîne opaque.

  ⚠️ **LA LEÇON DU LOT, et elle a coûté une régression en production locale :
  prouver le STOCKAGE n'est pas prouver la LECTURE.**

  La reprise a constaté que **535 commandes sur 535** portaient leurs champs
  personnalisés. C'était exact. J'en ai conclu que `Order.specMeta` — la copie
  locale qui servait de filet — ne rattrapait plus rien, et je l'ai retiré.

  **Or la liste ne porte AUCUN champ personnalisé.** `GET /orders` est servi par
  la ressource d'index : `meta` y vaut `{_index_resource: true}` et
  `custom_field_values` est **absent**, `with[]` ou pas. Seule la lecture
  unitaire `GET /orders/{uuid}` les rend. Résultat : le transporteur s'est
  retrouvé sans prix, sans montant à encaisser et sans exigence de véhicule.

  ⚠️ **L'avertissement était dans le fichier que j'éditais, en majuscules** —
  « CE PARAMÈTRE EST SANS EFFET, ET LA LISTE NE PORTE AUCUN MONTANT », avec la
  mesure du 01/08 juste en dessous. Je l'ai lu et je n'en ai pas tiré la
  conséquence pour le chemin que j'étais en train de casser. Une mesure juste ne
  protège pas d'une conclusion qui porte à côté — même famille que la borne du
  `pubspec` et que « le graphe ne sert à rien » (règle 11).

  ✅ **Le remède est `FleetbaseApiClient.hydrateOrders`** : recharge par
  lectures unitaires, par lots de huit, **après** les filtres que la liste sait
  porter. Employé par les trois modules. Une commande qu'on ne sait pas
  recharger est **rendue telle quelle** avec un avertissement, jamais retirée —
  elle s'affichera sans ses montants, ce qui se voit ; la faire disparaître
  serait un manque que personne ne peut constater.

  ⚠️ **À savoir avant d'ajouter un champ personnalisé** : tout chemin qui lit
  par `fetchEveryOrder` doit recharger, sinon le champ est **toujours vide** et
  rien ne le signale.

  ✅ **La reprise de données est un script du dépôt, pas un geste manuel** :
  `scripts/backfill-order-custom-fields.sh`, idempotent, **prouvé par un second
  passage** à chaque fois. Il refuse de bénir un passage incomplet — et il a
  fallu trois mensonges pour qu'il l'apprenne, tous des `continue` muets :
  546 commandes illisibles suivies d'un « ✅ », 11 refus lus et 0 repris sans un
  mot, et une non-idempotence que seule la seconde exécution a montrée. Le garde
  qui compte : **un script de reprise qui lit des lignes et n'en traite aucune
  n'a pas « rien à faire », il a échoué sans le dire.**

  ✅ **Le PROFIL du conducteur est descendu aussi (03/08/2026)** —
  `firstName`, `lastName`, `phone`, `vehicleType`. Ce n'était pas une
  duplication théorique : mesurée le même jour, elle avait **déjà divergé sur
  les trois conducteurs de la base**. « Test Transporteur » côté BFF contre
  « Amar BENGHARBI » chez Fleetbase, téléphone vide d'un côté et renseigné de
  l'autre. L'application affichait un nom, la console un autre, pour la même
  personne — sans une erreur.

  ⚠️ **Zéro appel Fleetbase ajouté**, et c'est ce qui rend le lot sûr : les
  trois lecteurs interrogeaient déjà Fleetbase pour autre chose. `getProfile`
  lisait le statut en ligne ; le filtre des opportunités lisait la zone et la
  position ; la sollicitation d'un favori lisait la zone de chacun. Le nom et
  la catégorie sortent des mêmes réponses.

  ⚠️ **Un `where` Prisma est devenu un filtre en mémoire**, et c'est un gain :
  la catégorie de véhicule filtrait les favoris dans la requête. Elle filtre
  maintenant sur une lecture qui existait déjà — et garde son biais, *non
  déclaré = compatible*, parce qu'un transporteur ne doit pas être écarté du
  réseau par un champ qu'il n'a pas rempli.

  ⚠️ **Vérifié avant de retirer, pas supposé** : `user.firstName` n'est lu
  **nulle part** dans l'application, et `authState.displayName` ne sert qu'au
  titre de l'écran **commerçant**. Les servir à la connexion aurait imposé un
  appel Fleetbase sur ce chemin pour un champ que personne n'affiche.

  ✅ **Le profil du COMMERÇANT et de l'ENTREPRISE est descendu aussi** —
  `firstName`, `lastName`, `phone`, `businessName`, `businessPhone`. Le nom
  vient du `Vendor` (`getVendorIdentity`), la recherche d'entreprises de
  `searchVendors`.

  ⚠️ **`query=` est mesuré honoré, avec témoin** : 456 vendors, un fragment
  réel en rend 1, un fragment inventé **0**, et `name=` **0** — c'est une
  égalité, pas un « contient ». Sans témoin, un filtre abandonné en silence
  aurait rendu les 456 comme si c'était la réponse.

  ⚠️ **La recherche rend TOUS les vendors, commerçants compris** : chez
  Fleetbase les deux populations sont le même objet. L'appartenance reste
  décidée par le BFF, seul à savoir lesquels sont des entreprises de transport.

  ⚠️ **Le coût, dit plutôt que caché** : un appel Fleetbase de plus sur le
  chemin de **connexion**, pour le titre de l'écran commerçant. Assumé — la
  route est plafonnée à 5/min, et `getVendorIdentity` rend `null` sans lever :
  un nom illisible n'empêche pas de se connecter.

  ⚠️ **Contrôle PRÉALABLE avant de supprimer**, pas après : les 452 comptes ont
  été vérifiés porteurs d'un `Vendor` **nommé** en amont. Sans lui, supprimer
  la colonne aurait perdu le nom au lieu de le déplacer — la migration
  s'annulait d'elle-même si un seul manquait.

  **Les trois tables de comptes ne portent plus que le secret de connexion et
  les liens Fleetbase.** C'est le seul contenu qu'un opérateur en console ne
  doit justement pas voir.

  ⚠️ **Ce qui ne peut PAS monter, et le dire évite de le retenter** :

  | | motif |
  |---|---|
  | les 3 tables de **comptes** | un hash de mot de passe en champ personnalisé serait lisible par tout utilisateur de la console. Aggravation, pas nettoyage |
  | `DriverMembership` | interrogé **dans les deux sens** avec un statut. En champ personnalisé, « les conducteurs de l'entreprise X » impose de balayer tous les conducteurs — le défaut de pagination corrigé le 02/08, réintroduit. ⚠️ Fleetbase a un `FleetDriver` natif, mais il lie `Driver` à `Fleet` quand nos entreprises sont des `Vendor` : c'est un remodelage, pas un déplacement |
  | `DriverInvitation` | cherché **par jeton** — même balayage |
  | jetons push, `MerchantNotification` | le commerçant n'est pas un `User` Fleetbase ; et un historique à croissance non bornée n'est pas un champ personnalisé |
  | `AuditLog` | ce ne sont pas des données métier mais des refus d'accès, qu'aucun opérateur n'a à voir |
  | `Order.merchantId` | racine de **toute** l'autorisation. La déplacer est une décision de sécurité, pas un rangement |

  ⚠️ **Deux mesures faites avant d'écrire, à ne pas refaire** : `Vendor` accepte
  bien des champs personnalisés (`PUT /int/v1/vendors/{public_id}`, enveloppe
  `{vendor: …}`), et **la définition est portée par le vendor lui-même** —
  chaque commerçant a la sienne, donc tout cache doit être **par vendor**. Un
  cache global écrirait les favoris de l'un sur la fiche de l'autre.

  ⚠️ **Et le piège qui a coûté deux fois** : une valeur de champ `array` revient
  **déjà désérialisée** en liste, pas en chaîne JSON. Un `JSON.parse`
  inconditionnel échoue et fait passer une liste pleine pour une liste vide.

  ⚠️ **Un défaut trouvé en chemin, et il est instructif** : les trois champs
  d'encaissement ajoutés le matin même n'atteignaient **aucune application** —
  ajoutés au catalogue, oubliés dans la liste d'autorisation des projections. La
  fiche affichait « pas encore encaissé » sur une livraison déclarée, sans une
  erreur ni un journal. La liste refuse par défaut, ce qui est la bonne polarité
  et rend l'oubli silencieux plutôt que dangereux. Un test tient désormais les
  deux listes ensemble, avec une liste d'exceptions **nommées** — `declines` et
  `delivery_failures` en sont, parce qu'un transporteur n'a pas à savoir qui
  d'autre a refusé la course ni à quel prix.

- [x] ✅ **Le registre de caisse est RETIRÉ — 03/08/2026, décision produit**

  **Tenir des soldes est de la trésorerie, pas de la logistique**, et détenir des
  fonds pour compte de tiers est une activité réglementée qu'un agrégateur
  n'exerce pas. Motif complet, modélisation et défaut connu :
  **`docs/registre_caisse_precis.md`**. Implémentation figée sous le tag
  **`registre-caisse-v1`**.

  ⚠️ **Ne pas argumenter par « Fleetbase ne le fait pas ».** C'est faux et ça
  s'effondre à la première vérification : `Order` porte `cod_amount`, et le
  vendor embarque une extension `ledger-api`. Le vrai argument est
  réglementaire — les plateformes qui tiennent l'argent (Yalidine, ZR, Noest)
  sont des transporteurs **à agences**, avec dépôts et agrément.

  **Trois choses étaient confondues sous un seul mot, et c'est la séparation qui
  décide de tout** :

  | | nature | sort |
  |---|---|---|
  | le **montant à encaisser** | une donnée du colis, elle voyage avec lui | **gardé** |
  | la **déclaration à la porte** | un **évènement** de la livraison, comme la photo | **gardé** |
  | dette, remises, plafond, contrepartie, **commission** | des **soldes** | **retiré** |

  **La frontière : la plateforme enregistre des faits, elle ne tient pas de
  soldes.** Un fait est daté et un doublon se corrige ; un solde demande une
  garde d'idempotence, une réconciliation et un avis juridique — et il ment en
  silence quand il se trompe.

  **Ce qui a remplacé quoi** : 3 tables Prisma → trois champs personnalisés
  Fleetbase (`collected_amount`, `collected_at`, `collection_reason`) ;
  23 routes → **1** en lecture ; 29 codes d'erreur → **5** ; un écran de
  1 399 lignes à trois personas → un écran commerçant en lecture seule ;
  `settleCashIfDue()` → `recordCollectionIfDue()`, même garde, écriture
  différente. Environ **5 000 lignes** retirées.

  ✅ **Gain non prévu, et c'est le plus intéressant : l'idempotence devient
  gratuite.** La table accumulait des lignes, donc une reprise après échec
  réseau exigeait une garde explicite — celle des remises manquait, et trois
  déclarations pour une même dette étaient acceptées (7 300 de dette,
  14 600 déclarés). Écrire la même valeur deux fois sur la même commande donne
  le même état : il n'y a plus rien à garder.

  ⚠️ **Le contrôle de collision est désormais exécuté, pas constaté une fois.**
  Un champ personnalisé qui porte un nom déjà servi par Fleetbase ne produit
  **aucune erreur**, seulement une valeur silencieusement fausse — c'est le
  défaut `currency` du 02/08. Les 56 clés servies par `Order.php` et
  `Index/Order.php` sont **épinglées** dans `order-custom-fields.spec.ts`, et un
  test refuse toute collision non déclarée. Éprouvé par mutation du vrai
  catalogue (un champ nommé `notes`) : il échoue, puis repasse une fois
  restauré. ⚠️ **À reprendre à chaque montée de version de Fleetbase** — une clé
  ajoutée en amont ne casse rien tant que personne ne lui donne le même nom.

  ✅ **Le contrat d'écriture est prouvé en réel** (03/08/2026), et il fallait
  le prouver : `PUT /int/v1/orders/{public_id}` avec `{order: {custom_field_values}}`
  rend 200, la valeur est **relue**, `meta` est **intact** — et surtout **le
  `PUT` fusionne, il ne remplace pas**. Trois champs posés, un `PUT` n'en
  portant qu'un : les trois survivent.

  ⚠️ **C'est ce troisième témoin qui décidait de tout.** Sans lui, l'écriture de
  clôture aurait effacé prix et montant à encaisser **au moment précis où le
  transporteur tient l'argent** — le défaut `meta` du 30/07, reproduit sur le
  mécanisme censé le corriger. Et il fallait **poser** le témoin : lire une
  commande qui ne porte qu'un champ ne distingue pas « les autres ont été
  détruits » de « elle n'en avait pas ». Ma première sonde lisait exactement
  cela, et concluait faussement au remplacement.

  ⚠️ **Ce que le retrait DÉPLACE, et qu'il faut assumer.** Le plafond de dette
  disparaît, et il ne pouvait pas survivre seul : ce qu'un transporteur détient,
  c'est l'encaissé **et pas encore remis**, un nombre incalculable sans registre
  des remises. Le risque change de porteur — **l'entreprise** pour ses
  conducteurs, le **commerçant** pour un indépendant.

  ⚠️ **Conséquence sur une décision de la veille** : « Echango répond des espèces
  pour les indépendants » (02/08) devient **intenable** — répondre de l'argent
  suppose de le suivre. Soit on l'abandonne, soit les courses encaissées sont
  réservées aux conducteurs d'entreprise et aux favoris. **Arbitrage produit
  ouvert.**

  ⚠️ **La commission sort entièrement**, et elle se calcule désormais sur un
  système externe. Elle était calculée, écrite en base, et **jamais perçue** :
  sur une course du pool la dette allait droit au commerçant, donc il n'existait
  aucun flux conducteur → Echango sur lequel retenir quoi que ce soit. Le volume
  à facturer survit intégralement — courses, prix, dates de clôture.

  ⚠️ **Une règle de règlement a disparu de l'écran aussi, et c'était voulu.** La
  fiche commerçant annonçait « vous reviendra : 1 400 » — perçu moins la
  rémunération. Ce n'est pas une lecture, c'est un **arbitrage** que la
  plateforme faisait à la place des deux parties. Les deux nombres restent
  affichés ; la soustraction leur appartient.


- [x] ✅ **Paginer côté Fleetbase là où c'est possible — fait le 02/08/2026**, et l'énoncé de départ était trop large.

  **Un seul site était déplaçable, pas trois.** `FlotteService.getOrders` découpe désormais côté Fleetbase (`getOrderPage`), avec `facilitator` et `status` passés au serveur et `meta.total` relu. Les autres restent, et c'est justifié : `isClaimable` combine statut, `adhoc`, conducteur et facilitateur, `listOrders` (transporteur) applique ensuite véhicule, refus et **zone** — aucun filtre Fleetbase ne les exprime, il faut tout ramener. Le compte de « sept sites » venait d'un recensement, pas d'un examen de chacun.

  ⚠️ **Ce qui rend l'optimisation sûre est le repli, pas le filtre.** Si `meta.total` manque, la route **reprend le parcours complet** au lieu de deviner : `orders.length` dirait « voilà tout » sur une page pleine, donc une liste tronquée en silence — exactement le défaut que le total servi corrige. Le chemin lent est conservé parce qu'il est **juste** ; l'optimisation ne peut donc pas produire un résultat faux, seulement ne pas s'appliquer.

  ⚠️ **Le contrôle d'appartenance en mémoire reste**, et ce n'est pas un doublon : le filtre serveur allège, il n'autorise pas. Une régression de nom de filtre **vide la page** au lieu de servir les courses d'une autre entreprise.

  **Mesuré, chaque filtre contre un témoin inventé** (422 commandes) : `facilitator` 26 contre 0, `status=created` 37 contre 0, `without_driver` 123 contre 422. Bout en bout : la route rend 26, Fleetbase en compte 26 pour ce vendor, deux pages consécutives ne se recouvrent pas, et `status=created` rend 2 — le compte exact de la base.

  ⚠️ **Mon premier banc comparait le NOMBRE DE LIGNES et non les totaux.** Plafonné à `limit=100`, il rendait 100 des deux côtés et concluait « filtre ignoré » sur un filtre qui marchait. C'est le défaut que ce banc existe pour détecter, commis dans le banc. ⚠️ Et un `0` contre un témoin à `0` ne prouve rien non plus : `status=completed` rendait 0, ce qui pouvait aussi bien dire « filtre cassé » — il a fallu la répartition réelle (24 `dispatched`, 2 `created`) pour savoir que le zéro était vrai.

  ⚠️ **Le reste de l'audit est sain, et le dire évite de le refaire** : les seize tables d'alors étaient justifiées, y compris les cinq dont je croyais un moment qu'elles ne l'étaient pas — mon filtre cherchait `///` là où elles emploient `//`. ⚠️ **Elles sont onze depuis le 03/08/2026** : le registre COD — qui était *l'*exception nommée — est retiré, et trois autres tables sont remontées chez Fleetbase (voir la ligne « Vider le BFF » en Prochaines étapes). `DriverMembership` est une relation n-n que `Driver.vendor_uuid` ne peut pas porter, `AuditLog` enregistre des refus que Fleetbase ne voit jamais, et la décision sur les comptes est tranchée dans `specs_bff.md` v2 (`customer-portal-api` ne couvre que le commerçant, rien n'existe pour la flotte ni pour le conducteur).

- [ ] **Le transporteur choisit ce qu'il voit : wilaya d'abord, rayon autour (décidé ET branché le 02/08/2026 — sauf les notifications)**

  ⚠️ **Décisions prises, à ne plus reposer.** Elles répondent à l'arbitrage laissé ouvert par la revue du 28/07 (« la diffusion est à 15 km mais la liste est à l'échelle de l'organisation »). Ce n'était pas une divergence à corriger : **c'est le transporteur qui choisit sa course**, pas le rayon qui choisit pour lui.

  | question | décision |
  |---|---|
  | qui décide de la course ? | **le transporteur** — la liste ne doit pas trancher à sa place |
  | filtre principal | **la wilaya**, et elle est **obligatoire** |
  | filtre secondaire | un **rayon autour de son point**, pour « chercher autour » |
  | valeur par défaut du rayon | **15 km** — sans quoi il voit les courses de toutes les wilayas |
  | distance mesurée depuis | **sa position**, pas une base déclarée |
  | wilaya d'enlèvement ou de livraison ? | **enlèvement** — c'est là qu'il doit se rendre |
  | le rayon gouverne-t-il les notifications ? | **oui**, pas seulement l'affichage |
  | où vit la préférence ? | **champs personnalisés Fleetbase si `Driver` les supporte** (règle 1), colonne BFF sinon |

  ⚠️ **Ce qui est décidé n'est pas ce qui est branché, et l'écart est mesuré** — c'est la leçon du 01/08 sur `specs_facilitateur.md`, où des décisions consignées se lisaient comme un état livré.

  **Ce qui existe déjà** : le géocodage inverse **extrait la wilaya** (`state`/`region` → `province`, `common/geocoding/geocoding.service.ts`), et le carnet d'adresses la conserve — `SaveAddressDto.province`, `SavedAddress.province`, l'écran d'adresses la saisit.

  ✅ **La wilaya voyage — fait le 02/08/2026.** `CreateOrderDto` porte désormais `pickupProvince` et `dropoffProvince`, `createPlace` les écrit, le formulaire les capture depuis le carnet **et** depuis la carte, et la duplication les restaure (elle les perdait, comme elle avait perdu `podMethod` et la quantité de colis avant). **Vérifié par témoin** : une course créée avec la wilaya rend `payload.pickup.province = "ALGER"`, une créée sans rend `null` — Fleetbase abandonnant un champ inconnu sans rien dire, c'est la seule preuve qui vaille.

  ✅ **La préférence et le filtrage de la liste — faits le 02/08/2026.** `common/orders/driver-zone.ts` porte la décision (`zoneAllows`, 22 tests), `fleetbase/driver-zone.service.ts` la range dans les **champs personnalisés du `Driver`**, `GET`/`PUT /transporteur/zone` l'exposent, et `lib/screens/transporteur/zone_card.dart` la règle depuis l'onglet profil — sans quoi seul un opérateur pourrait le faire depuis la console (règle 9).

  ✅ **`Driver` supporte bien `HasCustomFields`** — vérifié dans le source `fleetops` (ligne 60 du modèle, avec quatorze autres modèles), puis **en réel**. La préférence n'est donc dans aucune colonne BFF : la règle 1 est tenue.

  ⚠️ **Trois pièges Fleetbase mesurés en la branchant**, tous invisibles à la lecture : `PUT /int/v1/drivers` exige un corps **enveloppé** `{driver: {…}}` (sinon 500, `TypeError`) et n'accepte que le `public_id` ; la création d'une définition répond sous la clé `custom_field` et non `custom_field_value` ; et **la chaîne vide est refusée sur tout type de champ**, d'où `ZONE_UNSET = '-'` pour dire « effacé » — un `null` ne pouvant pas être écrit.

  ⚠️ **Le filtre est prouvé dans les deux sens, et c'est la seule preuve qui compte** (règle 8) : un filtre qui ne retire rien est indiscernable d'un filtre absent.

  | préférence du conducteur | courses visibles |
  |---|---|
  | aucune | 2 |
  | wilaya = Alger | 2 |
  | wilaya = Tamanrasset (témoin) | **1** — celle sans wilaya, qui reste montrée |
  | retour à aucune | 2 |

  ⚠️ **Le biais, et il est délibéré : ce qu'on ignore ne cache jamais du travail.** Course sans wilaya, course sans coordonnées, transporteur sans position — chaque absence **laisse passer**. Même raison que les statuts inconnus dans `isOrderClaimable` : une course offerte puis refusée est un désagrément, une course jamais montrée est un manque à gagner que personne ne peut constater. Sept des 22 tests ne vérifient que cela.

  ⚠️ **La hiérarchie wilaya → rayon n'est pas un ordre de lecture, elle bouche un trou** : à rayon seul, un transporteur dont on ignore la position ne verrait **aucune course**. La wilaya est déclarée et ne dépend d'aucun capteur ; le rayon est un raffinement qui peut ne pas s'appliquer, et l'écran le dit quand c'est le cas.

  ⚠️ **`DEFAULT_ZONE_RADIUS_KM = 15` est une valeur d'écran, jamais un filtre implicite.** Elle pré-remplit le champ ; `zoneAllows` ne filtre que sur ce qui est **déclaré**. Les confondre ferait disparaître du travail pour tous ceux qui n'ont jamais ouvert le réglage — et « le choix revient au transporteur » cesserait d'être vrai pour eux.

  ✅ **La sollicitation d'un favori honore la zone — fait le 02/08/2026.** C'est **le seul chemin à nous** qui décide à qui va une course : `pickAvailableFavourite` pose `driver_assigned_uuid`, donc **sort la course du pool**.

  ⚠️ **C'est là que ça compte le plus, et l'argument est celui que le code faisait déjà pour `online`** : confier une course à quelqu'un qui a filtré cette wilaya, c'est la confier à quelqu'un qui ne la regardera pas — et **rien ne la reprend** (le second repli, différé, n'existe pas). Le repli, lui, est sans danger : la course part au pool.

  La règle vit dans `zoneAllowsPickup` et **nulle part ailleurs** : `OrderPickup` existe parce que les deux chemins n'ont pas la même chose en main — la liste tient une commande Fleetbase, la sollicitation se décide **avant que la commande existe**. Un test vérifie que les deux rendent la même réponse, sans quoi un transporteur serait écarté d'une liste **et** assigné d'office à la même course.

  ⚠️ **Prouvé à deux branches en réel**, le même favori, la même course : zone = Tamanrasset (départ à Alger) → **non assignée** ; zone effacée → **assignée**. Un filtre qui n'écarte jamais est indiscernable d'un filtre absent.

  ⚠️ **Et le banc a failli conclure trois fois à tort** : création refusée sur des champs de contact manquants (les deux branches disaient « non assignée »), route de mise en ligne inexistante (un favori hors ligne n'est jamais sollicité, donc même faux vert), et lecture des clés Fleetbase alors que la réponse est la ligne **locale** (`driverAssignedUuid`). Il refuse désormais de conclure quand la course n'a pas été créée.

  **Reste à faire** : **les notifications push**. ⚠️ Rien n'est branché aujourd'hui — le dispatch géospatial est **entièrement celui de Fleetbase** (`adhoc_distance` posé sur la course), et le BFF n'a **aucun chemin de notification vers les conducteurs**. Y ajouter un filtre de zone maintenant créerait du code sans appelant, c'est-à-dire le défaut le plus répété du dépôt (règle 9). À faire **en même temps** que le premier envoi réel, avec `zoneAllowsPickup` déjà prêt — sinon la préférence mentira sur un canal et pas sur l'autre.

  **Un point resté à trancher** : une course qui traverse deux wilayas doit-elle apparaître dans les deux ? Aujourd'hui non — seul l'enlèvement décide.

- [ ] **Responsabilité des espèces — tranché le 02/08/2026 (décision produit, contrat à écrire)**

  | cas | qui répond des espèces |
  |---|---|
  | conducteur rattaché à une **entreprise** | **l'entreprise** |
  | conducteur **indépendant** (pool) | **Echango** |

  ⚠️ **RATTRAPÉE PAR LE RETRAIT DU REGISTRE (03/08/2026).** La ligne « le code fait déjà cela » était juste ce jour-là et ne l'est plus : il n'y a plus de registre pour router quoi que ce soit. **Echango ne peut plus répondre des espèces d'un indépendant** — répondre de l'argent suppose de le suivre. La colonne de droite du tableau ci-dessus est donc à retrancher : soit l'indépendant règle directement avec le commerçant, soit les courses encaissées lui sont fermées.

  ⚠️ **Deux conséquences qui changent des points ouverts ailleurs dans ce fichier** :

  - ~~**La commission redevient recouvrable.**~~ **Annulé le 03/08/2026** : la commission sort du code et se calcule sur un système externe. Le flux sur lequel elle aurait été retenue n'existe pas.
  - ~~**Le plafond de dette devient l'exposition d'Echango.**~~ **Annulé le 03/08/2026** : il n'y a plus de plafond, et il ne pouvait pas survivre au registre — ce qui est détenu n'est pas calculable sans les remises.

  **Ce que ça ne règle pas** : la question juridique demeure, mais elle se déplace. Elle n'est plus « qui est responsable » — c'est tranché — mais « le contrat Echango–transporteur suffit-il à couvrir la détention d'espèces pour compte de tiers ». À voir avec les transporteurs et les commerçants.

- [x] ✅ **Devise — fait le 02/08/2026, et la cause n'était pas celle qu'on croyait**

  « 777 USD » à côté de « À encaisser : 2727 DZD ». La ligne d'origine attribuait l'écart à « deux sources qui se contredisent » — c'était vrai, mais la source du `USD` a été trouvée ailleurs, et elle est instructive.

  ⚠️ **`Order` a DÉJÀ une colonne `currency` chez Fleetbase, dont le défaut est `USD` — et notre champ personnalisé porte le même nom.** Sur la **liste**, où les valeurs des champs personnalisés sont absentes (ressource d'index), le repli « à plat » de `readOrderCustomFields` lisait `order.currency` — celle de Fleetbase — et, les champs personnalisés étant fusionnés **en dernier**, cette valeur **l'emportait** sur le `DZD` correct venu de `specMeta`. **Un repli qui gagne contre sa source n'est plus un repli.**

  ⚠️ **Aucune relecture ne pouvait le montrer** : chaque couche prise séparément disait `DZD` — le champ personnalisé, `meta`, `specMeta` — et l'écran disait `USD`. Il a fallu comparer ce que servent **la liste et la fiche pour la même commande** : fiche `DZD`, liste `USD`. Les treize clés du catalogue ont ensuite été comparées aux 37 de la ressource d'index — **une seule collision**, celle-là. À refaire à chaque nouveau champ personnalisé : un nom déjà pris par Fleetbase ne produit aucune erreur, seulement une valeur silencieusement fausse.

  **Deux corrections, parce qu'elles ne traitent pas le même manque** : le repli à plat ignore désormais les clés que Fleetbase sert lui-même (`FLEETBASE_OWNED_ORDER_KEYS`) ; et la devise est décidée **en un seul endroit** (`common/money/currency.ts`, DZD par défaut), que lisent la tarification, le registre de caisse et la projection — sans quoi la même décision resterait écrite trois fois (règle 5).

  ⚠️ **Aucune conversion, et aucune devise sans montant** : « DZD » seul décrirait une somme qui n'existe pas (règle 10). Vérifié en réel — **50 courses servies en USD avant, 0 après** (26 en DZD, 24 sans prix donc sans devise). Éprouvé par mutation : sans la garde et sans la normalisation, 4 des 9 cas échouent.

  **Reste ouvert** : l'Organization Fleetbase a-t-elle un champ devise ? Si oui, c'est de la configuration, et la constante deviendrait un repli au lieu d'une décision.

- [ ] **Robustesse des API — audité le 02/08/2026, rien n'est corrigé** (règles 12 et 13). La mécanique est meilleure que ne le suppose la question qui a lancé l'audit ; ce qui manque, ce sont les **preuves** et six correctifs courts.

  ✅ **(1) Le banc de refus — fait le 02/08/2026** (`scripts/test-frontiere-http.sh`, 9ᵉ scénario). **259 appels, 87 routes protégées, trois refus chacune** : sans jeton (401 `auth.missing_token`), avec un jeton révoqué (401 `auth.session_revoked`), avec le jeton d'un autre rôle (403 `server.persona_forbidden`). Le **code** est vérifié, pas seulement le statut — un 401 sans code est une protection que l'application ne sait pas traduire.

  **Il énumère les routes depuis la source** : une route ajoutée demain est couverte sans que personne y pense. Les identifiants d'URL sont volontairement inexistants, pour qu'un garde tombé ne se traduise pas par une vraie ressource modifiée.

  ⚠️ **Et il a fallu deux versions, parce que la première a passé la mutation.** `@Public` posé sur `GET /commercant/commandes` : le banc est passé **au vert**, de 87 routes à 86 — la route ouverte avait simplement **quitté l'ensemble testé**, en silence. C'était le défaut exact qu'il existe pour attraper, et il l'a laissé passer parce qu'il **prenait sa cible dans la donnée qu'il examinait**. Les huit routes ouvertes sont désormais **épinglées** (`PUBLIC_ROUTES`) : en ouvrir une neuvième fait échouer le banc tant que la décision n'est pas écrite là. Prouvé ensuite dans les deux sens — brèche → refus (sortie 1), correction → 259/259 (sortie 0).

  ✅ **(2) Le banc d'appartenance — fait le 02/08/2026** (`scripts/test-appartenance.sh`, 10ᵉ scénario). **26 routes éprouvées, 26 refus** sur les trois personas. La ressource de A demandée avec le jeton de B rend 403 ou 404, jamais la ressource.

  **Le compte exact des 32 routes à identifiant** (recompté le 03/08/2026, après le retrait du registre de caisse), parce qu'un total sans sa décomposition ne se vérifie pas :

  | | routes | |
  |---|---|---|
  | **éprouvées** | **25** | commandes, adresses, favoris, notifications (commerçant) · commandes, adhésions (entreprise) · course assignée, dépôt de preuve, rattachements (transporteur) |
  | exclues, l'appartenance n'y est pas la question | 5 | opportunités (visibles à toute entreprise), prendre une opportunité, inviter un conducteur, accepter/refuser une course libre |
  | décor **photographique** | 2 | `GET preuves/:id` (commerçant et transporteur) — il faut une preuve existante, donc une livraison achevée avec sa photo |

  ⚠️ **Les 8 routes à décor comptable ont disparu, elles n'ont pas été couvertes.** `remises/:id/confirmer|contester` des trois personas et `encaissements/:id/confirmer|contester` du transporteur sont parties avec le registre — la couverture passe de 26/41 à 25/32 sans qu'aucune épreuve n'ait été ajoutée. Le dire évite de lire une amélioration là où il n'y a qu'une soustraction.

  ⚠️ **Une route avait été rangée sur son NOM plutôt que sur son besoin.** `POST /transporteur/commandes/:id/preuve` était comptée avec les preuves à décor parce qu'elle en porte le mot — alors qu'elle n'exige **aucune preuve existante** : une photo dans le corps (un PNG d'un pixel suffit) et une course de A, que le banc avait déjà. Le tri paresseux que ce fichier dénonce partout, commis dans son propre inventaire.

  ⚠️ **Chaque épreuve porte son témoin, et c'est ce qui la rend non tautologique** : A doit d'abord obtenir SA ressource (2xx). Un identifiant du **mauvais type** rend 404 partout — un banc naïf y lirait « l'appartenance est vérifiée » et serait vert sans rien prouver. Sans témoin, le persona est déclaré **non couvert**, jamais réussi. Les identifiants sont découverts en listant les ressources de A, jamais écrits en dur.

  Prouvé par mutation du vrai service : `getOrderDetail` privé de son filtre par commerçant → « **SERVIE À B (200)** », sortie 1 ; restauré → 10/10, sortie 0.

  ⚠️ **Trois précautions de conception, chacune née d'un essai qui prouvait moins qu'il n'en avait l'air** :

  - **Le témoin faible est nommé comme tel.** Il n'existe pas de `GET /commercant/adresses/:id` : exercer PUT ou DELETE avec le jeton de A pour prouver que la route répond **détruirait sa donnée**. Le témoin se réduit alors à « l'identifiant vient de la liste de A », et le rapport l'écrit plutôt que de laisser croire à une preuve à deux temps.
  - **Le banc pose son propre décor** quand A n'a pas la ressource (un favori), et le retire. Sans cela il resterait durablement « incomplet », donc rouge — et **un banc durablement rouge finit ignoré**. ⚠️ Le décor exige un **vrai** conducteur : un identifiant inventé est refusé en 400, et la sonde ne prouvait rien.
  - **Les corps des sondes viennent des DTO réels**, pas d'une supposition — `activity` est un objet, `reason` vient d'une liste fermée, `terminer` attend un montant. Un corps invalide fait répondre 400 **avant** l'appartenance : la route ressort « non concluante » et reste non éprouvée sous couvert de refus. Deux routes étaient dans ce cas.

  ⚠️ **Deux décisions de conception ajoutées en complétant la couverture** :

  - **Le banc ne sonde que des identifiants que le pipe accepte.** La liste des encaissements du transporteur mêle des lignes `earning:<uuid>` dont le deux-points est hors du motif de `FleetbaseIdPipe` : les sonder donnait 400 **avant** toute question d'appartenance, et deux routes restaient non éprouvées sous couvert de refus.
  - **Une ressource absente est NOTÉE, pas fatale — et c'est un arbitrage.** Un encaissement n'existe qu'après une livraison payée à la porte ; en poser un demanderait d'écrire dans le registre de caisse, ce qu'un banc de sécurité n'a pas à faire. Mais faire échouer le banc quand la base n'en porte pas le rendrait **durablement rouge, donc ignoré** — et un banc ignoré ne protège rien. Il l'imprime à chaque passage dans son récapitulatif, plutôt que de se taire ou de crier.

  ⚠️ **Trois fois le banc a accusé le mauvais coupable avant d'être juste** : un champ hors DTO refusé par `forbidNonWhitelisted` (ma propre inscription, rejetée par la validation stricte), des comptes créés mais **en attente de validation** (`merchant_pending`), et le **plafond de connexion que le banc épuisait lui-même** (5/min) — il rapportait alors « persona NON COUVERT », un verdict qui accuse l'appartenance pour un problème de débit. Les trois disaient la même chose : *« je n'ai pas pu savoir »* n'est pas *« rien à signaler »*.

  ✅ **(3) L'hygiène de la frontière, tenue par un test — fait le 02/08/2026** : `common/dto-hygiene.spec.ts` refuse un `@Body` typé en ligne, un champ de DTO sans décorateur, un `@Param('id')` sans pipe, et une regex partagée recopiée en clair. Onze cas, dont **six qui doivent échouer**, et une **mutation de deux vrais fichiers** (pipe retiré, motif recopié) qui les fait tomber tous les deux.

  ⚠️ **Un test Jest plutôt qu'un script à part** : il tourne avec `npm test`, donc il ne peut pas être oublié. Et **il protège le code à venir, ce qu'aucun rangement du code présent ne fait** — le dépôt était déjà propre sur ces quatre points ; ce qui manquait, c'est ce qui empêche la prochaine route de rouvrir un des quatre trous.

  ✅ **(4) La copie échappée** de `register.dto.ts` importe désormais `FLEETBASE_ID_PATTERN`.

  ✅ **(5) Les correctifs courts — faits le 02/08/2026, et constatés en service** :

  - **`@Catch()` sans argument** : le filtre attrape désormais **toutes** les exceptions, pas seulement les HTTP. Une `TypeError` ou une erreur Prisma sort avec `server.unexpected` au lieu de sortir sans `code` — la règle 3 était percée sur son chemin le plus obscur. ⚠️ **Le message d'origine ne sort pas** (une erreur Prisma cite des colonnes, une erreur Axios une URL interne) ; il va au journal. Six cas, dont le témoin qui vérifie qu'une `HttpException` garde son propre code — sans lui, un filtre qui écraserait tout en `server.unexpected` passerait les cinq autres.
  - **En-têtes de sécurité, sans `helmet`** : `nosniff`, `DENY`, `no-referrer`, et `X-Powered-By` retiré. ⚠️ Écrits à la main **parce que le BFF sert du JSON à deux applications mobiles** : sur les quinze en-têtes d'`helmet`, la douzaine qui concerne le rendu n'a aucun effet ici. **Cet arbitrage tombe le jour où une page web est servie.**
  - **CORS** : le défaut `FLEET_APP_URL` valait `http://localhost:3001` — **le port du BFF lui-même**.
  - **`driverIds` borné** par un DTO (`DriverPositionsQueryDto`) : il était lu en `@Query('driverIds')`, donc **hors du `ValidationPipe`**. Constaté : liste normale 200, liste énorme **400**, caractères hors motif **400**.
  - **Identifiant de corrélation** : posé sur chaque requête, rendu en `X-Request-Id`, présent dans le journal et dans le corps d'erreur. L'en-tête entrant est **repris** mais **nettoyé** — sinon une chaîne venue du dehors finirait recopiée dans un journal qu'on lit. Constaté : `bad<>;value` → `badvalue`.
  - ⚠️ **Reste ouvert** : le débit est par IP et **en mémoire** — derrière un proxy sans `TRUST_PROXY` correct tout le monde partage un compteur, et à deux instances les compteurs ne s'additionnent pas. À traiter au déploiement VPS.

  ⚠️ **Deux mutations n'ont pas pris effet avant d'être justes**, et c'est à consigner : casser `/health` pour déclencher une erreur non HTTP a laissé la route répondre 200 (essai sans valeur, remplacé par un test unitaire sur le vrai filtre), et désactiver le filet par `if (false)` a **cassé le typage** — la suite ne compilait plus, ce qui n'est pas un refus. *« La mutation n'a jamais pris effet »* et *« le contrôle est aveugle »* sont deux choses.

  **(6) Deux décisions à prendre, pas des correctifs :**

  - **Chaque requête coûte une lecture en base** (`active` + `tokenVersion`). C'est le prix de la révocation immédiate, et il est peut-être juste — mais il fait dépendre l'**authentification** de Postgres : sous lenteur, tout tombe ou traîne. À assumer explicitement ou à mitiger (cache court, révocation différée).
  - **L'idempotence de l'argent est décidée route par route** — `declareCollection` est permissive, `declareRemittance` volontairement pas. Un double appui sur un réseau instable est un cas réel ; la question mérite une réponse d'ensemble plutôt qu'un choix par auteur.

  ⚠️ **Ce que l'audit ne dit pas** : que la validation est faible. Elle ne l'est pas — `whitelist` + `forbidNonWhitelisted`, 134 champs tous décorés, 41 identifiants tous filtrés. Ranger davantage les DTO **ne comble aucune des deux vraies brèches**, qui sont (1) et (2).

  ⚠️ **Et une leçon de méthode, parce qu'elle s'est produite trois fois dans la même journée** : mon scanner de DTO a annoncé **six champs non validés qui l'étaient tous** — il s'arrêtait sur le `})` d'un décorateur multi-ligne. Deux versions ont échoué avant la bonne. **Un outil d'audit se vérifie comme un vérificateur** : sur des cas dont on sait qu'il doit les refuser, et sur des cas dont on sait qu'il doit les accepter.

- [ ] **Résilience — mesurée le 03/08/2026 en coupant Fleetbase, deux mensonges corrigés, le reste à faire**

  L'expérience tient en une commande : `docker stop fleetbase-src-httpd-1`, on interroge, on redémarre. Elle a rendu plus que trois heures de lecture.

  ✅ **Deux routes rendaient une liste vide en HTTP 200.** `GET /commercant/adresses` servait `{"data": []}` à un commerçant qui a **deux** adresses — son écran affichait « aucune adresse enregistrée » et l'invitait à ressaisir ce qui existe déjà. Idem pour l'historique des transporteurs. Les deux levaient un `catch → return { data: [] }` : **le repli qui détruit l'information d'absence** (règle 10), la faute la plus documentée du dépôt, vivante sur deux routes. Corrigé en `merchant.addresses_unavailable` / `merchant.known_drivers_unavailable`, vérifié sous coupure réelle.

  ✅ **Ce qui dégradait déjà correctement** : la liste de commandes du commerçant sert le cache local avec `stale: true` par ligne, et l'application le lit (`MerchantOrder.degraded`). Les listes de l'entreprise et du transporteur lèvent `order.fetch_failed` / `driver.fetch_failed` — un refus codé, donc traduisible.

  ⚠️ **`GET /health` rend 200 alors que Fleetbase est à terre.** Une sonde qui ne peut pas échouer n'est pas une sonde : derrière un répartiteur de charge, elle continuerait d'envoyer du trafic sur un BFF incapable de servir. **Non corrigé délibérément** — faire échouer `/health` peut déclencher une boucle de redémarrage en orchestration. La bonne forme est probablement de **rapporter l'état de la dépendance sans échouer**, et le choix appartient au déploiement.

  ⚠️ **Un refus amont sort en 400, pas en 503.** `order.fetch_failed` dit « votre requête est fautive » là où l'amont est en panne — un client peut en conclure qu'il est inutile de réessayer. Le code est juste, le statut ment.

  **Reste entier** : la concurrence (deux clôtures simultanées), la charge, et le comportement quand Fleetbase répond **lentement** plutôt que pas du tout — le délai est à 30 s, ce qui est très long pour un écran.

- [ ] **Priorité 3** : trancher les règles métier non tranchées (tarification, commission, annulations, SLA, onboarding — liste complète dans `docs/specs_echango_delivery.md` §6).
- [x] ✅ **Migrer les données métier de `meta` vers les champs personnalisés — FAIT**, et vérifié dans le code le 02/08/2026 : `createOrder` envoie `custom_field_values`, `meta` ne porte plus que `pricing_inputs`, et `effectiveOrderMeta` sert les trois couches par ordre de durabilité. ⚠️ **Cette ligne est restée cochée « à faire » après coup**, ce qui a fait reposer la question deux jours plus tard.

- [ ] **Le nom `meta` sur le contrat, alors que la source est `custom_field_values` (ouvert le 02/08/2026)** — le BFF sert l'objet fusionné sous le nom `meta`, donc un lecteur croit lire le `meta` de Fleetbase quand il lit surtout des champs personnalisés.

  ⚠️ **`custom` serait faux dans l'autre sens** : la fusion contient aussi le `meta` historique et `specMeta`, pour les commandes d'avant la migration. Le nom juste dirait « les données métier effectives, quelle que soit leur couche » — la fonction s'appelle déjà `effectiveOrderMeta`, c'est le nom **sur le fil** qui ment.

  **Ce que ça coûte** : le champ est lu partout — modèles Flutter des trois personas, projections, scénarios shell. Contenu mais réel. **Ce que ça n'est pas** : un prérequis aux tests humains — aucun testeur ne voit ce JSON.

- [ ] ~~**Ancienne note de migration, conservée pour le motif**~~ (30/07/2026, § Règles §1) : `meta` est remplacé en entier par toute mise à jour qui le mentionne, et la console le fait en affectant un transporteur. `custom_field_values` est la mécanique prévue — table séparée, synchronisée seulement si la requête la porte, `delete_missing` désactivé par défaut. **Ce que ça demande** : déclarer les définitions `CustomField` sur l'`OrderConfig` (une par donnée : prix, montant à encaisser, marchandise, véhicule, préférence de favoris…), les envoyer sous `order.custom_field_values` à la création, et les relire via `with[]=customFieldValues`. **Ce que ça apporte en plus de la sûreté** : un admin peut corriger un prix depuis la console et cette correction est visible — ce que `meta` ne permettait pas de façon fiable. **À vérifier en réel avant de basculer** : le format exact accepté par `syncCustomFieldValues`, le comportement quand une définition manque, et si la console affiche bien ces champs sur la fiche commande. `Order.specMeta` reste jusque-là, et sera retiré ensuite.
- [ ] **Signaler le bug à l'amont** (`fleetbase/fleetops`) : `addon/services/order-actions.js` → `assignDriver()` sauvegarde une commande issue de la ressource d'index sans la recharger, ce qui écrase `meta` avec le drapeau `_index_resource`. Le correctif tient en trois lignes et existe déjà partout ailleurs dans le même dépôt (`place-actions.js`, `driver-actions.js`, `vehicle-actions.js`, route de détail des commandes) : `if (order?.meta?._index_resource) await order.reload();`. `unassignDriver()` fait le même `order.save()` et mérite la même vérification.
- [ ] **Au déploiement VPS — brancher les webhooks Fleetbase (Lot 5)** (`docs/plan_migration_fleetbase.md` §7, journal §25) : reporté le 29/07/2026 parce que **Fleetbase refuse toute URL de webhook non publique** (« The url must be a public HTTP or HTTPS URL » — ni `localhost`, ni `host.docker.internal`), ce qui imposait un tunnel, c'est-à-dire exposer un service sur Internet pour un contrôle de dix minutes. Sur le VPS l'obstacle disparaît : domaine et certificat suffisent. **L'endpoint `POST /webhooks/fleetbase` a été écrit puis retiré le même jour** — une route publique sans vérification de signature qu'on ne rouvrirait qu'au déploiement serait déployée avec le reste ; il est dans l'historique git. `scripts/webhook-listener.js` est conservé, c'est un outil de développement autonome. **Entre-temps `OrderReconcilerService` fait le travail**, avec `Order.status`/`Order.driverAssignedUuid` pour mémoire, et la chaîne est validée en réel (§23.5) — plus lent et plus coûteux qu'un webhook, mais pas un pis-aller. **Ordre au moment de le reprendre** : déclarer le webhook (tous identifiants API, tous évènements — leur vocabulaire réel est inconnu), observer avec l'écouteur pour relever le nom et le format de l'en-tête de signature, la forme du corps (commande entière ou simples identifiants ? cela décide si le réconciliateur peut disparaître), **puis seulement** recréer l'endpoint — signature d'abord, effets ensuite.
- [ ] **Au déploiement VPS — `APP_DEBUG=false` côté Fleetbase** : le 500 du filtre `phone` observé le 29/07/2026 renvoyait une page d'erreur Laravel complète (chemins de fichiers, requêtes SQL).
- [ ] **Au déploiement VPS — reconfigurer le contournement de preuve photo** (journal §7.8, §11.9) : le BFF envoie `disk`/`bucket` dans la requête pour contourner un bug amont Fleetbase, et cette valeur **prend le pas sur la config serveur**. Passer en S3 sans renseigner `FLEETBASE_PROOF_DISK=s3` et `FLEETBASE_PROOF_BUCKET=<bucket>` ferait écrire sur le disque public malgré une config S3 correcte, sans erreur visible. Vérifier au passage si l'amont a corrigé la ligne : si oui, retirer le contournement, qui deviendrait nuisible. **Prérequis en développement** : `FLEETBASE_PROOF_DISK` vaut `public` par défaut et exige `php artisan storage:link` côté Fleetbase — sans ce lien le fichier est écrit mais aucune route ne le sert.
- [ ] **Reste du plan de migration** (`docs/plan_migration_fleetbase.md`) : le **Lot 5 est reporté au VPS**, voir la ligne dédiée ci-dessous. Tous les autres lots sont clos. Anciennes vérifications restantes : les filtres `orders?customer|facilitator|driver` et `drivers?query` par appel réel, **toujours en comparant un filtre valide à un filtre inexistant** ; le comportement du cache Redis après écriture (deux requêtes) ; `$filterParams` sur le modèle `Order` ; le champ de statut du `Vendor` pour la validation commerçant ; l'émission et la politique de relance des **webhooks** `fleetops`, qui remplaceraient le réconciliateur et le miroir de statut.
- [ ] **Trois chantiers de mutualisation, décidés le 31/07/2026** — ils correspondent aux règles 5, 6 et 7, et ils sont écrits ici parce qu'une règle sans chantier est une règle que le code viole en silence. **Ordre recommandé : 3, puis 2, puis 1** — le troisième est le moins risqué et rend les deux autres mécaniques. **Les trois sont faits** (voir chacun ci-dessous pour ce qu'il a trouvé).

  ⚠️ **Aucun `flutter analyze` n'est possible dans ce bac à sable** (pas de toolchain Dart). Les contrôles menés à la place sont mécaniques, nommés, et **chacun a attrapé au moins un défaut réel** : équilibre des délimiteurs par un scanner qui comprend l'interpolation Dart ; portée de chaque `scheme`/`semantic`/`context` aux sites modifiés — c'est lui qui a trouvé un `scheme` employé sans exister ; imports manquants et devenus inutiles ; et **aucune chaîne visible perdue**, comparée à HEAD par un extracteur qui *concatène les littéraux adjacents* (sans quoi un simple ré-enveloppement de ligne passerait pour une modification de texte). Deux lots sont en outre prouvés **par inversion** : resubstituer les jetons d'espacement, ou réécrire chaque `AppSectionCard` en `Card > Padding`, redonne la version précédente au caractère près. Rien de tout cela ne remplace l'analyseur — à passer côté utilisateur.

  ⚠️ **Une erreur de méthode commise deux fois dans ce chantier, à consigner** : remplacer un bloc par une **tranche entre deux ancres** au lieu du bloc entier. Dans `orders_screen.dart` la tranche a avalé le `return` suivant, et la liste non vide s'est retrouvée à rendre l'ancien état vide. Fichier repris depuis git, refait avec des ancres complètes, et le transformateur de cartes de section a ensuite été écrit à parenthèses équilibrées pour cette raison.

  **(1) Mutualisation des fonctions** (règle 5) — **✅ fait le 31/07/2026, en quatre lots.** Six défauts réels en sont sortis, et **aucun n'a été trouvé en relisant**.

  ⚠️ **Le `grep` sur les formules d'aveu (« doit rester identique à ») n'a donné qu'un cas sur quatre.** Les trois autres sont venus d'une **comparaison mécanique des corps de fonction**, normalisés puis appariés par similarité — ce que la prose ne pouvait pas trouver, puisqu'une copie muette ne s'annonce pas. C'est l'outil à reprendre au prochain passage, pas le `grep`.

  **(a) Un test qui recopiait ce qu'il vérifie.** `subscriber-number.spec.ts` portait une copie de `subscriberNumber`/`sameIdentifier` et s'en justifiait par la dépendance à Prisma. **La copie avait déjà divergé** : le service commençait par `if (typeof stored !== 'string' || !stored.trim())`, pas elle — or `email` et `phone` sont facultatifs sur un conducteur, donc `null.trim()` aurait levé au milieu d'un contrôle de doublon. La justification tenait, la conclusion non : il suffisait d'extraire dans un module qui n'importe rien. Un cas ajouté vient d'une **mutation**, pas d'une relecture — assouplir la longueur exigée (`=== 9` en `>= 6`) laissait les cinq autres au vert.

  **(b) Cinq façons d'écrire une date, dont deux fausses.** Le détecteur a trouvé deux fonctions identiques sous deux noms ; le reste est apparu en regardant toutes les dates. **L'écran transporteur affichait « Créée le » en UTC** — une heure trop tôt, juste au-dessus d'une date d'échec que le même écran localisait correctement. Plus un rembourrage manquant (« 5/8 » contre « 05/08 ») et un format ISO isolé. `utils/dates.dart` + un test qui **dit ce qu'il ne peut pas prouver** : recalculer l'attendu avec `toLocal()` serait une tautologie, donc le cas de localisation est neutralisé sur une machine en UTC plutôt que faussement rassurant.

  **(c) Une décision « erreur → message » écrite 34 fois**, en trois vocabulaires et pour six usages du résultat. `messageForError()` la porte ; la plomberie (`_isLoading`, `notifyListeners`, la relecture) reste chez chaque classe — la fusionner aurait demandé un paramètre par variante, soit la duplication déguisée en factorisation. **Quatre trous invisibles site par site** : trois `catch` sans repli du tout, alors que `getMerchantAddresses` et `addFavouriteDriver` n'enveloppent pas leurs erreurs réseau — un `SocketException` remontait **non géré**, écran muet ; et un quatrième affichait « erreur inconnue » sur un code qui a une traduction.

  **(d) Le cas où le critère a dit « ne pas fusionner », et avait raison.** Trois enveloppes HTTP `confirm*Remittance` à 93-96 % : trois routes distinctes, qui ne doivent pas changer ensemble. C'est leur **divergence de surface** qui valait d'être suivie — la variante flotte sérialisait `{'reason': null}` là où les deux autres omettaient la clé. En remontant le fil : **la route flotte n'avait aucun DTO**, seulement un type en ligne `@Body() dto: { reason?: string }`, et le `ValidationPipe` ne valide que les classes décorées. Une entreprise pouvait donc contester avec un motif de **longueur illimitée** là où les deux autres personas sont bornés à 500 caractères. Le plafond n'était pas contourné — il n'existait pas sur ce chemin. Et les deux personas qui l'avaient portaient **chacun leur copie du DTO**.

  ⚠️ **Ce qui a été délibérément laissé, et pourquoi.** Les trois enveloppes d'écriture des classes d'état (`_mutate`, `_addressWrite`, `_mutateOrder`, 93-98 %) ne diffèrent que par la relecture qu'elles déclenchent — mais les fusionner demanderait un `mixin` accédant à des champs privés de quatre classes, pour aucun défaut observable. Le critère prévoit ce cas : l'invariant se tient alors par un contrôle. Ici il tient **par construction** — il ne reste plus un seul `translateErrorCode` dans `lib/state/` hors des codes client levés localement, donc il n'y a plus rien à vérifier. Et la répétition des ~30 enveloppes HTTP a été **contrôlée plutôt que supposée saine** : une seule méthode ne vérifie pas sa réponse (`logout`), et c'est l'exception documentée — sa route n'existe effectivement pas côté BFF, vérifié.

  **(2) Mutualisation des composants graphiques** (règle 6) — **✅ fait le 31/07/2026, en six lots** (composants + un dossier par commit). Les quatre motifs sont dans `lib/widgets/`, et **zéro `Colors.*` ne subsiste dans `lib/screens/`** : la couleur ne se décide plus que dans `theme/`.

  **Trois des quatre extractions ont fermé un défaut réel, et aucun n'avait été trouvé en relisant.** (1) L'onglet Conducteurs affirmait « Aucun conducteur rattaché à votre entreprise » **quand le BFF était injoignable** — `FleetState.load()` avale l'échec en rendant une liste vide, et `driversUnavailable` existait déjà sans que l'écran le lise ; d'où `AppEmptyState.unavailable`, un constructeur distinct qui force la question *« est-ce vide, ou n'ai-je pas pu savoir ? »* à l'écriture. (2) **Dix refus s'affichaient exactement comme des confirmations** — six côté entreprise, quatre côté commerçant : `SnackBar(content: Text(error ?? 'Course prise'))`, un seul message, aucune couleur. `showAppOutcome` déduit le ton de la donnée, il n'y a plus rien à penser à l'appel. (3) `AppEmptyState` rend `hint` **obligatoire**, et cinq écrans n'en avaient aucun — le compilateur tient maintenant ce qu'un commentaire ne tenait pas.

  **Une fusion de la règle 5 trouvée en chemin** : `_getStatusColor` existait **deux fois, identique caractère pour caractère** (commentaire compris), et **les deux oubliaient l'orthographe `cancelled`** — une course annulée sur deux tombait dans le gris. Même forme que `isClaimable`/`isClaimableAdhoc` en juillet : deux copies d'accord entre elles ne prouvent rien. La table du **commerçant** reste séparée, et le critère le dit — `created` est son brouillon (neutre) là où c'est une course qui attend pour le transporteur (avertissement).

  **`AppSemanticColors` était un préalable, pas un extra** : `ColorScheme` a un rôle `error` mais **aucun rôle succès ni avertissement**. Les huit `Colors.green` et douze `Colors.orange` n'étaient pas de la négligence — il n'existait aucun endroit où les mettre. Extension de thème et non constantes, l'application ayant deux thèmes : un vert figé serait illisible sur fond sombre, soit le défaut de la règle 6 sous un nom plus présentable.

  ⚠️ **La carte de section, elle, ne corrige rien** — et le dire importe : elle nomme seulement les deux densités que le code employait sans les distinguer (14 `lg`, 4 `md`, ces dernières toutes dans la caisse). Rôles Material limités à Flutter 3.20, la borne déclarée dans `pubspec.yaml` : ni `surfaceContainerHighest` (3.22) ni `surfaceVariant` (déprécié, donc un `info` que `flutter analyze` remonte). ⚠️ **Correction du 01/08/2026** : cette borne était fausse (réelle : `>=3.24.0`, imposée par la contrainte Dart du même fichier), donc `surfaceContainerHighest` était **disponible** et la limitation invoquée ici n'existait pas. Le refus de `surfaceVariant` tient, lui : il est déprécié, ce qui ne dépend d'aucune borne.

  **(3) Centraliser les valeurs en dur des écrans** (règle 7) — **✅ fait le 31/07/2026, en deux lots.** Détail et vérificateurs en § Règles §7 ; l'essentiel ci-dessous.

  **Lot 1, les valeurs métier** (celles qui peuvent mentir). Quatre miroirs de règles serveur dans `ServerRules`, dont **une divergence réelle trouvée en instruisant le chantier** : l'écran de caisse laissait passer deux caractères là où le serveur en exige trois, donc un refus incompréhensible sur une saisie que l'application venait d'accepter. Une **troisième** valeur dormait dans `lib/validation/validators.dart` — fichier mort, jamais importé, mais parfaitement utilisable, avec un mot de passe à six caractères contre huit côté serveur ; supprimé. Et `maxPhotoBase64Length`, le miroir le plus cher (cinq mégaoctets envoyés avant un 400), qui vivait sous un commentaire « doit rester alignée sur… ».

  **Lot 2, les valeurs d'apparence** : 320 sites vers `AppSpacing`/`AppRadius`, `app_theme.dart` compris. **Vérifié comme un renommage pur** — en resubstituant chaque jeton par sa valeur et en retirant la ligne d'import, chaque fichier redevient sa version précédente au caractère près. C'est la seule preuve qui distingue un renommage d'une modification, et sans elle un lot de cette taille est impossible à relire.

  ⚠️ **Ce qui reste, et qui est un choix** : une vingtaine de littéraux hors barème, laissés parce que les glisser vers le jeton voisin déplacerait des pixels — décision de design, à prendre à l'écran. `check_spacing.dart` les recense, et **imprime leur compte** pour qu'il ne soit plus recopié — le chiffre noté à la main a divergé de la mesure, et sa correction, transcrite depuis une sortie tronquée, était fausse elle aussi. Deux fois la même erreur par le même geste.

  **Pourquoi cet ordre** : les jetons d'apparence sont un remplacement mécanique et vérifiable par l'analyseur ; les composants s'écrivent naturellement avec ces jetons une fois qu'ils existent ; et la revue des invariants de fonctions demande un jugement au cas par cas, donc du temps et de l'attention, qu'il vaut mieux dépenser en dernier. ⚠️ **Aucun des trois n'est vérifiable dans ce bac à sable** (pas de toolchain Flutter) : chacun demande un `flutter analyze` et un passage à l'écran côté utilisateur, par petits lots.

- [ ] **Publier les deux signalements amont** : `docs/signalements_amont.md` — rédigés en anglais, prêts à coller. (1) `fleetbase/fleetops`, `assignDriver()` qui écrase `meta` faute de recharger une ressource d'index — correctif de trois lignes, déjà présent quatre fois ailleurs dans leur dépôt. (2) `Graphify-Labs/graphify`, l'import relatif Dart non résolu qui crée un nœud fantôme au `source_file` vide et fabrique des chemins **plausibles et faux** — avec les mesures (2 % de nœuds fantômes, 3,83 arêtes/nœud en TS contre 1,61 en Dart) et le cas de reproduction.

- [x] ⚠️ ~~**« Echango est toujours le facilitateur » est une DÉCISION, pas du code**~~ — **CLOS SANS ÊTRE FAIT, le 03/08/2026.**

  L'écart entre la doc et le code était réel, et il ne sera jamais comblé : le registre qui aurait porté cette décision est retiré (`docs/registre_caisse_precis.md`). Conservé ci-dessous **pour la leçon de méthode**, qui vaut indépendamment du sujet.

  *(Constat d'origine, 01/08/2026 :)* — et c'est la plus grosse pièce non écrite du projet, celle qui a le plus l'air faite.

  `docs/specs_facilitateur.md` §2.2 et §2.3 sont titrées « ✅ **Décisions prises** le 31/07/2026 ». Elles se lisent comme un état livré. **Le code dit autre chose**, et la vérification tient en deux lignes :

  ```
  resolveFacilitator(order):  if (!order.facilitator_uuid) return null;
  ```

  Les **seuls** écrivains de `facilitator_uuid` sont la prise d'une course par une entreprise (`fleetbase-api.client.ts:1055`) et la remise au pool qui l'efface (`:934`). **Rien ne pose Echango comme facilitateur d'une course du pool.**

  **Deux modèles coexistent donc dans le code, un seul dans la doc** :

  | | chaîne | statut |
  |---|---|---|
  | course confiée à une **entreprise** | 3 maillons, conducteur → entreprise → commerçant | conforme à la doc, **testé** |
  | course du **pool** (cas majoritaire) | **2 maillons**, conducteur → commerçant | modèle d'avant le 31/07 |

  **Ce que cela change concrètement** : sur une course du pool, le conducteur doit 1300 **au commerçant directement**, pas à Echango ; la commission reste **non recouvrable** (aucun flux conducteur → Echango sur lequel compenser) ; et c'est le **commerçant** qui porte le risque, pas nous.

  **Trois autres pièces de la même décision, vérifiées absentes** : les **favoris polymorphes** (`DriverFavourite` seul, clé sur `fleetbaseDriverUuid` — une entreprise ne peut pas être mise en favori) ; le **persona opérateur** (`PartyType = 'driver' | 'fleet' | 'merchant'`, défaut D21) ; et `isPlatform`, qui **existe et fonctionne** mais reste **dormant** — il ne décide de la retenue que si un `FleetAccount` marqué plateforme est facilitateur, ce que rien ne fait automatiquement.

  ⚠️ **La leçon de méthode, et c'est elle qui compte.** J'ai produit un résumé métier depuis les docs alors que **mes propres tests du jour montraient le contraire** — `test-parcours-argent.sh` écrit une dette `driver → merchant` avec `facilitatorId: null`, sous mes yeux. Un titre « ✅ Décision prise » se lit comme « fait » ; il faudrait qu'il se lise comme « à faire ». **Une décision consignée sans son état d'implémentation est une donnée d'appui fausse en puissance** — même famille que la borne du `pubspec` et que le commentaire de `dates.dart`, corrigés le matin même. À l'écriture d'une spec : dire ce qui est décidé **et** ce qui est branché, séparément.

- [x] ~~**Flux d'argent à quatre acteurs — décisions produit à prendre avant tout code**~~ — **CLOS le 03/08/2026** : le registre de caisse est retiré, ces décisions ne conditionnent plus aucun code de ce dépôt. L'analyse reste juste et redevient la spec d'un module externe s'il se construit un jour (`docs/registre_caisse_precis.md` §3). *(Énoncé d'origine :)* `docs/specs_flux_argent_quatre_acteurs.md` (30/07/2026). ⚠️ **Partiellement remplacé par `docs/specs_facilitateur.md`** (ci-dessus), qui tranche ses questions ouvertes et corrige son §3.4 : la base de commission est **déjà** ce que le commerçant paie (`recordEarning` reçoit `meta.price`) — le défaut porte sur le destinataire, pas sur la valeur. L'entreprise de transport qui gère sa propre flotte est le **seul acteur sans place dans le registre de caisse**, bâti sur un couple `driverId`/`merchantId`. Quatre défauts en découlent, dont deux graves : le **plafond de dette borne la mauvaise exposition** (une entreprise de dix conducteurs accumule dix fois le plafond chez le même commerçant sans qu'aucune garde ne se déclenche), et la **commission est assise sur la rémunération du conducteur**, un montant interne à l'entreprise que nous n'aurons jamais — la base doit être ce que le commerçant paie. Antérieur à tout ça : **le commerçant ne pose jamais `facilitator`**, donc une entreprise ne peut recevoir que ce qu'un opérateur lui rattache à la main en console. Recommandation centrale : **la contrepartie financière est l'entreprise quand il y en a une, le transporteur sinon** — ce qui demande de généraliser les trois tables du registre à un couple de parties typées, sans toucher à une seule règle métier, et rend le cas indépendant et le cas entreprise identiques au lieu d'ajouter une branche partout où il est question d'argent. **Trois décisions prises le 30/07/2026, qui ouvrent le développement** : (1) le commerçant choisit **une entreprise ou un transporteur du pool**, au même endroit — donc les **favoris doivent devenir polymorphes** eux aussi, et confier une course à une société ne doit PAS nommer son conducteur à sa place ; (2) une entreprise peut **prendre une course diffusée** et l'attribuer en interne — il faut lui donner l'équivalent d'`acceptOrder()`, et gérer les deux populations qui réclament la même course ; (3) **l'entreprise répond de ses conducteurs**, ce qui rend le modèle tenable : la perte d'un conducteur ne change rien au solde que voit le commerçant, elle bascule sur la chaîne interne où l'entreprise a des moyens que nous n'avons pas. Le client final reste hors plateforme. Restent ouvertes trois questions qui ne bloquent rien, sauf une : **un conducteur peut-il travailler pour deux entreprises** — elle décide si un simple couple de parties suffit.
- [x] ~~**Paiement à la livraison — reste à trancher**~~ — **CLOS le 03/08/2026, et la conclusion est celle que ce texte redoutait**. Il disait déjà : *« une mise en œuvre partielle serait pire que l'absence, un commerçant confierait de l'argent réel à une capacité qui n'existe pas »*. La Voie B a été construite, puis retirée pour cette raison même. Ce qui reste est le geste informationnel qu'il décrivait comme l'apport réel de l'app : **le bon montant au bon moment, et l'écart constaté à la porte plutôt que cinq jours plus tard au dépôt**. *(Énoncé d'origine :)* les points du §9 de `docs/specs_paiement_livraison.md` que l'implémentation n'a délibérément pas préemptés — qui supporte la perte, le montant réel du plafond, le retrait en agence, et la **vérification juridique** sur la détention de fonds pour compte de tiers (la Voie B est conçue pour l'éviter, cela reste à confirmer). : `docs/specs_paiement_livraison.md`. Le sujet n'est pas un champ « montant » mais une **chaîne de garde d'espèces** qui court à contresens du colis, par quelqu'un qui n'est ni l'expéditeur ni le destinataire. Trois modèles observés : transporteur intégré à agences (Yalidine, ZR, Noest en Algérie ; Bosta, Mylerz en Égypte — reversement en 3 à 7 jours, rapprochement manuel à 3-5 % d'erreurs et 15 % de trésorerie en suspens), plateforme à solde coursier (DoorDash — le coursier garde le liquide, déduit de ses gains, plus de courses encaissées si le solde passe négatif), et agrégateur qui ne touche jamais l'argent. **Notre position n'est aucune des trois** : ni agences ni dépôts, transporteurs indépendants, et pas encore de versement sur lequel compenser — mais nous avons les favoris, une relation répétée qui change le profil de risque et fournit l'occasion naturelle de la remise. **Recommandation : Voie B** — le transporteur conserve les espèces, l'application tient le registre de sa dette par commerçant, la remise se fait au prochain enlèvement et se confirme des deux côtés ; Echango ne touche jamais l'argent. Garde-fous logiciels : plafond de dette, courses encaissées réservées aux favoris au démarrage, trace horodatée. **L'apport de l'app** est entièrement informationnel : le bon montant au bon moment, « livré » et « encaissé X » en une seule déclaration prouvée, l'écart constaté à la porte et non cinq jours plus tard au dépôt, la réponse à « combien me doit-on et depuis quand », et le plafond de dette — seul instrument de contrôle disponible sans dépôt physique. **Rien n'est implémenté volontairement** : une mise en œuvre partielle serait pire que l'absence, un commerçant confierait de l'argent réel à une capacité qui n'existe pas. Six points à trancher (§9), dont qui supporte la perte et une **vérification juridique** sur la détention de fonds pour compte de tiers.
- [ ] **P1 restant — relu et corrigé le 31/07/2026** (`docs/rapports_revue_2026-07-28/00_synthese.md`). ⚠️ **Trois des quatre points étaient périmés, et deux étaient devenus faux** — les laisser écrits aurait fait « corriger » ce qui l'est déjà, ce qui est la même faute que décrire une protection qu'on n'a pas. Vérifié point par point dans le code, pas de mémoire :

  - ~~**prix et délai affichés**~~ — **faux depuis longtemps** : `price`, `currency`, `price_source` et `cod_amount` sont dans `META_FIELDS` de `projectOrderForDriver`, chacun sous un commentaire disant explicitement que le transporteur doit les avoir pour décider ; `scheduled_at` est dans `ORDER_FIELDS`.
  - ~~**coordonnées par défaut d'Alger**~~ — **faux depuis le lot carte du 30/07** : `CreateOrderDto` **exige** les quatre coordonnées, le formulaire refuse de soumettre sans les deux points, et une adresse du carnet sans position rend `null` plutôt que `(0,0)`. `_algiers` ne subsiste que comme **position initiale de la caméra** du sélecteur, avec le libellé de l'adresse résolu et affiché avant toute confirmation.
  - ~~**rayon de diffusion**~~ — **arbitré le 02/08/2026, voir la ligne « Le transporteur choisit ce qu'il voit » ci-dessus.** Le constat technique reste juste : `adhoc_distance` (15 km, `ADHOC_RADIUS_METRES`) gouverne les **pings**, tandis que `listOrders` sert les courses libres à l'échelle de l'organisation. Ce que j'appelais un désaccord n'en était pas un : **c'est le transporteur qui choisit sa course**, et la liste n'a pas à trancher à sa place. La suite n'est donc pas d'aligner la liste sur le rayon, mais de donner au transporteur **sa** wilaya et **son** rayon.
  - **mode de dispatch** — toujours ouvert, mais **partiellement tranché** par le mode brouillon/publier du 30/07 : c'est le commerçant qui décide du moment. Reste la question de l'opérateur outillé.

- [ ] Revenir documenter les réponses **avant** de concevoir le connecteur Odoo → Fleetbase (qui vivra dans `echangoorder/backend/addons/echango_order/`, pas dans ce repo).
- [ ] Rouvrir la question de la licence AGPL avec un juriste avant la Phase 3 B2B.

## Repo lié

- [`echangoorder`](https://github.com/ecolealgerienne-ui/echangoorder) — Echango Order (Produit 1). `docs/specs_macro_drive_transport.md` pour la vision macro complète des deux produits.

