# Rapport agent — Architecture

*Produit par un agent spécialisé architecture solution (subagent "Plan"), le 26 juillet 2026, en relecture de `CLAUDE.md` et `docs/journal_exploration_fleetbase.md`, avec vérification croisée du code source public de Fleetbase et une étude complémentaire sur FlutterFlow demandée en cours de mission. Reproduit ici intégralement pour traçabilité — la synthèse priorisée est dans `docs/specs_echango_delivery.md`.*

---

## 0. Méthode et sources

Lecture de `CLAUDE.md` et `docs/journal_exploration_fleetbase.md` en entier, puis vérification dans le code source public de Fleetbase (`fleetbase/fleetops`, `fleetbase/fleetops-data`, `fleetbase/customer-portal`, `fleetbase/ledger`, `fleetbase/fleetbase`, `fleetbase/storefront`, `fleetbase/ember-core`) des trois zones d'ombre demandées, plus une découverte non anticipée : le package officiel `fleetbase/customer-portal`. Recherche web complémentaire sur les capacités réelles de FlutterFlow (API REST, temps réel/WebSocket), ajoutée en cours de mission à la demande de l'utilisateur. Aucun fichier du repo n'a été modifié.

---

## 1. Schéma d'ensemble

```
                         ┌───────────────────────────────────────────┐
                         │   Organization Fleetbase "Echango Delivery" │
                         │   (self-hosted : Laravel/MySQL/Redis/       │
                         │    SocketCluster)                           │
                         │                                             │
                         │  Extensions installées : FleetOps           │
                         │  Extensions à évaluer : customer-portal,    │
                         │                          ledger             │
                         │  Extension écartée : Storefront              │
                         └───────────────────────────────────────────┘
                                 ▲            ▲             ▲
                    clé API      │            │             │  webhook / OSRM / Valhalla
                 service unique  │            │             │  (calcul d'itinéraire)
                                 │            │             │
                    ┌────────────┘            │             └──────────────┐
                    │                          │                            │
         ┌──────────┴──────────┐   ┌──────────┴──────────┐      (service externe
         │   Console Fleetbase │   │        BFF Echango   │       de routage)
         │  (opérateur Echango, │   │  (détient la clé API,│
         │   accès complet,     │   │   scoping Vendor/    │
         │   existant)          │   │   Fleet, auth Echango,│
         └──────────────────────┘   │   futur point d'entrée│
                                     │   API publique)       │
                                     └───────────┬───────────┘
                                                 │ REST (Bearer token), polling
                              ┌──────────────────┼───────────────────┐
                              │                  │                   │
                    ┌─────────┴────────┐ ┌───────┴────────┐ ┌───────┴─────────┐
                    │ Interface         │ │ Interface       │ │ Connecteur Odoo  │
                    │ "commerçant"      │ │ "petite flotte" │ │ → Fleetbase       │
                    │ (Flutter/         │ │ (Flutter/       │ │ (echangoorder/    │
                    │  FlutterFlow)     │ │  FlutterFlow)   │ │  backend/addons/  │
                    └───────────────────┘ └─────────────────┘ │  echango_order)   │
                                                               └───────────────────┘
                                     │
                            (assignation driver)
                                     ▼
                         ┌───────────────────────┐
                         │  Navigator (app driver) │
                         │  React Native, AGPL,    │
                         │  1 clé API = 1 Org      │
                         └───────────────────────┘
```

Modélisation métier à l'intérieur de la seule Organization : un **Vendor** = une sous-organisation (petite flotte dédiée), une **Fleet** liée à ce Vendor = ses drivers dédiés (relation avec les drivers permettant l'appartenance multiple, cf. rapport 05 pour la nuance technique exacte), et le **facilitator** sur l'Order pointe vers ce Vendor. Ce triptyque est confirmé solide par le code (`fleetbase/fleetops`, modèles `Fleet.php`, `Vendor.php`, `Order.php`) et par les tests manuels du journal.

---

## 2. Composants

