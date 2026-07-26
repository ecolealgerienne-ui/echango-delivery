# Specs Echango Delivery — synthèse consolidée (avant développement)

**Date** : 26 juillet 2026
**Statut** : Draft de synthèse post-exploration — à valider avant tout développement d'interface custom ou de BFF.

Ce document consolide et priorise les conclusions de 5 relectures spécialisées (sécurité, architecture, métier, logistique, validation technique Fleetbase) menées en parallèle sur `CLAUDE.md` et `docs/journal_exploration_fleetbase.md`, chacune avec vérification croisée du code source public et de la documentation officielle de Fleetbase. **Les 5 rapports complets sont conservés intégralement dans `docs/rapports_specs/` — ce document est une synthèse priorisée, pas un remplacement.** En cas de doute sur un point, se référer au rapport complet correspondant.

---

## 1. Comment lire ce document

- **§2** : les points où deux agents se contredisent — à vérifier en priorité, avant de faire confiance à quoi que ce soit d'autre dans ce document.
- **§3** : les découvertes qui changent réellement la donne par rapport à ce qu'on pensait avant cette revue.
- **§4 à §7** : synthèse par domaine (architecture, sécurité, métier, logistique), condensée — le détail complet est dans `docs/rapports_specs/`.
- **§8** : la décision FlutterFlow.
- **§9** : le plan d'action concret, priorisé, avant d'écrire la moindre ligne de code d'interface ou de BFF.
- **§10** : documents à corriger suite à cette revue (CLAUDE.md, doc macro).

---

## 2. ⚠️ Contradictions entre agents — à vérifier en priorité

Cinq agents ont travaillé en parallèle, chacun avec ses propres recherches de code. Deux points où leurs conclusions divergent factuellement ont été identifiés. **Ne pas trancher entre elles par supposition — vérifier directement en local avant de figer l'architecture.**

### 2.1 `fleetbase/fleetops-api` est-il archivé ?

- Le rapport **Sécurité** (`01_securite.md`) affirme avoir vérifié que `fleetbase/fleetops-api` est **archivé** (`archived: true`, dernière MAJ avril 2025), et que le code actif est dans `fleetbase/fleetops` (arborescence `server/src/Models/...`).
- Le rapport **Validation technique Fleetbase** (`05_validation_technique_fleetbase.md`) continue de citer `fleetbase/fleetops-api` comme "la branche main v1.2.0, celle que l'équipe déploierait aujourd'hui", sans mention d'archivage, avec une arborescence `src/Models/...` (sans `server/`).
- Le rapport **Architecture** (`02_architecture.md`) cite `fleetbase/fleetops` comme repo actif.

**Action requise avant tout choix d'architecture** : ouvrir directement `https://github.com/fleetbase/fleetops-api` et `https://github.com/fleetbase/fleetops` dans un navigateur, noter lequel est marqué "Archived", lequel a des commits récents, et quelle arborescence (`src/` vs `server/src/`) correspond à la version réellement installée par `composer require fleetbase/fleetops` (celle utilisée par `scripts/setup-local.sh`). Corriger toutes les références de repo dans `docs/journal_exploration_fleetbase.md` en conséquence.

### 2.2 `order_config_uuid` existe-t-il comme colonne réelle sur `Order` ?

- Le rapport **Architecture** affirme que `order_config_uuid` est une colonne réelle sur `Order`, avec un modèle `OrderConfig` complet (activity-flow, champs personnalisés) dans le repo qu'il cite comme actif.
- Le rapport **Validation technique Fleetbase** affirme au contraire que dans `fleetops-api` "main, v1.2.0", il n'y a **pas** de colonne `order_config_uuid` sur `Order` — le mécanisme de configuration de commande passerait plutôt par `Order.type` + un modèle `Extension` (`meta_type='order_config'`), et que le vrai modèle `OrderConfig` avec colonne dédiée n'existe que dans le package plus récent `fleetbase/customer-portal`.

