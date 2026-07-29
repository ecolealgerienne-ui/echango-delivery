# Specs Echango Delivery — synthèse consolidée (avant développement)

**Date** : 26 juillet 2026
**Statut** : Draft de synthèse post-exploration — à valider avant tout développement d'interface custom ou de BFF.

Ce document consolide et priorise les conclusions de 5 relectures spécialisées (sécurité, architecture, métier, logistique, validation technique Fleetbase) menées en parallèle sur `CLAUDE.md` et `docs/journal_exploration_fleetbase.md`, chacune avec vérification croisée du code source public et de la documentation officielle de Fleetbase. **Les 5 rapports complets sont conservés intégralement dans `docs/rapports_specs/` — ce document est une synthèse priorisée, pas un remplacement.** En cas de doute sur un point, se référer au rapport complet correspondant.

---

## 1. Comment lire ce document

- **§2** : les points où deux agents se contredisent — à vérifier en priorité, avant de faire confiance à quoi que ce soit d'autre dans ce document.
- **§3** : les découvertes qui changent réellement la donne par rapport à ce qu'on pensait avant cette revue.
- **§4 à §7** : synthèse par domaine (architecture, sécurité, métier, logistique), condensée — le détail complet est dans `docs/rapports_specs/`.
- **§8** : la décision Flutter pur vs FlutterFlow.
- **§9** : le plan d'action concret, priorisé, avant d'écrire la moindre ligne de code d'interface ou de BFF.
- **§10** : documents à corriger suite à cette revue (CLAUDE.md, doc macro).

---

## 2. ✅ Contradictions entre agents — résolues (26 juillet 2026, après compilation)

Cinq agents ont travaillé en parallèle, chacun avec ses propres recherches de code. Deux points où leurs conclusions divergeaient factuellement ont été identifiés lors de la compilation, puis **vérifiés directement sur GitHub/Packagist dans la foulée** — conservés ici avec leur résolution, pour la traçabilité.

### 2.1 `fleetbase/fleetops-api` est-il archivé ? — RÉSOLU

- **`fleetbase/fleetops-api`** (le repo GitHub de ce nom) est bien **archivé** depuis le **22 novembre 2023** ("This repository was archived by the owner... It is now read-only"), confirmé en ouvrant directement la page. C'est la source consultée à tort par le rapport Validation technique Fleetbase (`05_validation_technique_fleetbase.md`).
- Le développement actif a été déplacé vers **`fleetbase/fleetops`** (1 550 commits, structure `server/src/...`), confirmé actif.
- **Vérification décisive faite sur Packagist** : le package Composer réellement requis par `fleetbase/fleetbase` (`"fleetbase/fleetops-api": "^0.6.58"`) — donc celui installé par `scripts/setup-local.sh` — a sur Packagist une **URL de dépôt qui pointe vers `https://github.com/fleetbase/fleetops`** (pas vers le repo archivé du même nom), dernière version 0.6.58 publiée le 17 juillet 2026, mise à jour le 25 juillet 2026. Autrement dit : le nom du **package Composer** (`fleetbase/fleetops-api`) n'a pas changé pour rester rétrocompatible, mais son **code source** vit désormais dans le repo GitHub `fleetbase/fleetops`.

**Conclusion actionnable** : pour toute recherche de code future sur ce projet, utiliser `fleetbase/fleetops` (chemins `server/src/Models/...`), jamais le repo GitHub archivé `fleetbase/fleetops-api`. `docs/journal_exploration_fleetbase.md` a été corrigé en conséquence (voir sa note de mise à jour en tête de fichier).

### 2.2 `order_config_uuid` existe-t-il comme colonne réelle sur `Order` ? — RÉSOLU, confirmé OUI

Vérifié directement dans `fleetbase/fleetops` (le bon repo, cf. §2.1), fichier `server/src/Models/Order.php` : `order_config_uuid` **est bien présent dans `$fillable`**, et une relation réelle existe :
```php
public function orderConfig(): BelongsTo
{
    return $this->belongsTo(OrderConfig::class)->withTrashed();
}
```
**Conclusion** : le rapport Architecture (`02_architecture.md`) avait raison. Le rapport Validation technique Fleetbase s'était trompé en consultant le repo archivé (qui a effectivement une modélisation différente, antérieure). **La recommandation "un `OrderConfig` par persona" (§4) est donc bien réalisable nativement** — à confirmer par un test pratique de création, mais plus besoin de lever le doute sur son existence.

