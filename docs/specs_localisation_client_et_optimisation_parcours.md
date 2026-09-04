# Specs — Fiche client géolocalisée & optimisation de parcours conducteur

**Statut** : spec, rien d'implémenté. Destiné à être donné tel quel à Claude
Code pour le développement.
**Date** : 04/09/2026.
**Origine** : discussion produit sur le positionnement « dernier kilomètre »
et le multi-arrêt (voir `docs/comparaison_marche_commercant.md`,
`docs/status_v1.md`) — deux fonctionnalités concrètes en sont sorties et sont
spécifiées ici. Le reste de la discussion (multi-arrêt, import en lot) est
noté en §3 mais **délibérément pas spécifié** : il reste bloqué par des
décisions produit non prises.

**Un point de positionnement, pour mémoire, qui n'est pas une fonctionnalité
mais qui a conditionné la suite** : un transporteur inter-wilayas qui
redistribue en dernier kilomètre est, du point de vue de la plateforme, un
**commerçant** — `MerchantAccount` ne porte aujourd'hui aucune donnée propre à
un secteur d'activité, le rôle est transactionnel (qui crée et paie une
commande), pas une catégorie d'entreprise. **Aucun nouveau persona, aucune
nouvelle route d'authentification** à prévoir pour ce cas d'usage.

---

## 1. Fiche client géolocalisée + lien de localisation

### 1.1 Problème

Les adresses saisies à la main sont peu fiables en Algérie. Le commerçant a
besoin de demander au client sa position exacte sans lui faire taper une
adresse, en utilisant un canal qu'il possède déjà (SMS, WhatsApp, Messenger…).

### 1.2 Principe général

1. Le commerçant saisit les informations du client (nom, téléphone) pendant
   la composition d'une commande.
2. Il génère un **lien de localisation**, valable **10 minutes**.
3. Il l'envoie lui-même via le **partage natif de son téléphone** — la
   plateforme n'envoie rien elle-même. **Aucune intégration SMS/WhatsApp
   n'est nécessaire ni prévue** : c'est ce qui rend ce lot petit plutôt que
   de nécessiter un compte opérateur télécom.
4. Le client ouvre le lien sur une **page web publique**, générique
   (branding Echango uniquement), sans compte à créer, autorise la
   géolocalisation de son navigateur, et sa position est transmise au
   serveur.
5. Le résultat est rattaché à une **fiche client**, jamais à une commande.

### 1.3 La fiche client — nouvelle notion dans le modèle

⚠️ **Aucune entité « client » n'existe aujourd'hui dans le dépôt** —
`dropoffContactName`/`dropoffContactPhone` sont du texte libre ressaisi à
chaque commande. Cette fiche est une table entièrement nouvelle, côté BFF
uniquement.

| propriété | valeur |
|---|---|
| identifiant | numéro de téléphone, **normalisé au format `+213…` imposé** |
| portée | **plateforme entière** — un client est reconnu par tout commerçant du réseau, pas seulement celui qui a envoyé le lien |
| contenu | nom, adresse (texte), position GPS (latitude/longitude), date de dernière mise à jour |
| création | au **premier partage de position réussi** pour ce numéro — jamais de fiche vide créée par la simple saisie d'un numéro |
| auto-remplissage | dès qu'un commerçant tape un numéro déjà connu, nom/adresse/GPS se pré-remplissent automatiquement depuis la fiche |
| expiration du point GPS | **aucune** — il reste valable indéfiniment, jusqu'à modification volontaire |
| lien de mise à jour | **toujours proposable**, même quand une position existe déjà |

⚠️ **Pourquoi cette table est légitimement côté BFF, et pas une exception à
la règle 1 de `CLAUDE.md` (« Fleetbase fait foi »)** : Fleetbase n'a
structurellement aucun équivalent — son `Contact`/`Customer` est scopé par
`Vendor`/commande, jamais un répertoire transversal à tout le réseau, indexé
par téléphone. Ce n'est pas une donnée qu'on duplique depuis Fleetbase,
c'est une donnée que Fleetbase ne peut pas porter par construction.

### 1.4 Deux mécanismes de résolution de conflit — à ne pas confondre

