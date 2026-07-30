# Interface commerçant — comparaison avec le marché (29 juillet 2026)

## 1. Méthode, et ce qu'elle vaut

Comparaison de **notre persona commerçant** (module `commercant` du BFF + `echango_delivery/lib/screens/commercant/`) avec les plateformes de livraison du dernier kilomètre existantes.

**Ce que j'ai fait** : lecture exhaustive de notre code — endpoints, modèles, écrans, ce qui est réellement branché par opposition à ce qui est déclaré ; puis lecture de la documentation publique et des pages produit des comparables.

**Ce que je n'ai pas fait, et qui limite la portée** : je n'ai utilisé aucune de ces applications. Je décris donc ce que leurs éditeurs *documentent*, pas ce qu'on ressent en s'en servant. Sur les fonctionnalités structurantes (devis avant commande, suivi cartographique, preuve de livraison) l'écart est net et documenté ; sur l'ergonomie fine, mes remarques valent ce que vaut une lecture de documentation.

## 2. Les comparables, et pourquoi ceux-là

Trois familles, parce qu'aucune ne recouvre exactement notre position.

| Famille | Exemples | Ce qu'ils partagent avec nous | Ce qui diffère |
|---|---|---|---|
| **Réseau de coursiers à la demande** | Uber Direct, Stuart | Le commerçant ne possède pas de flotte : il commande une course sur un pool mutualisé. **C'est notre modèle exact.** | Ils fixent le prix, possèdent le réseau, opèrent à l'échelle continentale |
| **Logiciel de dispatch pour flotte propre** | Onfleet, Shipday | La mécanique — commandes, assignation, suivi, preuve | Le client *a* ses livreurs. Pas d'effet réseau, pas de marché à équilibrer |
| **Super-app locale** | Yassir Express, Temtem One (Algérie) | Le marché réel, ses usages de paiement, ses attentes | Verticalement intégrées (restauration, courses), le commerçant y est un catalogue plus qu'un donneur d'ordre |

**Le comparable de référence est Uber Direct** : même proposition — « je n'ai pas de livreur, envoyez-m'en un » — et documentation publique détaillée. Stuart le confirme sur le marché européen.

## 3. Ce qui est à parité, ou meilleur

À ne pas perdre de vue en lisant la suite : le socle est là, et deux choix nous distinguent favorablement.

**À parité.** Création de course avec enlèvement et livraison géolocalisés, carnet d'adresses, choix du véhicule, enlèvement programmé, preuve de livraison exigible, instructions au transporteur, suivi par statut, annulation, historique, duplication d'une commande passée.

**Meilleur que le marché — les transporteurs favoris avec repli automatique.** Ni Uber Direct ni Stuart ne le proposent : leur pool est anonyme par construction. Or un fleuriste qui livre les mêmes quartiers veut le coursier qui connaît le code de l'immeuble. Notre mécanisme sollicite le favori et **retombe seul sur le réseau** s'il n'est pas disponible — la préférence sans la perte de liquidité. C'est un vrai différenciateur pour du commerce de proximité, et il est déjà construit.

**Meilleur — le refus motivé, avec capture des entrées tarifaires.** Uber n'a pas besoin de ça : il connaît son barème. Nous devons le découvrir, et chaque refus dit « ce trajet ne vaut pas ce prix » sur une course réelle. Cet actif s'accumule tout seul dès le premier jour du pilote.

## 4. Les écarts qui comptent

Classés par ce qu'ils coûtent, pas par difficulté.

### 4.1 🔴 Le commerçant ne sait pas ce que ça va coûter

**Le marché.** Uber Direct impose un ordre : `createQuote()` renvoie **frais + durée + heure d'arrivée estimée**, puis `createDelivery()` confirme sur ce devis. Le commerçant voit le prix et l'heure *avant* de s'engager. Stuart affiche un tarif à la course.

**Nous.** L'inverse exact : le commerçant **propose** un montant, sans savoir ce qu'un transporteur acceptera. S'il vise trop bas, personne ne prend et il ne sait pas pourquoi. S'il vise trop haut, il paie sa méconnaissance.

**Pourquoi c'est le n°1.** Un commerçant ne peut pas répercuter sur son client un coût qu'il ignore, ni décider si la livraison vaut le coup. C'est la question qu'il se pose en premier, et notre écran est le seul du marché à ne pas y répondre.

**Où on en est.** La couture est posée — `POST /commercant/devis`, appelé à chaque changement de paramètre, l'écran bascule seul de la saisie au tarif affiché quand `source == 'computed'`. `PricingService.computeQuote()` est un talon qui renvoie `null`. **Il ne manque que la formule**, qui est une décision produit (Priorité 3), pas du développement.