**Bonus découvert pendant cette vérification** : le `$fillable` complet d'`Order` dans le bon repo contient aussi `time_window_start` et `time_window_end` — **ces deux champs sont donc bien mass-assignable**, contrairement à ce qu'affirmait le rapport Logistique (`04_logistique.md` §7), qui les avait aussi vérifiés sur le mauvais repo (l'archivé) et concluait à tort qu'ils seraient "probablement ignorés silencieusement". **Ce signal d'alerte est levé** : les créneaux horaires peuvent être utilisés avec confiance raisonnable — un test de persistance réel reste recommandé (créer une commande avec ces champs, vérifier en base) mais le risque identifié n'est plus fondé. Autre champ notable découvert au passage, absent des rapports initiaux : `required_skills` sur `Order` — suggère un mécanisme de correspondance compétences driver/commande non exploré, à regarder si pertinent pour le dispatch (ex. véhicule réfrigéré, permis spécifique).

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

**✅ CONFIRMÉ PAR TEST EN PRATIQUE (26/07/2026)** : après installation (`composer require fleetbase/customer-portal-api` dans le conteneur `application`, aucune migration nécessaire — le package réutilise entièrement les tables `User`/`Contact` existantes), création manuelle d'un compte de test (`User.type='customer'` + `Contact.type='customer'`+`user_uuid`, tous deux `$guarded` côté modèle donc à définir via `forceFill()`, pas `create()`), et login réel via `POST customer-portal/int/v1/auth/login` :
- **`GET customer-portal/int/v1/orders` renvoie `{"orders":[]}`** pour ce compte de test sans aucune commande liée — alors que le compte "vendeur" (§3.3 ci-dessous) voyait *toutes* les commandes de l'Organization avec la même API console. **Isolation par compte confirmée réelle**, pas juste théorique.
- **Découverte additionnelle** : Fleetbase assigne automatiquement à tout compte customer-portal un rôle IAM dédié **"Fleet-Ops Customer"**, avec un jeu de permissions volontairement restreint (lister/voir/créer/annuler ses commandes, gérer ses contacts et places, voir les `order-configs` — rien sur IAM, Ledger, Developers, ni les autres Organizations). Confirme que Fleetbase a bien pensé un mécanisme de permission dédié à ce persona, distinct du système de Rôles génériques de la console.
- Deux pièges rencontrés à noter pour la suite (connecteur Odoo, scripts de provisioning) : `User.type` et `User.password` sont tous les deux `$guarded` (pas dans `$fillable`) — `User::create()` les ignore silencieusement sans erreur ; il faut passer par `forceFill(...)->save()`. Le mot de passe a un mutator `setPasswordAttribute` qui hache automatiquement (`Hash::make`) — ne jamais pré-hacher soi-même. Un nouveau compte a aussi un flag de vérification email à lever (`email_verified_at`) avant de pouvoir se connecter.
- **✅ Boucle complète validée (26/07/2026)** : Contact rattaché comme personnel du Vendor "vendeur1" (`vendorPersonnel`), commande créée avec ce Vendor en **`customer`** (champ "Client" de la console — pas `facilitator`, qui n'est **pas** ce sur quoi `customer-portal` scope) : `GET orders` a d'abord persisté à renvoyer une liste vide malgré tout ça correctement configuré.
  - **Cause trouvée et corrigée** : bug/incohérence réel côté Fleetbase. `PortalOrderService::queryForAccount()` compare `customer_type` via `Utils::getMutationType('fleet-ops:vendor')`, qui résout en `Fleetbase\FleetOps\Models\Vendor` (**sans** backslash initial). Mais la console, en enregistrant le champ "Client" avec un Vendor, avait stocké `customer_type` = `\Fleetbase\FleetOps\Models\Vendor` (**avec** un backslash initial) — deux chaînes différentes au sens strict SQL, donc la comparaison échouait silencieusement. Correction manuelle en base (`$order->customer_type = 'Fleetbase\FleetOps\Models\Vendor'; $order->save();` — le cast du modèle a ensuite renormalisé la valeur en alias court `fleet-ops:vendor` à la relecture) → **la commande apparaît immédiatement dans `GET orders`**.
  - **À signaler comme piège concret** pour quiconque construit sur `customer-portal-api` avec un `Vendor` en `customer` : vérifier/normaliser systématiquement le format de `customer_type` (et `facilitator_type`) plutôt que de faire confiance aveuglément à ce que la console écrit — un candidat solide à remonter comme bug upstream à l'éditeur Fleetbase.
  - **Donnée bonus découverte dans la réponse** : chaque commande a une **URL de suivi public** générée nativement (`{CONSOLE_HOST}/track-order?order={tracking_number}`), un `order_config` complet avec machine à états (created → dispatched → started → enroute → completed, `pod_method`/`require_pod` par étape), et une distance/durée effectivement calculée par OSRM (`distance`, `time`) — confirme qu'OSRM répond bien aujourd'hui (via le service par défaut non self-hosted déjà flaggé comme risque, §3.3 des rapports logistique/architecture — fonctionnel maintenant, ne change rien à la recommandation de le self-hoster avant la prod).
  - **Conclusion** : la chaîne complète Vendor + Fleet + Facilitator/Customer + customer-portal fonctionne de bout en bout, une fois le bug de format contourné. Le spike `customer-portal` est maintenant validé à 100 %, pas juste "pour l'essentiel".

### 3.2 L'auto-dispatch par proximité existe nativement

Contrairement à ce que suggérait le test manuel du journal (rien testé au-delà de l'assignation manuelle), le code contient un mécanisme géospatial complet et fonctionnel : commande marquée `adhoc=true` → recherche des drivers disponibles dans un rayon autour du point de prise en charge → broadcast (`OrderPing`) à tous les drivers trouvés → relance automatique toutes les ~4 minutes si personne n'accepte. Limite réelle : ce broadcast n'est filtré ni par `Fleet`, ni par `Zone`/`ServiceArea` — juste par un rayon en mètres. Voir `04_logistique.md` §1 et §3.

**✅ CONFIRMÉ PAR TEST EN PRATIQUE (26/07/2026)** : driver de test ("Toto") positionné (`location` — champ vide par défaut, "île nulle" `0,0`, à définir explicitement) et passé `online=1` manuellement (pas de client Navigator connecté pour le faire naturellement) ; commande créée avec `adhoc=true`, dispatchée via l'action "Ordres d'envoi" (bulk action de la liste des commandes, traduction de "Dispatch Orders"). Résultat en base : `dispatched=1`, `dispatched_at` renseigné à l'horodatage exact du clic — le pipeline `Order::dispatch()` → event `OrderDispatched` → listener `HandleOrderDispatched` → recherche géospatiale → `$driver->notify(new OrderPing(...))` s'est exécuté sans erreur (`failed_jobs` à 0, queue `healthy`).

**Point méthodologique important pour de futurs tests** : chercher une preuve de réception dans les tables `jobs`/`notifications` de la base est **structurellement impossible** avec ce mécanisme — vérifié en lisant `OrderPing` (`server/src/Notifications/OrderPing.php`) : la classe implémente `ShouldQueue` et n'a que des canaux éphémères (`broadcast` en WebSocket, `FcmChannel`, `ApnChannel`), **aucune méthode `toDatabase()`**. Rien n'est donc jamais persisté nulle part — la seule preuve de réception possible est un client réellement connecté (Navigator avec jeton FCM/APN enregistré, ou un abonné WebSocket actif sur le canal). **La validation complète (réception réelle par un driver) reste donc conditionnée à l'installation de Navigator** (déjà en backlog, §9 priorité 4/différé) ; le test ci-dessus valide tout le pipeline serveur jusqu'à l'envoi, ce qui était l'objectif technique principal.

Détail additionnel noté en creusant `HandleOrderDispatched` : la queue Fleetbase n'utilise pas le driver "database" de Laravel (table `jobs` absente de la base — confirme un driver Redis, cohérent avec le service `cache`), et le conteneur Docker `queue` n'écrit rien de visible sur stdout (`docker compose logs queue` vide) — pour du diagnostic futur, préférer l'inspection directe des tables `failed_jobs`/état des enregistrements plutôt que les logs Docker sur ce projet.

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

### 6.1 Contre-proposition de prix par le transporteur — proposition écartée (29/07/2026)

**Statut : proposée, écartée pour l'instant sur décision explicite.** Consignée ici parce que la question se reposera dès que la tarification sera tranchée, et qu'il vaut mieux retrouver le raisonnement que le refaire.

**L'idée.** Aujourd'hui le commerçant propose un montant (`meta.price`) et le transporteur ne peut que prendre ou laisser. Une contre-proposition lui permettrait de répondre « je le fais pour X », le commerçant acceptant ou non — une négociation en un aller-retour plutôt qu'un prix à prendre ou à laisser.

**Ce qui la rend séduisante.** C'est le mécanisme qui produirait le plus vite un barème juste : chaque contre-proposition acceptée est un point de la courbe prix/distance/horaire, mesuré sur des courses réelles et non estimé. Le mécanisme *découvre* le tarif au lieu de le supposer.

**Ce qui l'a fait écarter, et qu'il faudra trancher si on y revient :**

- **Elle transforme une place de marché en négociation bilatérale.** La thèse du produit est l'effet réseau (`CLAUDE.md` § Positionnement) : un pool mutualisé où une course part au premier transporteur disponible. Une négociation introduit un délai entre l'offre et l'acceptation, pendant lequel la course n'est ni prise ni libre.
- **Elle demande un arbitre.** Que se passe-t-il si trois transporteurs contre-proposent ? Le commerçant choisit-il, ou le moins-disant l'emporte-t-il ? Une enchère inversée est un tout autre produit, avec ses propres effets — dont la pression à la baisse sur les revenus des transporteurs, qui est exactement ce que le réseau doit éviter s'il veut en garder.
- **Elle suppose que le commerçant soit joignable.** Une boulangerie à 6 h du matin ne consulte pas son téléphone. Sans délai d'acceptation automatique — encore une règle à trancher —, la course reste en suspens.
- **Le refus motivé la remplace en grande partie.** Implémenté le 29/07/2026 : un transporteur qui trouve le prix insuffisant le dit (`prix_insuffisant`), et ce motif est enregistré avec les entrées tarifaires de la course (distance, horaire, véhicule). On obtient donc le signal — « ce trajet ne vaut pas ce prix » — sans le mécanisme de négociation. C'est moins précis (on sait que c'est trop bas, pas de combien) et **c'est le compromis assumé** : la donnée s'accumule sans changer la nature du produit.

**Si on y revient**, l'ordre logique est : d'abord un barème calculé (`PricingService.computeQuote()`, aujourd'hui un talon), calibré sur les refus accumulés ; ensuite seulement, éventuellement, une marge de négociation autour de ce barème. Négocier sans référence de prix, c'est négocier dans le vide.

---

## 7. Logistique / Opérations — synthèse

Détail complet : `04_logistique.md`. Points structurants au-delà des découvertes déjà notées en §3.2/§3.3 :

- Les tournées multi-arrêts (waypoints) sont supportées côté structure de données, mais **aucune optimisation d'ordre des arrêts n'est câblée côté API** — à construire si c'est un besoin produit réel.
- Le zonage géographique (`ServiceArea`/`Zone`) existe mais n'a **aucun effet de filtrage** sur le dispatch — purement descriptif en l'état. Même constat vérifié le 26/07/2026 pour les compétences (`Order.required_skills`/`Driver.skills`, tous deux réels en base) : aucun filtrage par compétence dans `HandleOrderDispatched`. Fleetbase expose plusieurs axes de filtrage riches en données mais aucun n'est câblé nativement au-delà du rayon géographique — à garder en tête comme un pattern répété, pas un cas isolé.
- **Signal d'alerte concret à vérifier en priorité** : les champs `time_window_start`/`time_window_end` (créneaux horaires), capturés dans un payload de commande réel pendant les tests, sont absents des champs autorisés et des règles de validation observées dans le code — probablement ignorés silencieusement si envoyés tels quels. À tester avant de promettre un engagement de créneau horaire à un commerçant.
- Aucune contrainte de capacité véhicule, aucun planning/shift driver (seulement un flag `online` temps réel) — lacunes à combler côté Echango si besoin produit confirmé.
- Recommandation : activer/tester le mode `adhoc` natif pour le persona "petite flotte" plutôt que construire un moteur de matching maison — le vrai travail est de le scoper à la bonne Fleet (non filtré nativement).

---

## 8. Flutter (pur) vs FlutterFlow — décision revue le 27/07/2026

Détail complet de l'évaluation initiale : `02_architecture.md` §5 (toujours valide techniquement, voir nuance ci-dessous). Confirmé viable pour consommer une API REST custom (auth Bearer natif, formulaires liés à des données dynamiques — bon fit pour l'interface commerçant). **Limite claire, indépendante de l'outil** : pas de client SocketCluster natif pour le temps réel dans Flutter — recommandation de faire du **polling REST** plutôt que du WebSocket pour la V1, suffisant pour un usage B2B à l'échelle visée.

**Décision initiale (26/07/2026) : FlutterFlow.** **Revue et inversée le 27/07/2026** : c'est Claude Code qui écrit le code des deux interfaces, pas un développeur humain qui gagnerait du temps avec l'éditeur visuel glisser-déposer de FlutterFlow — cet argument central en faveur de l'outil ne s'applique donc pas. Un agent IA n'a pas de moyen efficace de piloter une interface web visuelle pensée pour un humain ; écrire directement du code Dart/Flutter est plus rapide et plus précis, et garde tout dans le repo git comme le reste du projet, sans dépendance à un compte/projet FlutterFlow externe ni étape d'éjection vers du code à un moment donné.

**Décision retenue : Flutter pur (code écrit directement)** pour les deux interfaces custom. Les vraies questions techniques identifiées restent d'actualité, reformulées sans référence à l'outil FlutterFlow : Flutter web est-il un bon choix de déploiement pour ces deux interfaces (cohérent avec la recommandation web-first déjà faite, moins de friction d'onboarding qu'une app à installer) ? Polling REST vs client temps réel pour le suivi/dispatch (polling recommandé pour V1, non remis en cause par ce changement) ? Un test technique ciblé sur ces deux points reste utile avant de démarrer le développement des écrans, mais ce n'est plus un "spike FlutterFlow" — plutôt une vérification de la qualité du déploiement web Flutter et du pattern de polling retenu.

---

## 9. Plan d'action avant tout développement (priorisé)

### Priorité 1 — conditionne toute la suite
1. ~~Résoudre les contradictions §2~~ **Fait** (26/07/2026) : `fleetbase/fleetops` confirmé comme repo actif, `order_config_uuid` confirmé réel. Voir §2.
2. **Spike `fleetbase/customer-portal`** — **✅ entièrement fait et concluant** (26/07/2026, voir §3.1) : installation, compte `Contact` rattaché comme personnel d'un `Vendor`, login réel, commande créée avec ce Vendor en `customer`, visible via `GET orders` après correction d'un bug de format (`customer_type` avec backslash initial en trop, écrit par la console). Chaîne Vendor + Fleet + Facilitator/Customer + customer-portal validée de bout en bout. La décision "le BFF s'appuie sur `customer-portal-api`" est maintenant fortement recommandée plutôt qu'hypothétique — sous réserve de la maturité v0.0.x à surveiller en continu, et du piège de format `customer_type`/`facilitator_type` à neutraliser systématiquement dans toute couche qui écrit ces champs.

### Priorité 2 — vérifications techniques bloquantes pour des engagements produit
3. ~~Vérifier si `time_window_start`/`time_window_end` sont réellement persistés~~ **Signal d'alerte levé** (26/07/2026) : les deux champs sont confirmés mass-assignable dans le bon repo. Un test de persistance réel (créer une commande, vérifier en base) reste recommandé mais n'est plus bloquant. Voir §2.2.
4. ~~Vérifier la configuration réelle du routing (OSRM)~~ **Reclassé, pas bloquant pour le dev** (26/07/2026) : déjà répondu sans installation nécessaire — le code confirme que ce n'est pas self-hosted par défaut, et le test §3.1 a montré empiriquement que le routing fonctionne aujourd'hui (distance/durée réelles calculées) via le service par défaut. La vraie question n'est pas "est-ce que ça marche" mais "est-ce acceptable en prod" (non — pas de SLA, adresses commerçants/clients envoyées à un tiers non contractualisé) : c'est une tâche de **mise en production** (déployer OSRM self-hosted ou Valhalla/VROOM), pas une vérification préalable au développement.
5. ~~Tester le mode `adhoc`~~ **✅ Fait** (26/07/2026, voir §3.2) : pipeline serveur confirmé de bout en bout (recherche géospatiale, event, queue, notification déclenchée sans erreur). Reste seulement la réception réelle par un client (Navigator), déjà liée à l'action différée correspondante. Le comportement du retry à 4 minutes (`fleetops:dispatch-adhoc`) reste à observer sur la durée — non testé, non bloquant.
6. ~~Vérifier si `Order.customer` déclenche une facture Ledger cohérente~~ **Reclassé, pas bloquant** (26/07/2026) : cohérent avec la décision déjà actée (§3.3, rapport métier) de garder Odoo/Echango Order comme source de vérité comptable — Ledger n'étant prévu que pour un usage interne borné, voire pas utilisé du tout, ce test devient optionnel plutôt que prérequis au développement.
7. ~~Explorer le champ `required_skills` sur `Order`~~ **Fait** (26/07/2026) : `Driver.skills` existe aussi (JSON, `$fillable`), mais **aucun filtrage par compétences n'est câblé dans le dispatch natif** (`HandleOrderDispatched` ne filtre que sur statut/en ligne/société/position/distance géographique) — même schéma que `ServiceArea`/`Zone` (§7 du journal, rapport logistique) : donnée descriptive présente, sans effet automatique. Si le matching par compétence (véhicule réfrigéré, permis spécifique...) est un besoin produit réel, c'est encore à construire côté BFF.

**→ Priorités 1 et 2 closes (26/07/2026)** : tout ce qui était bloquant techniquement avant le développement est soit validé par test réel, soit explicitement déclassé comme non bloquant (tâche de mise en prod plutôt que prérequis dev). Les points restants sont des décisions produit (Priorité 3) et de la préparation technique pour le développement lui-même (Priorité 4).

### Priorité 3 — décisions produit à trancher (pas techniques, mais bloquantes pour le dev)
8. Trancher les 11 règles métier listées en `03_metier.md` §5 (tarification, commission, cadence de paiement, annulations, SLA, propriété relation client, onboarding, fiscalité).
9. Documenter explicitement les règles de priorité/consentement driver entre Fleet dédiée et pool mutualisé (aucune règle native, silence = bug potentiel).
10. Décider si Ledger est activé, et si oui, confirmer Odoo/Echango Order comme source de vérité comptable pour éviter une double comptabilité.

### Priorité 4 — avant la première ligne de code d'interface
11. ~~Spike FlutterFlow~~ **Décision revue (27/07/2026, voir §8)** : Flutter pur (code écrit directement par Claude Code), pas FlutterFlow — l'argument de vitesse pour un développeur humain via glisser-déposer ne s'applique pas à un développement piloté par IA. Reste utile : vérifier la qualité du déploiement Flutter web sur l'écran le plus exigeant (carte + positions drivers + action d'assignation, côté "petite flotte") et confirmer le pattern de polling REST, avant de démarrer le développement des deux interfaces.
12. Concevoir le BFF comme point d'entrée unique (y compris futur connecteur Odoo), stateless, avec DTOs internes qui n'exposent jamais les noms de champs Fleetbase bruts.
13. Modèle de menace + tests anti-IDOR pour la couche de filtrage du BFF, avant tout accès commerçant/sous-organisation réel.
15. Installer et tester Navigator (décision prise le 27/07/2026 : on reste sur Navigator plutôt qu'une app transporteur custom — question ouverte #3 du `CLAUDE.md`) — jamais installé en pratique, à faire avant de considérer l'app transporteur prête.

### Reste différé (déjà noté dans `CLAUDE.md`, non affecté par cette revue)
14. Rouvrir la question de la licence AGPL avec un juriste avant la Phase 3 B2B.
15. Installer et tester Navigator avec un vrai compte driver (question ouverte #3 du `CLAUDE.md`).

---

## 10. Documents à corriger suite à cette revue

- **`docs/journal_exploration_fleetbase.md`** : ~~corriger la référence de repo Fleetbase~~ **fait** (26/07/2026, voir note de mise à jour en tête du journal et §2.1 ci-dessus) ; note vers ce document de synthèse ajoutée.
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