Ce point a été source d'ambiguïté pendant la discussion et est clarifié ici
explicitement (voir §4.2, ce qu'a trouvé la vérification) :

- **Nouvelle position soumise par le client (via le lien)** : si une
  position existait déjà sur la fiche, elle **n'est jamais écrasée
  silencieusement**. Le commerçant qui a généré le lien voit l'ancienne et
  la nouvelle valeur et **confirme explicitement** avant que le remplacement
  n'ait lieu. C'est une porte humaine, posée avant l'écriture.
- **Deux commerçants qui modifient la même fiche en même temps** (deux
  écritures concurrentes, y compris deux confirmations quasi simultanées) :
  **le dernier écrivain gagne**, sans verrou. C'est l'arbitrage technique
  bas niveau entre écritures concurrentes, pas une alternative à la
  confirmation — les deux mécanismes s'appliquent à des moments différents
  de la même opération.

### 1.5 Utilisation des coordonnées

- **GPS et adresse texte coexistent toujours** à l'affichage — aucun ne
  remplace l'autre.
- Si un GPS existe, il est **utilisé en priorité** pour la navigation.
- Les coordonnées doivent voyager **jusqu'à l'écran de navigation du
  conducteur** — ce n'est pas seulement un confort de saisie côté commerçant,
  c'est une donnée d'exécution.

### 1.6 Nouvelle capacité d'API à prévoir

⚠️ **Aucune route de modification d'une commande existante n'existe
aujourd'hui** (`backend/bff/src/commercant/commercant.controller.ts` —
uniquement `annuler`, `publier`, `rediriger`). Pouvoir mettre à jour le GPS
d'une commande déjà créée, à partir d'une fiche client mise à jour, est donc
une **capacité entièrement nouvelle** — à concevoir avec la même discipline
d'appartenance que le reste de l'API (règle 12 de `CLAUDE.md` : vérifier que
la commande appartient bien au commerçant qui la modifie, jamais seulement
qu'il est authentifié).

### 1.7 Confidentialité — décision à écrire avant le développement

⚠️ **Portée « plateforme entière » veut dire qu'un commerçant B peut lire une
position que le client a partagée en réponse au lien d'un commerçant A**,
sans que ce dernier en soit informé. Ce n'est pas noté comme un défaut —
c'est un choix produit assumé pour maximiser la réutilisation — mais **le
consentement du client à cette réutilisation doit être visible sur la page
publique** avant la V1 (formulation à écrire : « votre position sera
utilisée pour vos livraisons sur le réseau Echango », pas seulement « pour
cette commande »). Ne pas laisser cette mention de côté au moment du
développement.

### 1.8 La page publique — ce qu'elle montre et ne montre pas

- **Montre** : branding générique Echango uniquement.
- **Ne montre jamais** : nom du commerçant, contenu de la commande, ou toute
  autre donnée métier — c'est ce qui rend la page sûre à partager largement.
- **États à couvrir explicitement**, chacun avec son message dédié — jamais
  un échec silencieux (règle 10 de `CLAUDE.md`) :
  - lien valide, en attente d'action du client ;
  - lien expiré (passé les 10 minutes) ;
  - lien déjà utilisé ;
  - géolocalisation refusée par le client (permission navigateur refusée).

### 1.9 Précision GPS

Décision explicite : **aucun seuil de précision minimal côté serveur.** La
précision renvoyée par le navigateur du client dépend de son téléphone et de
son environnement (intérieur, GPS désactivé) — c'est un problème du terminal
du client, assumé comme tel, pas une garde à construire.

### 1.10 Ce qui reste à trancher avant le développement

- **Format du champ adresse sur la fiche** : texte libre, ou structuré
  (commune/quartier/wilaya, comme `CreateOrderDto` le fait déjà pour les
  commandes) ? **Recommandation** : structuré, par cohérence avec
  `pickupCity`/`pickupProvince`/`pickupNeighborhood` déjà en place — le même
  géocodage inverse alimenterait les mêmes champs partout dans le dépôt.
- **Formulation exacte de la mention de consentement** (§1.7).
- **Débit maximal de génération de liens** par commerçant (anti-abus) — à
  poser en `@Throttle`, dans l'esprit de la règle 12 : toute route publique
  ou sensible porte son propre plafond, justifié par écrit.

### 1.11 Critères de vérification recommandés (style du dépôt)

À la manière des scénarios existants (`scripts/test-*.sh`), prévoir au
minimum :
- un lien généré, utilisé une fois, refusé à la seconde tentative ;
- un lien expiré (au-delà de 10 minutes) refusé ;
- une fiche client pré-remplit bien nom/adresse/GPS à la frappe du même
  numéro par un **second** commerçant (preuve de la portée plateforme) ;
- une nouvelle position soumise sur une fiche déjà pourvue **n'écrase rien**
  tant que le commerçant n'a pas confirmé (témoin négatif) ;
- la page publique ne renvoie **aucune** donnée commerçant ou commande
  (frontière de projection, même discipline que
  `scripts/test-frontiere-projection.sh`).

---

## 2. Optimisation de parcours pour le conducteur

### 2.1 Objectif

Depuis une course déjà acceptée, permettre au conducteur de découvrir, **sur
demande**, d'autres courses du pool à proximité de sa dépose, pour enchaîner
et augmenter ses gains — sans changer le modèle de commande.

### 2.2 Ce que ce n'est pas

⚠️ **Ce n'est pas une optimisation de tournée façon flotte dédiée**
(Onfleet, Circuit). `docs/comparaison_marche_commercant.md` §5 écarte
aujourd'hui ce type de fonctionnalité comme hors modèle, au motif qu'une
flotte dédiée planifie sa journée à l'avance quand notre modèle diffuse à un
réseau. **Ce n'est pas contradictoire** : la suggestion spécifiée ici est
déclenchée par le conducteur lui-même, à la volée, sur une course qu'il
tient déjà, et **ne réserve rien à l'avance** — elle reste un pool
mutualisé de bout en bout. Ce document §5 sera à nuancer/corriger en même
temps que l'implémentation, pour ne pas laisser deux sources se contredire.

Ce n'est pas non plus le multi-arrêt (waypoints Fleetbase, une commande à
plusieurs points) — sujet distinct, hors périmètre de ce document, voir §3.