### 4.2 🔴 Aucun suivi cartographique, aucune heure d'arrivée

**Le marché.** Universel, sans exception : Uber Direct renvoie un `tracking_url`, Stuart annonce des ETA dynamiques, Onfleet vend des « predicted ETA ». C'est le cœur de ce qu'on achète.

**Nous.** Un statut en toutes lettres (« En cours », « Recherche transporteur »). Ni carte, ni position, ni estimation d'arrivée.

**Et c'est le motif récurrent du projet, une fois de plus** : la donnée **existe déjà côté serveur**. Le transporteur remonte sa position en continu, le BFF la miroite dans `DriverAccount.lastLatitude/lastLongitude/lastPositionAt`, et le module flotte la sert sur une carte. Le module commerçant ne l'expose simplement pas. L'app a même `flutter_map` intégré, avec un écran de carte fonctionnel.

**Coût réel** : un endpoint qui renvoie la dernière position du transporteur assigné à *cette* commande (le contrôle d'appartenance existe déjà via `resolveOwnedOrder()`), et une carte réutilisant `MapPickerScreen`. L'ETA est plus lourde — elle demande un calcul d'itinéraire, donc OSRM, aujourd'hui non auto-hébergé (`specs_echango_delivery.md` §3.3). **Une position sans ETA vaut déjà largement mieux qu'un statut textuel** : ne pas attendre OSRM pour livrer la carte.

### 4.3 🔴 Le destinataire final n'existe pas dans le produit

**Le marché.** Onfleet envoie des SMS de marque à chaque étape et fournit un lien de suivi que le destinataire ouvre sans compte ; Stuart propose un suivi en marque blanche ; Uber Direct expose un `tracking_url` partageable.

**Nous.** Le destinataire ne reçoit rien. Son téléphone est saisi — et jusqu'à hier il était même **jeté à la création**. Le commerçant sert de standard téléphonique entre son client et un transporteur qu'il ne voit pas.

**Pourquoi ça compte plus qu'il n'y paraît.** Notre premier motif d'échec de livraison est `client_absent`. Un destinataire prévenu est un destinataire présent : c'est la fonctionnalité qui réduit mécaniquement le taux d'échec, donc les courses perdues et les litiges. Et c'est l'argument de vente auprès du commerçant — « votre client voit sa livraison arriver » —, pas un confort.

**Ce qu'il faut trancher avant de construire** : envoi par SMS (coût par message, passerelle à contracter en Algérie) ou lien partagé par le commerçant via WhatsApp (gratuit, demande un geste). Le second est le bon départ : une page publique de suivi, adressée par un jeton non devinable, sans compte. Le SMS s'ajoutera dessus.

### 4.4 🔴 La preuve de livraison n'atteint pas celui qui en a besoin

**Le marché.** Uber Direct conserve la photo, accessible au tableau de bord 7 jours et par API 30 jours. Stuart propose code PIN ou photo. Shipday et Onfleet capturent photo et signature.

**Nous.** Le transporteur photographie, Fleetbase stocke, le BFF relaie l'image de façon authentifiée — **au transporteur seul**. Le commerçant, qui est pourtant celui qui devra trancher un litige avec son client, ne voit rien. Idem pour l'échec : il reçoit « Échec de livraison : client absent » et rien d'autre — ni photo, ni précision, ni trace dans la commande.

C'est le même défaut que celui corrigé le 28/07 côté transporteur, resté en place côté commerçant.

**⚠️ Défaut de sécurité constaté en passant.** `proof_url` figure dans `ORDER_FIELDS`, donc il **sort vers le commerçant** — c'est l'URL Fleetbase brute, qui n'est protégée par aucune authentification. Personne ne la lit aujourd'hui côté application, mais elle transite. Toute la discipline mise en place côté transporteur (§11 du journal : jamais l'URL Fleetbase, toujours un chemin BFF authentifié) est contournée ici par un champ oublié dans une liste d'autorisation. **À corriger indépendamment du reste** : retirer `proof_url` de la projection, et servir la preuve au commerçant par une route dédiée.

### 4.5 🔴 Le paiement à la livraison n'existe pas — et c'est l'écart local le plus lourd

**Le marché local.** Le paiement à la livraison domine le commerce en ligne du Maghreb et du Moyen-Orient — de l'ordre de 65 à 70 % des commandes en Égypte, avec des ordres de grandeur comparables dans la région. Les plateformes qui y opèrent en font une fonction de premier plan : encaissement par le livreur, rapprochement, reversement au commerçant. Les écarts de caisse non contrôlés y sont chiffrés à 2–5 % des sommes collectées, ce qui dit assez que le sujet est un système et non une case à cocher.

**Nous.** Rien. Ni champ « montant à encaisser », ni suivi de ce que le transporteur détient, ni reversement. Notre modèle implicite est celui d'une course déjà payée — c'est le modèle Uber Direct, transposé d'un marché où la carte bancaire est la norme.

**Pourquoi je le classe en rouge malgré son absence de tout comparable occidental.** Un commerçant algérien qui vend en ligne encaisse à la livraison. Sans ce mécanisme, on ne s'adresse qu'aux commerces déjà payés — boulangerie, pharmacie sur ordonnance réglée — et on exclut le commerce en ligne, qui est précisément le segment en croissance. C'est une décision produit avant d'être du code : **veut-on porter l'argent d'autrui ?** Cela engage une responsabilité, sans doute une assurance, et une réglementation à vérifier. À trancher explicitement, pas à laisser tomber par omission.

### 4.6 🟠 La liste des commandes s'arrête à 25, sans le dire

`GET /commercant/commandes` pagine (`page`, `limit`, défaut 25), et l'application **n'envoie aucun paramètre et n'a pas de « charger plus »**. Un commerçant actif dépasse 25 livraisons en une semaine : les plus anciennes deviennent alors inaccessibles, silencieusement.

C'est exactement le défaut corrigé côté transporteur le 28/07 (le plafond de 100 commandes) — même nature, autre persona. Aucune recherche ni filtre non plus, alors que le serveur accepte déjà un filtre par statut.

### 4.7 🟠 Le téléphone du transporteur est envoyé, jamais affiché

Le BFF projette `driver_assigned: { name, phone, photo_url }`. `MerchantOrder` ne lit que le nom ; l'écran n'affiche que le nom. Un commerçant qui veut savoir où en est son coursier n'a aucun moyen de le joindre — alors que le numéro est déjà sur son téléphone, dans la réponse HTTP.

Le motif du projet, dans sa forme la plus pure : **le serveur sait, l'app ignore**. Correction : quelques lignes.

### 4.8 🟠 Le colis tient en une ligne de texte

**Le marché.** Uber Direct transporte un *manifest* : articles, dimensions, valeur, plus des exigences de vérification (signature, pièce d'identité, code PIN, code-barres).

**Nous.** Un champ libre « Contenu ». Le DTO accepte pourtant déjà `quantity`, `weight` et `fragile` par article — **le formulaire n'en envoie rien** (`quantity: 1` en dur, jamais de poids ni de fragilité). Le transporteur ne peut donc pas juger si sa moto suffit, alors que c'est précisément ce qui fonde son refus pour `colis_inadapte`.

Écart faible en coût, direct en effet : exposer poids et fragilité, que le contrat serveur accepte déjà.

### 4.9 🟠 Aucune trace financière

Le modèle `Commission` existe dans le schéma depuis l'origine et **n'est écrit nulle part**. Pas de relevé, pas de facture, pas de total mensuel. Un commerçant ne peut pas répondre à « combien m'a coûté la livraison ce mois-ci ? », question qu'il se posera au premier bilan.

À relier à §4.1 : sans barème, il n'y a de toute façon rien à facturer de façon fiable. L'ordre est donc contraint — barème d'abord, relevés ensuite.

### 4.10 🟡 Pas de notation du transporteur

Onfleet permet au client de noter la livraison. Dans un réseau mutualisé, la notation n'est pas un ornement : c'est **le seul mécanisme de qualité disponible**, faute de lien hiérarchique avec des transporteurs indépendants. C'est aussi ce qui alimenterait un classement d'attribution plus fin que « le premier qui accepte ».

Non urgent au pilote — quelques transporteurs, tout le monde se connaît — mais structurant dès l'ouverture B2B (Phase 3).

### 4.11 🟡 Carnet d'adresses en écriture seule

Création uniquement : ni modification, ni suppression. Une adresse mal saisie reste à vie, et le carnet se remplit de doublons — d'autant que rien ne détecte les doublons à la création.

**Au passage** : `getAddresses()` renvoie les objets `Place` Fleetbase **bruts**, sans projection. C'est un reliquat de la fuite M10 corrigée partout ailleurs le 28/07 ; ce qui sort est décidé par Fleetbase et changera à sa prochaine mise à jour.

### 4.12 🟡 Écarts assumables au pilote

- **Annulation sans motif** ni règle de facturation — les plateformes facturent une course annulée après affectation. À trancher avec les règles métier (Priorité 3).
- **Pas de multi-arrêts.** Fleetbase gère les `waypoints` nativement ; on ne les utilise pas. Utile pour une tournée de plusieurs clients, hors du besoin « une course, un point ».
- **Pas de créneau de livraison.** Fleetbase ignore silencieusement `time_window_start/end` (§7 des specs) : la fonctionnalité serait à construire entièrement.
- **Aucune intégration e-commerce.** Uber Direct, Stuart et Shipday se branchent sur Shopify et WooCommerce. Notre équivalent est le connecteur Odoo pour Echango Order, prévu hors de ce dépôt.
- **Pas d'import en lot** (CSV) ni de commandes récurrentes. La duplication livrée hier couvre le besoin le plus fréquent.

## 5. Ce qu'il ne faut pas copier

Autant que les écarts, ce qui n'en est pas :

- **L'optimisation de tournée** (Onfleet, Shipday, Circuit). Elle sert une flotte dédiée qui planifie sa journée. Notre modèle est une course diffusée à un réseau : il n'y a pas de tournée à optimiser. Ce serait construire un produit différent.
- **La lecture de codes-barres.** Elle sert un entrepôt et un colis référencé. Une boulangerie n'étiquette pas ses gâteaux.
- **Les enchères entre transporteurs.** Voir `specs_echango_delivery.md` §6.1 : la pression à la baisse sur les revenus vide le réseau de ses transporteurs, qui sont la ressource rare.
- **Le modèle tarifaire d'Onfleet** (599 $/mois pour 2 500 courses) : un abonnement pour piloter ses propres livreurs. Sans rapport avec un commerçant qui commande cinq courses par jour.

## 6. Ce que je ferais, dans cet ordre

L'ordre suit une seule règle : **d'abord ce qui manque pour qu'un commerçant décide, ensuite ce qui manque pour qu'il ait confiance.**

| # | Quoi | Pourquoi ici | Coût |
|---|---|---|---|
| 1 | **Retirer `proof_url` de la projection commerçant** | Fuite d'une URL non authentifiée. Indépendant de tout le reste. | minutes |
| 2 | **Pagination + recherche dans la liste** | Défaut silencieux : les commandes anciennes deviennent inaccessibles sans que rien ne le signale | heures |
| 3 | **Téléphone du transporteur affiché** | La donnée est déjà sur le téléphone du commerçant | minutes |
| 4 | **Suivi cartographique** (position, sans ETA) | Le manque le plus visible ; la donnée et la carte existent déjà | 1 journée |
| 5 | **Preuve et échec visibles au commerçant** | Il est celui qui arbitre le litige avec son client | 1 journée |
| 6 | **Barème** (`computeQuote()`) | L'écart n°1 du marché, mais c'est une **décision produit** — pas du code. Les refus motivés accumuleront la matière d'ici là | décision |
| 7 | **Page de suivi pour le destinataire** | Réduit mécaniquement les échecs `client_absent`, et c'est l'argument de vente | 2–3 jours |
| 8 | **Paiement à la livraison** | Le plus lourd, et le plus discriminant sur le marché local. À trancher explicitement avant de chiffrer | décision d'abord |

Les points 1 à 5 sont du rattrapage : dans les cinq cas, la capacité existe déjà côté serveur et n'est pas servie au commerçant. Les points 6 à 8 sont des décisions produit qui engagent le modèle d'affaires — elles ne se règlent pas en écrivant du code.

---

## Sources

- [Uber Direct — présentation marchands](https://merchants.uber.com/uber-direct.html)
- [Uber Direct — vue d'ensemble des API](https://developer.uber.com/docs/deliveries/overview)
- [Uber Direct — preuve de livraison](https://developer.uber.com/docs/deliveries/guides/proof-of-delivery)
- [Uber Direct — SDK officiel](https://github.com/uber/uber-direct-sdk)
- [Uber Direct — présentation Shopify](https://www.shopify.com/ie/blog/what-is-uber-direct)
- [Stuart — plateforme du dernier kilomètre](https://stuart.com/)
- [Stuart — suivi de livraison](https://help.stuart.com/en/articles/7038810-tracking-your-delivery)
- [Onfleet — notifications, chat et SMS](https://onfleet.com/chat-and-sms)
- [Onfleet — visibilité et suivi](https://onfleet.com/visibility-and-tracking)
- [Onfleet — notifications basées sur l'ETA prédite](https://onfleet.com/blog/scale-feature-spotlight-downstream-eta-notifications/)
- [Shipday — classement des logiciels du dernier kilomètre 2026](https://www.shipday.com/post/best-last-mile-delivery-software-2026-ranking)
- [Paiement à la livraison — gestion et contrôle](https://roboost.ai/blog/cash-on-delivery-management-how-to-track-control-and-secure-cod-operations)
- [Paiement à la livraison — défis du dernier kilomètre MENA](https://codrocket.com/blog/last-mile-delivery-challenges-mena-solutions)
- [Yassir — espace partenaire Algérie](https://yassir.com/partenaire)
- [temtem One](https://temtemone.com/)