Cette contradiction est **très probablement liée à la même confusion de repo qu'en §2.1** (deux versions différentes de l'écosystème Fleetbase consultées par les deux agents). **Action requise** : une fois le repo actif identifié (§2.1), vérifier directement dans son code si `order_config_uuid`/`OrderConfig` existe nativement dans FleetOps, ou uniquement via `customer-portal`. Ceci conditionne directement la faisabilité de la recommandation "un `OrderConfig` par persona" (§4 ci-dessous) — à ne pas considérer comme acquis avant vérification.

---

## 3. Découvertes qui changent la donne

Classées par impact, indépendamment du domaine d'origine.

### 3.1 `fleetbase/customer-portal` — découverte convergente et la plus structurante

**Confirmée indépendamment par deux agents** (architecture et validation technique, sans concertation entre eux — ils tournaient en parallèle), c'est le signal le plus fort de toute cette revue : un package **officiel first-party**, jamais mentionné dans le journal ni le `CLAUDE.md`, qui implémente déjà :
- une API dédiée avec login séparé, distincte de l'API console testée dans le journal,
- un **scoping natif par compte** (`Vendor` ou `Contact`) sur toutes les commandes/ressources — exactement la fonction qu'on pensait devoir construire entièrement dans notre BFF,
- un flux de gestion de "personnel" rattaché à un compte `Vendor` avec rôles — proche du besoin "gestionnaire de petite flotte",
- carnet d'adresses scopé, facturation intégrée à Ledger, conversion Contact → Vendor.

**Conséquence directe** : le constat du journal ("Fleetbase ne fournit aucune isolation en dessous du niveau Organization, tout devra être construit par notre BFF") reste vrai pour l'API console classique, mais est **incomplet**. Avant de concevoir le BFF, il faut un spike dédié pour tester ce package en conditions réelles (voir §9, action #1). Réserve commune aux deux agents qui l'ont trouvé : c'est une extension jeune (v0.0.12, pré-1.0), à ne pas adopter les yeux fermés.

### 3.2 L'auto-dispatch par proximité existe nativement