### 2.1 Fleetbase self-hosted (FleetOps)
Le cœur métier : commandes, dispatch, flottes, drivers, calcul d'itinéraire. Une seule Organization partagée. Rien à modifier dans son code (pas de fork).

### 2.2 Extensions FleetOps pertinentes au-delà du périmètre déjà identifié
- **OrderConfig** (`order_config_uuid`) — voir §3.1, découverte majeure qui affine le modèle (nuancée par le rapport 05, voir contradictions dans la synthèse).
- **Service Area / Zone** — voir §3.2, confirmé, utile pour du zonage tarifaire/géographique futur.
- **Ledger** — voir §3.3, extension de facturation/comptabilité réelle.
- **customer-portal** — voir §3.4, découverte non anticipée, potentiellement structurante pour tout le reste de l'architecture.

### 2.3 BFF Echango
Couche intermédiaire que nous possédons : détient la clé/le compte de service Fleetbase, applique le scoping par sous-organisation, expose une API REST stable à nos propres interfaces et (plus tard) aux tiers. Voir §3.4 pour une reformulation importante de son rôle.

### 2.4 Interfaces custom (commerçant / petite flotte)
Non développées. Candidates FlutterFlow — voir §5 dédiée.

### 2.5 Navigator (app driver)
Une clé API = une Organization par build, pas de bascule multi-org. Cohérent avec le choix "une seule Organization". Non testé en pratique.

### 2.6 Connecteur Odoo → Fleetbase (futur, autre repo)
Vit dans `echangoorder/backend/addons/echango_order/`. Voir §4.3 pour une recommandation d'architecture le concernant.

### 2.7 Moteur de routage (OSRM/Valhalla/VROOM)
Voir §3.5.

---

## 3. Vérifications du code source — zones d'ombre levées

### 3.1 `order_config_uuid` — bien plus qu'un champ isolé, une brique de modélisation à part entière

Le journal notait ce champ comme "non exploré". Vérification faite : ce n'est pas un simple attribut, c'est la clé étrangère vers un modèle **`OrderConfig`** de première classe dans `fleetbase/fleetops` (backend Laravel + composants Ember `order-config-manager`) :

- Un `OrderConfig` définit un **type de commande** (`type`/`key`), avec un **activity-flow** propre (machine à états des statuts), des **champs personnalisés** par type, des **entités personnalisées**.
- `ServiceRate` (tarification) est lié à la combinaison `service_area_uuid` + `zone_uuid` + **`order_config_uuid`** — la tarification peut donc varier par zone géographique ET par type de commande nativement.
- `Storefront`/`Network` utilisent aussi `order_config_uuid` comme "config par défaut" pour les commandes issues d'une boutique.

**Implication pour l'architecture** : plutôt que de faire porter toute la logique de statuts/champs différenciés par les deux couches d'interface custom dans notre propre code, il est probablement pertinent de créer **deux (ou plus) `OrderConfig` distincts** côté Fleetbase (ex. "Livraison commerçant standard" vs "Livraison flotte dédiée"). À valider en pratique avant de graver ce choix.

> **⚠️ Voir la contradiction avec le rapport 05** (agent Validation technique Fleetbase), qui ne trouve pas `order_config_uuid` sur `Order` dans `fleetops-api` main mais seulement dans `customer-portal` — signale un possible décalage de version dans l'écosystème Fleetbase. Traité dans `docs/specs_echango_delivery.md` § Contradictions à vérifier.

### 3.2 Service Area / Zone sur `Fleet` — confirmé

Vérifié : relations `belongsTo(ServiceArea::class)` et `belongsTo(Zone::class)` sur `Fleet`, en plus de `vendor()`. Utile plus tard si Echango veut restreindre le pool mutualisé ou une flotte dédiée à une zone, mais pas nécessaire au MVP.

### 3.3 Extension "Ledger" — réelle, et potentiellement stratégique