### 2.3 Mécanique

| paramètre | décision |
|---|---|
| déclenchement | bouton « Optimiser », explicite — jamais automatique |
| condition | le conducteur doit **déjà tenir une course acceptée** |
| référence géographique | le point de **dépose** de la course déjà tenue — **pas** la position live du conducteur |
| rayon | **fixe**, aligné sur le rayon de zone par défaut existant (15 km) — non configurable en V1 |
| tri des candidats | **uniquement par proximité** — pas de score combiné prix/distance en V1 |
| exclusion | les courses **ciblées** à un favori nommé (`targetFavouriteUuid` posé) ne doivent **jamais** apparaître |

### 2.4 Le gain affiché

Simple **somme des `price`** déjà proposés par les commerçants sur chaque
course suggérée — aucun nouveau calcul de tarification, aucune remise ni
majoration de groupage. Ce choix évite délibérément de rouvrir la question
de tarification non tranchée (priorité 3 du plan d'action,
`docs/specs_echango_delivery.md` §9) : la fonctionnalité ne fait qu'additionner
des montants déjà connus.

### 2.5 Ce qui se réutilise, sans rien construire de nouveau

- **`distanceKm()`** (haversine, `backend/bff/src/common/orders/driver-zone.ts:149`)
  pour le filtre de proximité — suffisant à l'échelle visée (le commentaire
  du fichier le dit déjà : « à la dizaine de kilomètres près, pas un
  itinéraire calculé »). **Aucun moteur de routage** (OSRM/Valhalla) requis
  pour cette version.
- Le mécanisme d'acceptation et son verrou (`ResourceLockService`) : une
  suggestion **n'est pas une réservation**. Si un autre conducteur prend la
  course entre la suggestion et le clic, le refus attendu
  (`order.already_taken`) s'applique sans aucun changement.
- Le filtre de réclamabilité déjà utilisé pour le pool, la zone/wilaya du
  conducteur, la catégorie de véhicule — tous existants.

### 2.6 Un point trouvé en vérifiant (voir §4.3) : l'exclusion des courses ciblées n'exige probablement aucun nouveau filtre

Si le point d'entrée de cette fonctionnalité puise ses candidats dans la
**même requête** que celle qui alimente déjà l'écran « Opportunités » du
pool, l'exclusion des courses ciblées est **déjà garantie** — elles n'y
figurent jamais par construction. Le risque à éviter est inverse :
construire par erreur une requête plus large (« toutes les commandes
actives ») qui les réintroduirait. **À couvrir par un scénario dédié**, pas
seulement supposé correct.

### 2.7 Ce qui reste à trancher avant le développement

- Comportement si **aucune** course compatible n'est trouvée dans le rayon —
  un message explicite (« rien à proximité »), jamais une liste vide sans
  explication (règle 10 de `CLAUDE.md`).
- Nombre maximal de suggestions affichées à l'écran.

### 2.8 Critères de vérification recommandés

- une course **ciblée** à un favori n'apparaît **jamais** dans les
  suggestions, même en zone et rayon compatibles (témoin négatif) ;
- une course **hors rayon** de la dépose n'apparaît pas, une course
  **dans** le rayon apparaît (témoin positif/négatif, comme
  `test-filtre-wilaya.sh` le fait déjà pour la zone) ;
- une suggestion acceptée en même temps par deux conducteurs ne produit
  qu'un seul gagnant — même verrou que l'acceptation classique, à rejouer
  sur ce chemin plutôt que supposé hérité.

---

## 3. Hors périmètre de ce document — discuté cette session, non tranché

Pour que rien de la discussion ne se perde, sans le spécifier ici :