Contrairement à ce que suggérait le test manuel du journal (rien testé au-delà de l'assignation manuelle), le code contient un mécanisme géospatial complet et fonctionnel : commande marquée `adhoc=true` → recherche des drivers disponibles dans un rayon autour du point de prise en charge → broadcast (`OrderPing`) à tous les drivers trouvés → relance automatique toutes les ~4 minutes si personne n'accepte. Limite réelle : ce broadcast n'est filtré ni par `Fleet`, ni par `Zone`/`ServiceArea` — juste par un rayon en mètres. Voir `04_logistique.md` §1 et §3.

### 3.3 Le calcul d'itinéraire n'est pas self-hosted par défaut

Deux agents (architecture, logistique) confirment que malgré le narratif "self-hosted AGPL" du projet, le routing dépend par défaut de services externes non contractualisés : le frontend console pointe vers le serveur de démonstration public d'OSRM (non garanti pour la production), et — découverte plus fine du rapport logistique — la classe backend qui fait le calcul réel (`Support\OSRM`) a une **URL codée en dur** vers un service hébergé par Fleetbase Pte Ltd elle-même (`bundle.routing.fleetbase.io`), indépendamment de la variable `OSRM_HOST`. Aucun conteneur de routing n'est déployé par défaut dans `docker-compose.yml`. Voir `04_logistique.md` §5 et `02_architecture.md` §3.5.

### 3.4 Ledger existe et facture automatiquement, mais ne calcule aucune commission

`fleetbase/ledger` est une extension réelle et déjà intégrée à FleetOps (génération automatique de factures brouillon à la création d'un tarif de commande). Mais **aucune logique de commission n'existe** : pas de taux configurable, pas d'événement "commande livrée → calcule la part du transporteur → crédite son wallet". C'est un moteur métier entièrement à construire côté Echango. Voir `03_metier.md` §1.

### 3.5 Le doc macro (`specs_macro_drive_transport.md`) contient des affirmations obsolètes

Plusieurs points du doc macro d'origine, non mis à jour depuis, contredisent des constats confirmés cette session : le concept "Networks" qu'il cite comme fonctionnalité Fleetbase native n'a été retrouvé nulle part dans le code, la "facturation automatique avec commissions" est sur-attribuée (la commission n'existe pas, cf. §3.4), le "dashboard Fleetbase" est présenté comme la solution retenue pour le commerçant alors que ce choix a été explicitement invalidé par test manuel, et la décision "Navigator écarté" y est présentée comme tranchée alors que `CLAUDE.md` l'a rouverte. Voir `03_metier.md` §3, et §10 ci-dessous pour l'action de correction.

---

## 4. Architecture — synthèse

Vue d'ensemble retenue (détail complet et schéma : `02_architecture.md` §1-2) :

- **Une seule Organization Fleetbase "Echango Delivery"**, extension FleetOps installée, Storefront écarté.
- **Modélisation des sous-organisations** : `Vendor` = une sous-organisation, `Fleet` liée à ce Vendor = ses drivers dédiés, ces drivers pouvant aussi appartenir à la Fleet "pool mutualisé" (partage confirmé au niveau data, nuance technique sur le type de relation Eloquent — voir `05_validation_technique_fleetbase.md` #2). `facilitator` sur la commande = le Vendor responsable de l'exécution.
- **Découverte à intégrer** : `Order` a aussi un champ `customer` (polymorphique Vendor/Contact), distinct de `facilitator` et jamais testé. Le persona **commerçant** correspond naturellement au rôle `customer` (potentiellement via `customer-portal`, §3.1), le persona **gestionnaire de petite flotte** au rôle `facilitator` (déjà testé). Un même Vendor peut jouer les deux rôles selon la commande.
- **Couche BFF Echango** : détient le(s) compte(s) de service Fleetbase, applique le scoping métier, point d'entrée unique pour toute écriture Fleetbase — y compris le futur connecteur Odoo → Fleetbase, qui ne doit **pas** appeler Fleetbase directement (recommandation transversale, `02_architecture.md` §4.3). **Sous réserve du spike `customer-portal`** (§9 action #1) : le contenu réel du BFF peut se réduire à un wrapper fin si `customer-portal-api` est retenu, ou être construit intégralement à la main sinon.
- **Risques identifiés à traiter dès la conception** : couplage à des champs Fleetbase non contractualisés (mitigé par des DTOs internes au BFF, jamais de nom de champ Fleetbase brut exposé aux consommateurs), BFF comme SPOF fonctionnel (stateless, scalable, quotas par sous-organisation dès le départ), absence de règle native de priorité/consentement driver entre Fleet dédiée et pool mutualisé (à spécifier explicitement, pas supposée), immaturité de `customer-portal`/`ledger` (extensions pré-1.0). Détail complet : `02_architecture.md` §4.2.

---

## 5. Sécurité — synthèse

Détail complet : `01_securite.md`. Points structurants :

- **Aucun filet de sécurité Fleetbase en dessous du niveau Organization** (confirmé par 3 agents indépendamment) : le BFF est **la** couche de sécurité pour tout scoping par sous-entité. Traiter chaque endpoint exposé à un commerçant/gestionnaire de flotte comme devant *prouver* le filtrage — tests automatisés anti-IDOR obligatoires en CI.
- **Doute non résolu sur l'entropie des clés API Fleetbase** (génération via Sqids sur timestamp + ID, pas une source d'entropie cryptographique confirmée) — à clarifier avant mise en prod, traiter la clé de service du BFF comme potentiellement plus faible qu'un token aléatoire classique en attendant (restriction réseau stricte, jamais transmise à un frontend).
- **Webhooks entrants `IntegratedVendor.webhook_url`** : validation de signature non confirmée côté code — ne pas répliquer ce mécanisme pour une future API tierce sans l'avoir auditée.
- **Géolocalisation driver** (table `Position` à haute fréquence) et données client : nécessitent une politique de rétention et de minimisation explicite, absente par défaut de Fleetbase.
- **AGPL** : l'obligation de publication porte sur les *modifications* du code exposées en réseau — consommer l'API sans forker ne devrait *a priori* pas déclencher cette obligation, mais reste une interprétation à confirmer avec un juriste avant la Phase 3.
- Checklist actionnable complète en fin de rapport (`01_securite.md` §5).

---

## 6. Métier — règles à trancher avant développement

Détail complet : `03_metier.md`. Tableau des 11 règles métier non tranchées, priorité haute sur : **modèle de tarification et de commission** (rien n'existe côté Fleetbase, entièrement à définir), **qui est posé en `Order.customer`** pour que la facturation automatique cible la bonne entité (jamais testé), cadence de paiement du transporteur, règles d'annulation/livraison ratée, existence d'un SLA de délai, propriété de la relation client final, parcours d'onboarding commerçant/sous-organisation. Voir le tableau complet en fin de `03_metier.md` §5.

---

## 7. Logistique / Opérations — synthèse

Détail complet : `04_logistique.md`. Points structurants au-delà des découvertes déjà notées en §3.2/§3.3 :

- Les tournées multi-arrêts (waypoints) sont supportées côté structure de données, mais **aucune optimisation d'ordre des arrêts n'est câblée côté API** — à construire si c'est un besoin produit réel.
- Le zonage géographique (`ServiceArea`/`Zone`) existe mais n'a **aucun effet de filtrage** sur le dispatch — purement descriptif en l'état.
- **Signal d'alerte concret à vérifier en priorité** : les champs `time_window_start`/`time_window_end` (créneaux horaires), capturés dans un payload de commande réel pendant les tests, sont absents des champs autorisés et des règles de validation observées dans le code — probablement ignorés silencieusement si envoyés tels quels. À tester avant de promettre un engagement de créneau horaire à un commerçant.
- Aucune contrainte de capacité véhicule, aucun planning/shift driver (seulement un flag `online` temps réel) — lacunes à combler côté Echango si besoin produit confirmé.
- Recommandation : activer/tester le mode `adhoc` natif pour le persona "petite flotte" plutôt que construire un moteur de matching maison — le vrai travail est de le scoper à la bonne Fleet (non filtré nativement).

---

## 8. FlutterFlow — décision

Détail complet : `02_architecture.md` §5. Confirmé viable pour consommer une API REST custom (auth Bearer natif, formulaires liés à des données dynamiques — bon fit pour l'interface commerçant). **Limite claire** : pas de client SocketCluster natif pour le temps réel — recommandation de faire du **polling REST** plutôt que du WebSocket pour la V1, suffisant pour un usage B2B à l'échelle visée. FlutterFlow génère du vrai code exportable, ce qui limite le risque d'un mauvais choix initial (on peut reprendre la main en code natif sur un écran précis sans tout réécrire).

**Décision** : partir sur FlutterFlow pour les deux interfaces custom, avec un **spike time-boxé préalable sur l'écran le plus exigeant** (carte + positions drivers rafraîchies par polling + action d'assignation, côté "petite flotte") avant de committer sur l'ensemble — ne pas valider l'outil uniquement sur l'écran commerçant, plus facile et moins représentatif du risque réel.

---

## 9. Plan d'action avant tout développement (priorisé)

### Priorité 1 — lève les deux contradictions et conditionne toute la suite
1. **Résoudre les contradictions §2** (repo `fleetops-api` vs `fleetops` archivé/actif, existence réelle d'`order_config_uuid`) en vérifiant directement sur GitHub et dans l'installation locale déjà en place.
2. **Spike `fleetbase/customer-portal`** : installer l'extension (`composer require fleetbase/customer-portal-api`), créer un compte `Contact` et un compte `Vendor`, vérifier le scoping réel des commandes et la maturité de l'API. Décide si le BFF s'appuie dessus (wrapper fin) ou se construit intégralement à la main.

### Priorité 2 — vérifications techniques bloquantes pour des engagements produit
3. Vérifier si `time_window_start`/`time_window_end` sont réellement persistés par l'API (créer une commande de test avec ces champs, inspecter la base).
4. Vérifier la configuration réelle du routing (OSRM) sur l'installation locale, évaluer Valhalla/VROOM ou un service commercial pour la production.
5. Tester le mode `adhoc` (auto-dispatch par proximité) en pratique avec au moins deux drivers de test, confirmer le comportement du retry à 4 minutes.
6. Vérifier si `Order.customer` doit être renseigné pour que `PurchaseRateObserver` génère une facture cohérente (test avec un Vendor "commerçant simple", sans facilitateur).

### Priorité 3 — décisions produit à trancher (pas techniques, mais bloquantes pour le dev)
7. Trancher les 11 règles métier listées en `03_metier.md` §5 (tarification, commission, cadence de paiement, annulations, SLA, propriété relation client, onboarding, fiscalité).
8. Documenter explicitement les règles de priorité/consentement driver entre Fleet dédiée et pool mutualisé (aucune règle native, silence = bug potentiel).
9. Décider si Ledger est activé, et si oui, confirmer Odoo/Echango Order comme source de vérité comptable pour éviter une double comptabilité.

### Priorité 4 — avant la première ligne de code d'interface
10. Spike FlutterFlow time-boxé sur l'écran dispatch/carte (le plus exigeant), avant de committer sur l'outil pour les deux interfaces.
11. Concevoir le BFF comme point d'entrée unique (y compris futur connecteur Odoo), stateless, avec DTOs internes qui n'exposent jamais les noms de champs Fleetbase bruts.
12. Modèle de menace + tests anti-IDOR pour la couche de filtrage du BFF, avant tout accès commerçant/sous-organisation réel.

### Reste différé (déjà noté dans `CLAUDE.md`, non affecté par cette revue)
13. Rouvrir la question de la licence AGPL avec un juriste avant la Phase 3 B2B.
14. Installer et tester Navigator avec un vrai compte driver (question ouverte #3 du `CLAUDE.md`).

---

## 10. Documents à corriger suite à cette revue

- **`docs/journal_exploration_fleetbase.md`** : corriger la référence de repo Fleetbase une fois la contradiction §2.1 résolue ; ajouter une note vers ce document de synthèse.
- **`docs/specs_macro_drive_transport.md`** : corriger les points listés en §3.5 (concept "Networks" non confirmé, facturation/commission sur-attribuée, dashboard Fleetbase comme solution commerçant à retirer, statut Navigator à aligner avec `CLAUDE.md`, ajouter le persona "gestionnaire de petite flotte" absent de la version actuelle). **Ce document appartient normalement au repo `echangoorder`** (`docs/specs_macro_drive_transport.md` y est cité comme source ; une copie existe aussi dans ce repo) — vérifier lequel est la source de vérité avant de corriger, pour ne pas créer une divergence entre les deux copies.
- **`CLAUDE.md`** : ajouter un renvoi vers ce document de synthèse et vers `docs/rapports_specs/`, mettre à jour la section "Prochaines étapes" avec le plan d'action priorisé du §9 ci-dessus.

---

## Annexes — rapports complets

- `docs/rapports_specs/01_securite.md`
- `docs/rapports_specs/02_architecture.md`
- `docs/rapports_specs/03_metier.md`
- `docs/rapports_specs/04_logistique.md`
- `docs/rapports_specs/05_validation_technique_fleetbase.md`
- `docs/journal_exploration_fleetbase.md` (journal source de l'exploration initiale)