`fleetbase/ledger` (AGPL, v0.0.8 — **très jeune**, pré-1.0) est une extension complète de comptabilité/facturation : comptabilité en partie double, cycle de vie complet des factures clients, paiements (Stripe, QPay, cash), **wallets** pour companies/users/**drivers**, génération automatique de factures brouillon à partir des `purchase_rate` des commandes FleetOps.

**Point d'attention à remonter explicitement** : Echango Order a déjà — ou aura — sa propre comptabilité côté Odoo. Si Ledger est activé, il faut décider **dès maintenant** qui est la source de vérité financière. Recommandation = garder Odoo/Echango Order comme source de vérité comptable pour la facturation client final, et ne considérer Ledger que pour un usage interne borné (suivi de commission/wallet driver), pour éviter une double comptabilité qui diverge. Non nécessaire au MVP.

### 3.4 Découverte majeure non anticipée : `fleetbase/customer-portal`

Ce package n'apparaît nulle part dans le journal ni dans le `CLAUDE.md`. C'est un **package officiel de première partie** (`customer-portal-api`, AGPL, v0.0.12 — également pré-1.0), backend Laravel + frontend Ember, qui fait exactement ce que le journal concluait comme "à construire nous-mêmes" :

- Il expose une **API séparée** (`customer-portal/int/v1`, distincte de l'API console `int/v1` testée dans le journal), avec son propre login (+ 2FA), protégée par un middleware `fleetbase.protected`.
- Un service **`PortalAccountResolver`** résout, à partir de la session/du token, un contexte `['account_type' => 'contact'|'vendor', 'account' => <Contact|Vendor>]`.
- Chaque contrôleur **scope systématiquement** ses requêtes/écritures à ce contexte (`customer_uuid = $context['account']->uuid`) — c'est très exactement la brique d'isolation par sous-entité que le journal concluait absente de Fleetbase.
- Un flux **`AccountPersonnelController`** gère du "personnel" (utilisateurs additionnels rattachés à un compte **Vendor**, avec rôles) — correspond presque littéralement au besoin "gestionnaire de petite flotte".
- Fonctionnalités additionnelles utiles : factures (intégration Ledger), pièces jointes de commande, carnet d'adresses, préférences de notification, tickets support, conversion Contact → Vendor.

**Ce que ça change concrètement** : le constat du journal ("aucune isolation native en dessous de l'Organization, tout devra être construit par notre BFF") reste **vrai pour l'API console/`int/v1` classique testée manuellement** — mais il est **incomplet** : Fleetbase fournit officiellement une seconde surface d'API, pensée précisément pour ce cas d'usage. C'est une correction factuelle à apporter au journal.

Deux options en découlent, à trancher après un spike pratique (installer `customer-portal-api`, créer un compte Contact et un compte Vendor, tester le scoping réel, vérifier la maturité vu le n° de version 0.0.x) :
1. **Adopter `customer-portal-api` comme backend du BFF** : nos apps Flutter/FlutterFlow appellent directement cette API, et notre "couche BFF" se réduit à une fine translation/agrégation par-dessus, plutôt qu'à réimplémenter tout le scoping Vendor/Contact nous-mêmes.
2. **Construire le BFF entièrement à la main comme prévu**, en s'inspirant de ce package comme référence, si le spike révèle qu'il est trop immature, trop rigide, ou ne couvre pas un besoin spécifique (ex. filtrage par Fleet plutôt que par Vendor pour la vue "dispatch" du gestionnaire de petite flotte).

### 3.5 OSRM — confirmé et complété

Confirmé : `OSRM_HOST` est bien utilisé côté config Laravel et console. **Point important non identifié dans le journal** : la valeur par défaut pointe vers le **serveur démo public** `router.project-osrm.org` — un service explicitement non destiné à un usage de production. Risque opérationnel réel à l'échelle. Alternatives déjà supportées avec surcharge par-Organization : **Valhalla** et **VROOM**. Recommandation : prévoir explicitement un service de routage self-hosted ou un contrat avec un fournisseur avant toute ouverture au-delà de l'exploration.

> Voir aussi le rapport 04 (logistique) qui approfondit ce point avec une découverte encore plus précise (URL codée en dur côté backend API, indépendante d'`OSRM_HOST`).

### 3.6 Autres points du journal — non contredits, brièvement recoupés
- `IntegratedVendor`, `registry-bridge`, `connect_company_uuid` sur Vendor : caractérisation du journal jugée correcte.
- Navigator (1 clé API = 1 Organization) : cohérent avec le reste du code consulté, reste à valider en pratique.

---

## 4. Solidité du modèle Vendor + Fleet + Facilitator + BFF à l'échelle

### 4.1 Ce qui tient bien la route
- Le partage natif `Fleet ↔ Driver` (voir nuance technique exacte au rapport 05) résout structurellement le problème central identifié dans le journal (zéro duplication d'identité driver entre pool mutualisé et flotte dédiée). Base de données relationnelle standard (MySQL) : aucun problème de volumétrie brute pour Laravel/MySQL à l'échelle visée.
- Le flux "facilitator à la création, driver assigné après coup" est confirmé au niveau API réel, pas seulement dans la console — automatisable de façon fiable depuis le BFF.
- `customer-portal-api` (si retenu) apporte une isolation par compte déjà pensée pour ce cas d'usage précis.

### 4.2 Risques réels identifiés

**a) Couplage aux internals non documentés de Fleetbase.** Le modèle repose sur des champs/relations qui ne sont pas un contrat d'API officiellement stabilisé pour l'usage "sous-organisation" que nous en faisons — c'est un détournement astucieux d'un modèle conçu à l'origine pour représenter des partenaires/fournisseurs business génériques. **Mitigation concrète** : geler une version Fleetbase testée, écrire des tests d'intégration du BFF qui exercent précisément ces champs/relations, et ne jamais exposer les noms de champs Fleetbase bruts dans les contrats d'API des interfaces custom ou du connecteur Odoo — toujours passer par un DTO propre à Echango dans le BFF.

**b) Le BFF, goulot d'étranglement et SPOF potentiel.** Puisque toutes les interfaces custom ET le futur connecteur Odoo doivent passer par le BFF, et que le BFF détient un compte de service Fleetbase unique, il devient : (i) un point de défaillance unique fonctionnel pour l'ensemble du réseau ; (ii) un point de contention potentiel. C'est un tradeoff assumé et raisonnable pour la sécurité et la cohérence, mais il implique des exigences non-fonctionnelles explicites dès la conception : BFF sans état (stateless, scalable horizontalement), quotas/rate-limiting par sous-organisation, monitoring dédié dès le premier déploiement réel.

**c) Absence de sémantique de priorité/exclusivité driver entre Fleets.** Le partage `Fleet ↔ Driver` est purement structurel : Fleetbase ne fournit aucune règle native du type "ce driver appartient prioritairement à sa flotte dédiée, ne doit piocher dans le pool mutualisé que si son Vendor l'autorise". Cette logique métier devra être entièrement portée par le BFF — à spécifier explicitement dans les specs produit.

**d) Immaturité des extensions candidates.** `customer-portal-api` (v0.0.12) et `ledger-api` (v0.0.8) sont deux extensions officielles mais très jeunes (pré-1.0). Les adopter réduit la dette technique interne, mais transfère un risque de maturité/stabilité vers un tiers dont on ne maîtrise pas la roadmap. À traiter comme un choix à valider par un spike technique borné dans le temps.

**e) Organization unique = infrastructure unique.** Une seule base MySQL, un seul Redis, un seul cluster SocketCluster pour tout le monde — pas de cloisonnement infra natif entre commerçants. À grande échelle, ceci demande une vraie discipline d'exploitation (sauvegardes, haute disponibilité, supervision) côté self-hosting Echango.

### 4.3 Recommandation transversale — le BFF comme point d'entrée unique, y compris pour le connecteur Odoo

Le connecteur Odoo → Fleetbase ne devrait **pas** appeler l'API Fleetbase directement avec sa propre clé, même s'il est "interne" à Echango. Il devrait passer par le même BFF que les interfaces custom. Justification : cela garantit que toute écriture dans Fleetbase respecte les mêmes règles de scoping et de validation métier, sans dupliquer cette logique dans deux codebases (Odoo/Python d'un côté, BFF de l'autre). Un seul chemin d'écriture vers Fleetbase, quel que soit l'appelant.

---

## 5. FlutterFlow — évaluation pour les deux interfaces custom

### 5.1 Consommation d'une API REST custom (le BFF)

Confirmé solide pour ce cas d'usage :
- **Auth Bearer token** : natif et bien supporté.
- **Formulaires liés à des données dynamiques** : cas d'usage central et bien rodé de FlutterFlow — correspond exactement au besoin de l'interface commerçant.
- **Pagination** : pas de mécanisme "clé en main", mais s'implémente sans difficulté via des paramètres `page`/`limit` + variables d'état — pas un blocage à l'échelle de volumétrie attendue.

### 5.2 Limites sur la logique temps réel / WebSocket

Le vrai point de vigilance :
- FlutterFlow a un support natif du temps réel uniquement pour ses backends intégrés (Firebase/Supabase) — **aucun client SocketCluster natif** (utilisé par Fleetbase pour le tracking live).
- Un WebSocket générique reste possible, mais uniquement via **Custom Actions** en code Dart pur — décrit par la communauté FlutterFlow comme "tricky".
- **Alternative recommandée pour le MVP** : polling REST plutôt que consommation de SocketCluster. Le BFF expose un endpoint simple interrogé à intervalle régulier. FlutterFlow supporte nativement les actions périodiques. Pour un usage B2B (pas grand public), un rafraîchissement toutes les 10-15 secondes est très probablement suffisant.

### 5.3 Tradeoff FlutterFlow vs Flutter écrit à la main

- FlutterFlow apporte de la vitesse principalement sur les écrans "CRUD-shaped" — exactement le profil de l'interface **commerçant**.
- FlutterFlow génère du **vrai code Flutter exportable** : si un écran dépasse ses capacités visuelles, il reste possible d'exporter et de reprendre la main en code natif sur cet écran précis, sans tout réécrire. Réduit fortement le risque de "mauvais choix initial".

### 5.4 FlutterFlow convient-il aux deux interfaces ?

- **Interface commerçant** : très bon candidat, cas d'usage quasiment canonique.
- **Interface petite flotte** (dispatch + carte + positions drivers) : candidat raisonnable **à condition d'adopter la stratégie de polling**, avec probablement un peu de Custom Action pour la logique d'assignation. C'est l'écran le moins prouvé des deux.

**Recommandation concrète** : avant de committer sur FlutterFlow pour les deux interfaces, faire un spike time-boxé (quelques jours) spécifiquement sur l'écran le plus exigeant — carte avec positions de drivers rafraîchies par polling + action d'assignation — plutôt que de valider l'outil uniquement sur l'écran commerçant.

---

## 6. Articulation dans le temps — recommandations concrètes

1. **Poursuivre l'exploration locale déjà planifiée**, en y ajoutant explicitement : (a) un spike sur `customer-portal-api` **avant** de figer la conception du BFF, car son issue change ce que le BFF a réellement à construire ; (b) vérifier la configuration OSRM et évaluer Valhalla/VROOM ; (c) tester la création d'un `OrderConfig` distinct par persona.
2. **Concevoir le BFF comme point d'entrée unique** pour toute écriture Fleetbase, stateless et horizontalement scalable, avec quotas par sous-organisation dès la conception.
3. **Isoler les champs Fleetbase bruts derrière des DTOs internes au BFF**.
4. **Ne pas construire de proxy WebSocket/SocketCluster en V1** ; privilégier le polling REST.
5. **Trancher explicitement la source de vérité financière** (Odoo/Echango Order vs extension Ledger Fleetbase) avant toute activation de Ledger.
6. **Documenter explicitement les règles de priorité/consentement driver entre Fleet dédiée et pool mutualisé**.
7. **Revoir la question de licence AGPL** avant l'ouverture B2B réelle.

**Fichiers de référence** : `/home/user/echango-delivery/CLAUDE.md`, `/home/user/echango-delivery/docs/journal_exploration_fleetbase.md`, `/home/user/echango-delivery/docs/specs_macro_drive_transport.md`, `/home/user/echango-delivery/scripts/setup-local.sh`.