- **Multi-arrêt / multi-enlèvement** (waypoints Fleetbase). Périmètre
  technique déjà identifié (DTO, client Fleetbase, trois projections, filtre
  de zone, écrans) mais **bloqué par deux décisions produit non prises** :
  la répartition du prix sur plusieurs arrêts, et la garde des espèces en
  cas d'encaissement à plusieurs portes (le retrait du registre de caisse du
  03/08/2026 aggrave ce second point). **Ne pas commencer avant réponse à
  ces deux questions** — recommencer une fois la règle tranchée coûterait
  plus cher que d'attendre.
- **Import de commandes en lot** (CSV/liste), pour un expéditeur à fort
  volume. Indépendant du reste, aucun blocage produit identifié — candidat
  à spécifier séparément si prioritaire.

---

## 4. Vérification de ces specs

Passe de relecture volontairement critique — l'objectif est de trouver ce
qui ne tient pas, pas de confirmer que tout va bien.

### 4.1 Cohérence avec les règles de développement du dépôt (`CLAUDE.md`)

| règle | contrôle | verdict |
|---|---|---|
| 1 — Fleetbase fait foi | la fiche client est-elle une duplication illégitime ? | non — aucun équivalent Fleetbase possible, voir §1.3 |
| 4 — pas de chaîne en dur | les nouveaux refus (lien expiré, déjà utilisé, géoloc refusée) doivent passer par le registre de codes | à faire à l'implémentation — noté en §1.8 |
| 10 — pas de valeur par défaut | l'état « en attente de confirmation » doit être un état explicite, pas une absence masquée | couvert par §1.4 (porte humaine avant écriture) |
| 12 — frontière fermée par défaut, publique = décision | les deux nouvelles routes publiques (servir le lien, recevoir la position) sont-elles justifiées et throttlées ? | à écrire à l'implémentation, noté en §1.10 |
| 13 — DTO décoré | la soumission de coordonnées (lat/lng) doit passer par une classe décorée, jamais un type en ligne | à rappeler à l'implémentation, pas encore écrit ici — **ajouté ci-dessous** |

⚠️ **Point ajouté par cette vérification, absent des échanges précédents** :
le DTO de soumission publique (`{ lat, lng }`) doit être une classe décorée
(`@IsLatitude()`, `@IsLongitude()`), pas un type en ligne — sans quoi la
règle 13 est violée dès le premier jour sur une route qui, étant publique,
est la plus exposée du lot.

### 4.2 Ambiguïté trouvée et résolue : confirmation vs dernier écrivain

Les deux règles — « confirmation avant écrasement » (§1.4) et « dernier
écrivain gagne » (§1.4) — semblaient se contredire en relisant l'échange :
la première dit qu'une écriture attend une validation humaine, la seconde
qu'aucun verrou n'arbitre les écritures concurrentes. **Elles ne portent pas
sur le même moment** : la confirmation est un geste humain qui précède
l'écriture (spécifique à la soumission d'une position via le lien) ; le
dernier écrivain gagne est l'arbitrage technique si deux écritures
(confirmations ou modifications directes) arrivent presque en même temps.
Reformulé explicitement en §1.4 pour qu'un lecteur pressé ne les confonde
pas à l'implémentation.

### 4.3 Simplification trouvée : l'exclusion des courses ciblées (§2.6)

En relisant la mécanique du pool, l'exclusion demandée pour les suggestions
(§2.3) est probablement déjà acquise **si** l'implémentation part de la même
requête que l'écran Opportunités existant, plutôt que d'écrire un nouveau
filtre parallèle qui pourrait diverger (le genre de duplication que la
règle 5 de `CLAUDE.md` interdit explicitement). Ajouté en §2.6 comme
recommandation, avec le risque inverse nommé.

### 4.4 Ce qui a été vérifié et n'a rien montré d'anormal

- Aucune des deux fonctionnalités ne rouvre la question de tarification
  bloquante (§2.4 le dit explicitement pour l'optimisation ; la fiche
  client ne touche à aucun montant).
- Aucune des deux ne nécessite de transaction entre systèmes au sens de la
  règle 2 — la fiche client est purement Postgres ; la mise à jour du GPS
  d'une commande existante (§1.6) touchera Fleetbase et devra nommer sa
  fenêtre d'échec le moment venu, mais ce n'est pas un défaut de cette
  spec, c'est un rappel pour l'implémentation.
- Le positionnement produit de l'optimisation (§2.2) a été confronté au
  document existant qui semblait s'y opposer, et la contradiction a été
  explicitement désamorcée plutôt que laissée pour que quelqu'un la
  découvre plus tard.

### 4.5 Ce qui reste un point d'attention, non résolu par cette vérification

- Le consentement du client (§1.7) et le format de l'adresse (§1.10) restent
  des décisions produit ouvertes, pas des oublis de cette relecture — ils
  sont portés tels quels, volontairement, pour que Claude Code les pose en
  question avant d'écrire le code plutôt que de trancher à sa place.
