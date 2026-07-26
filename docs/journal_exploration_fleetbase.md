# Journal d'exploration Fleetbase — 26 juillet 2026

Ce document trace en détail la session d'exploration Fleetbase du 26 juillet 2026 : installation, tests manuels dans la console, recherches dans le code source public de Fleetbase, et décisions/hypothèses qui en découlent. Le `CLAUDE.md` à la racine reste la source de vérité condensée (décisions + questions ouvertes) ; ce journal sert de trace détaillée pour ne rien perdre de ce qui a été testé et pourquoi.

Contexte général et enjeux produit : voir `CLAUDE.md`.

---

## 1. Installation locale

Suivi de `scripts/setup-local.sh` (clone `fleetbase/fleetbase` + `./scripts/docker-install.sh`, le wizard d'installation Docker officiel). Script relu avant exécution : jugé correct et à jour (chemin `scripts/docker-install.sh` vérifié comme existant côté upstream).

### 1.1 Bug rencontré — mismatch MySQL

À la fin de l'installation (`docker-install.sh` → `deploy.sh`), erreur :

```
SQLSTATE[42000]: Access denied for user 'fleetbase'@'%' to database 'fleetbase_sandbox'
```

**Cause identifiée** : `docker-compose.override.yml` configure MySQL avec des droits pour la base **`fleetbase`** uniquement (`MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` — générés par `docker-install.sh`, où `DB_DATABASE` est toujours codé en dur à `"fleetbase"`, et `ENVIRONMENT` vaut `"development"` ou `"production"`, jamais `"sandbox"`). Le conteneur `application` (l'API Laravel), lui, tente d'utiliser une base **`fleetbase_sandbox`** — valeur qui ne vient donc pas du script d'installation mais très probablement d'un `.env` par défaut embarqué dans l'image de l'API, indépendant de la variable `DATABASE_URL` transmise.

**Fix appliqué** (côté utilisateur, WSL) :
```bash
docker compose exec database mysql -uroot -p'<ROOT_PW>' -e "
CREATE DATABASE IF NOT EXISTS fleetbase_sandbox CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`fleetbase%\`.* TO 'fleetbase'@'%';
FLUSH PRIVILEGES;
"
docker compose exec -T application bash -c "./deploy.sh"
```
(`<ROOT_PW>` = valeur de `MYSQL_ROOT_PASSWORD` dans `docker-compose.override.yml` généré localement — ne pas committer cette valeur, propre à chaque installation locale.)

**Résultat** : déploiement réussi (migrations, cache, routes, scheduler — 18 tâches monitorées). Seul message résiduel : `Install notification was not sent: Connection closed` — non bloquant, tentative d'envoi d'une notification externe (webhook/analytics) en fin d'install, sans impact sur l'instance locale.

**À retenir pour une prochaine install** : ce bug se reproduira probablement à chaque installation fraîche tant que `setup-local.sh` ne l'anticipe pas. Piste non implémentée : durcir le script pour appliquer automatiquement ce grant après l'installation Docker.

### 1.2 Données de démonstration

`deploy.sh` exécute automatiquement `php artisan fleetbase:seed` + `php artisan fleetbase:create-permissions` — seed **système** (permissions, rôles), pas de données métier de démo. `DatabaseSeeder.php` (Laravel standard) est un stub vide ; `fleetbase:seed` est une commande custom définie ailleurs (package core, non localisée précisément). Aucune commande de seed de données de démo (commandes/drivers/clients fictifs) confirmée dans la documentation ni le code consultés. Recommandation retenue : créer les données de test manuellement via la console.

---

## 2. Complexité de la console — persona commerçant

Capture d'écran de "Customise Navigation" : barre de navigation limitée à **5 extensions épinglées** ("PINNED TO BAR 5/5"). Confirmé : limite d'espace UI, pas une restriction de licence — les extensions non épinglées restent accessibles via le panneau "All Extensions" ou en sous-navigation une fois dans une extension.

Constat manuel de l'utilisateur : la console (navigation à onglets Fleet-Ops/Storefront/Developers/Ledger/IAM, gestion d'extensions...) est **"très compliquée pour des petits commerçants, inutilisable dans l'état"**. Confirme et tranche la question ouverte du `CLAUDE.md` sur l'interface commerçant : ce sera une interface custom légère (formulaire commande + suivi), pas la console Fleetbase même avec un rôle restreint. Documenté dans `CLAUDE.md` (PR #1).

Un second persona a été identifié à cette occasion : une **organisation qui gère elle-même une petite flotte de transporteurs** (ni Echango l'opérateur réseau, ni un simple commerçant) — a aussi besoin d'une interface simple, mais différente (vue dispatch minimaliste plutôt qu'un simple formulaire de commande). Documenté dans `CLAUDE.md`.

---

## 3. Isolation entre Organizations

### 3.1 Test manuel — drivers/users

Un driver créé dans l'Organization A n'est **ni visible ni réutilisable** dans l'Organization B. En recréer un "identique" dans B génère un enregistrement Fleetbase entièrement distinct (ID différent), sans aucun lien natif entre les deux — confirmé par test direct (création d'un même driver dans deux Organizations différentes) et par observation générale ("les drivers, users ne sont pas visibles entre organisation").

**Conséquence** : si une organisation gère sa propre flotte dédiée dans sa propre Organization Fleetbase, ses drivers ne peuvent pas nativement aussi piocher dans le pool mutualisé "Echango Delivery" — double saisie manuelle requise, aucune synchronisation (statut, position, historique dupliqués et désynchronisés). Documenté dans `CLAUDE.md` (PR #1).

Ce constat a motivé la recherche des concepts **Fleet / Vendor / Facilitateur** (§6) qui offre une meilleure alternative : rester sur une seule Organization et gérer la notion de "sous-organisation" autrement.

### 3.2 API Keys — scoping par Organization (confirmé par le code)

Vérifié dans le code source public `fleetbase/core-api`, migration `migrations/2023_04_25_094311_create_api_credentials_table.php` : la table `api_credentials` a bien une colonne **`company_uuid`** (+ `user_uuid`, `key`, `secret`, `test_mode`, `expires_at`...). Confirme que les clés API sont scopées par Organization au niveau base de données — une brique de base utile pour la vision "plateforme ouverte" (transporteurs/tiers qui développent leurs propres intégrations).

### 3.3 IAM / permissions — pas d'isolation en dessous du niveau Organization

Test manuel : connexion en tant qu'utilisateur "vendeur" (lié à un `Vendor`/facilitateur) depuis un autre navigateur → **voit toutes les commandes de l'Organization**, y compris celles où il n'est pas facilitateur. Confirme que "Vendor/Facilitateur" est une **étiquette de donnée**, pas un mécanisme de permission/sécurité.

Vérification côté code pour corroborer (les rôles IAM ont trop d'options pour un audit manuel exhaustif — jugé non productif) :
- Aucun dossier `Policies` trouvé côté `fleetops-api` (404 sur le chemin attendu).
- `OrderController` (Internal v1) : aucune méthode d'index/liste visible dans ce fichier (héritée d'un contrôleur de base non inspecté), et **aucune référence à un système de Policy / `authorize()` / `can()` / gates** dans ce fichier.

**Conclusion retenue (répond à la question ouverte #1 du CLAUDE.md)** : Fleetbase ne fournit aucune isolation native en dessous du niveau Organization — ni pour un commerçant restreint à ses propres commandes, ni pour un vendor restreint aux commandes où il est facilitateur. Le filtrage/la visibilité par sous-entité devra être **entièrement géré par notre propre couche (BFF)**, pas par la configuration native de rôles Fleetbase.

---

## 4. App mobile Navigator

Repo public vérifié : `fleetbase/navigator-app` (React Native, AGPL). README : "open source order management, geolocation tracking & navigation app for Fleetbase drivers & agents" — gestion des activités de commande, scan QR, signatures/photos, chat intégré avec opérateurs et clients.

**Constat clé** : configuration via **une seule clé API Fleetbase par build de l'app** → une seule Organization par installation. Pas de fonctionnalité native de bascule entre Organizations mentionnée dans le README.

**Conclusions** :
- Architecturalement, Navigator est une app mono-usage pour un driver (pas un panel admin) — beaucoup plus simple que la console dans son principe. Bonne nouvelle : le vrai problème de complexité identifié (§2) concerne la console, pas l'app mobile.
- Pour le pool mutualisé (une seule Organization "Echango Delivery"), aucun problème — un seul build de l'app couvre tous les commerçants de cette Organization.
- Limite : un driver qui voudrait travailler à la fois pour le pool mutualisé et une flotte dédiée dans une **Organization séparée** aurait besoin de deux installations d'app distinctes. Ce point est cependant contourné si on adopte l'architecture Fleet/Vendor à une seule Organization (§6) plutôt que des Organizations séparées par flotte dédiée.

**Non vérifié** (à faire en local) : test réel de connexion d'un compte driver dans l'app pour confirmer la simplicité annoncée par le README.

---

## 5. Architecture envisagée — couche BFF (backend-for-frontend)

Recommandation discutée (pas encore un plan de dev arrêté) : une couche intermédiaire qu'Echango possède, entre les interfaces custom (commerçant, gestionnaire de petite flotte) et l'API Fleetbase — plutôt que ces interfaces qui appelleraient Fleetbase en direct. Rôles de cette couche :
- Détient les clés API Fleetbase (jamais exposées aux commerçants/gestionnaires de flotte/tiers).
- Applique nos propres règles de permission — nécessaire vu la conclusion du §3.3 (pas de scoping natif en dessous de l'Organization).
- Point d'implémentation naturel pour le filtrage par sous-organisation (Vendor/Fleet, §6).
- Deviendrait la base de l'**API publique Echango** documentée/versionnée pour les transporteurs qui veulent développer leurs propres intégrations (objectif produit exprimé), découplée des évolutions internes de l'API Fleetbase.

**Tradeoff assumé** : un service de plus à construire et héberger, contre l'option plus rapide (mais plus fragile) de laisser les interfaces custom appeler Fleetbase directement avec des clés API scopées par Organization.

**Reformulation utile identifiée plus tard dans la session** (voir backlog, §12) : puisqu'il n'y a de toute façon aucun scoping natif à déléguer à Fleetbase, il n'est peut-être **pas nécessaire de créer un compte utilisateur Fleetbase par commerçant/gestionnaire de flotte** — l'authentification pourrait être entièrement gérée côté Echango (comptes Echango), le BFF utilisant un seul compte de service Fleetbase pour tous les appels API. À vérifier/confirmer avant de trancher.

---

## 6. Sous-organisations : Fleet, Vendor, Facilitateur

### 6.1 Origine de la question

Proposition de l'utilisateur : plutôt que de dupliquer les Organizations Fleetbase (§3.1, qui casse le partage de drivers), garder **une seule Organization "Echango Delivery"** et gérer la notion de "sous-organisation" (une entité qui gère sa propre petite flotte dédiée, avec des drivers parfois aussi mutualisés) **nous-mêmes**, dans notre interface dédiée.

Idée initiale envisagée (avant la découverte des modèles ci-dessous) : gérer ça comme une couche d'étiquetage pure dans notre propre base (une table à nous, driver Fleetbase UUID → sous-org), sans support natif Fleetbase.

### 6.2 Validation qu'une assignation ciblée de driver existe

Capture d'écran du formulaire de création de commande : champ "Attribuer un conducteur" avec un driver précis sélectionné ("TOTO"). Confirme qu'on peut assigner un driver ciblé (pas seulement un broadcast ad hoc automatique) — répond en partie à la question ouverte #2 du CLAUDE.md et dérisque l'architecture envisagée.

### 6.3 Découverte du modèle `Fleet` (code source `fleetbase/fleetops-api`, `src/Models/Fleet.php`)

Champs fillable : `company_uuid`, `service_area_uuid`, `zone_uuid`, `vendor_uuid`, `parent_fleet_uuid`, `image_uuid`, `name`, `color`, `task`, `status`, `slug`.

Relations clés :
- **`drivers()` et `vehicles()` sont des relations many-to-many** (tables pivot `FleetDriver` / `FleetVehicle`) — **un même driver peut appartenir à plusieurs Fleets simultanément**, nativement. C'est la réponse directe au problème de duplication identifié en §3.1 : pas besoin de deux profils driver déconnectés.
- **`parent_fleet_uuid`** (relation `parentFleet()`, self-référentielle) — les Fleets sont **hiérarchisables**.
- **`vendor_uuid`** (relation `vendor()`) — une Fleet peut être rattachée à un `Vendor`.

### 6.4 Découverte du modèle `Vendor` (`src/Models/Vendor.php`)

Champs fillable : `_key`, `internal_id`, `company_uuid`, `logo_uuid`, `type_uuid`, `connect_company_uuid`, `business_id`, `name`, `email`, `website_url`, `meta`, `callbacks`, `phone`, `place_uuid`, `country`, `status`, `type`, `slug`.

Relations : `place()`, `company()` (belongsTo Company), `connectCompany()` (belongsTo un **second** Company via `connect_company_uuid`), `logo()`. Représente un tiers/partenaire business dans le système. Statut par défaut `active`, type par défaut `vendor`.

Le champ `type` est une chaîne libre sans logique métier associée côté backend (vérifié : aucune valeur spéciale traitée dans le modèle, juste un défaut `'vendor'`).

**Piste "Fuel Supplier" écartée** : option de type de vendor visible dans la console ("Provides fuel for vehicles"), aucune logique backend spécifique trouvée — catégorisation UI pour de vrais fournisseurs de carburant (gestion des dépenses carburant de flotte), sans rapport avec la modélisation de sous-organisation. Le type générique **"Vendor"** reste le bon choix pour représenter une sous-organisation.

**Piste `connect_company_uuid` — non concluante** : la relation existe dans le modèle, mais aucune route/méthode du `VendorController` (`getAsFacilitator()`, `getAsCustomer()`, `export()`, `bulkDelete()`, `statuses()`) ne l'utilise ou l'expose. Probablement non exploité dans la surface API actuelle, ou géré ailleurs (peut-être uniquement côté console/Ember, non vérifié). À ne pas utiliser comme base d'architecture sans démonstration concrète.

### 6.5 Découverte du `Facilitateur` (relation polymorphique sur `Order`)

Champs : `facilitator_uuid` + `facilitator_type` (cast `PolymorphicType`), relation `morphTo()`. Trois types supportés :
1. **`Vendor`** — partenaire/tiers business du système
2. **`IntegratedVendor`** — prestataire externe intégré via API (voir §6.6)
3. **`Contact`**

Accesseurs : `getFacilitatorNameAttribute()`, `getFacilitatorIsVendorAttribute()`, `getFacilitatorIsIntegratedVendorAttribute()`, `getFacilitatorIsContactAttribute()`. Méthode `isIntegratedVendorOrder()` déclenche une annulation externe via `$api->cancelFromFleetbaseOrder($this)` si applicable.

### 6.6 `IntegratedVendor` — écarté pour notre cas d'usage

Champs fillable (`src/Models/IntegratedVendor.php`) : `company_uuid`, `created_by_uuid`, `host`, `namespace`, `webhook_url`, `provider`, `sandbox`, `options`, `credentials`. Mécanisme de **pont vers un prestataire externe** via webhook/API (`IntegratedVendors::bridgeFromIntegratedVendor`, `resolverFromIntegratedVendor`, callbacks de cycle de vie).

**Conclusion** : conçu pour sous-traiter l'exécution d'une commande à un système externe indépendant (l'entreprise garde son propre dispatch, Fleetbase lui transmet juste la commande) — différent du persona "petite flotte" visé, qui doit utiliser **nos** drivers/Fleet à l'intérieur de Fleetbase avec une interface légère à nous, pas son propre système indépendant. Écarté pour ce besoin (pourrait éventuellement resservir plus tard pour un tout autre cas : un partenaire logistique totalement autonome).

### 6.7 `registry-bridge` — écarté

Package `fleetbase/registry-bridge` (vu dans `composer.json` de l'API). README : "Internal Bridge between Fleetbase API and Extensions Registry" — concerne uniquement le marketplace d'extensions (installation de FleetOps, Storefront, etc.), aucun rapport avec la connexion entre Organizations/companies. Piste écartée.

### 6.8 Architecture retenue pour les sous-organisations

- Une seule Organization Fleetbase **"Echango Delivery"**.
- Un **`Vendor`** (type générique, pas "Fuel Supplier") = une sous-organisation gérant sa propre petite flotte dédiée.
- Une **`Fleet`** liée à ce Vendor (`vendor_uuid`) = ses drivers dédiés.
- Ces mêmes drivers peuvent **aussi** appartenir à une Fleet "pool mutualisé" — many-to-many natif, **zéro duplication, zéro désync** (résout le problème du §3.1 sans avoir à construire nous-mêmes une couche d'identité driver multi-Organization).
- À la création d'une commande, `facilitator` = ce Vendor, pour exprimer explicitement quelle sous-organisation est responsable de la commande.

**Non vérifié en pratique** (prochaine étape) : créer un Vendor, une Fleet liée, y placer un driver aussi présent dans une autre Fleet, créer une commande avec ce Vendor en facilitateur et ce driver assigné, et confirmer que la console laisse faire de bout en bout.

---

## 7. Test pratique de commande — itinéraire, places, facilitateur + driver

### 7.1 Champs "Itinéraire" du formulaire de commande

- **Prise en charge** (obligatoire) / **Dépose** (obligatoire) / **Retour** (optionnel) : sélection de **Places** (adresses) déjà enregistrées, ou saisie directe d'une adresse (géocodée à la volée si Google Maps/Mapbox est configuré).
- **Déposes multiples** : toggle activant plusieurs points de dépose (tournée). **Non testé en pratique.**

### 7.2 Idée produit — pré-remplissage des adresses

Constat : dans le formulaire brut, l'utilisateur doit rechercher/sélectionner une Place à chaque commande pour la prise en charge et la dépose — friction inutile pour un commerçant qui expédie toujours depuis la même adresse.

**Idée retenue pour l'interface custom "commerçant"** (pas réalisable dans la console générique, qui ne connaît pas la notion de "magasin habituel") : pré-remplir automatiquement la **prise en charge** avec l'adresse du magasin (un `Place` Fleetbase enregistré une fois dans le profil du commerçant, réutilisé à chaque commande), et la **dépose** avec l'adresse du client (saisie une fois dans notre interface, ou récupérée plus tard depuis Echango Order via le connecteur Odoo → Fleetbase à concevoir). Le commerçant n'aurait qu'à confirmer, pas à chercher des adresses dans des dropdowns. Rien à construire côté Fleetbase pour ça — logique entièrement à notre charge, dans la couche custom.

### 7.3 Incident — Places créées non sélectionnables dans le formulaire

Deux Places créées ("AHMED", "MAGASIN1") n'apparaissaient pas dans les dropdowns du formulaire de commande. **Résolu par rafraîchissement de la page / réouverture du formulaire** — confirmé être un problème de cache frontend (liste des Places chargée en mémoire avant la création des nouvelles Places), pas un bug Fleetbase.

### 7.4 Facilitateur et driver — mutuellement exclusifs dans la console

Constat manuel : impossible de choisir un driver ET un facilitateur en même temps dans le formulaire de création de commande.

Vérification via le payload API réel (`POST /int/v1/orders`, capturé par l'utilisateur via DevTools Network) pour une commande créée avec le Vendor "vendeur1" en facilitateur :
```
facilitator_uuid: "179392a3-9e88-4d44-b6df-d4a103ec9dec"
facilitator_type: "fleet-ops:vendor"
driver_assigned_uuid: null
has_driver_assigned: false
vehicle_assigned_uuid: null
```
**Confirmé** : la console n'envoie effectivement aucun driver quand un facilitateur est choisi — absent du JSON, pas juste caché visuellement. Ceci dit, ça ne prouve que le choix de la console, pas un refus du backend si les deux étaient envoyés ensemble (vérification côté `OrderController` : aucune validation d'exclusivité mutuelle trouvée dans le code visible, mais la validation réelle est déléguée à une méthode non inspectée).

### 7.5 Assignation du driver après coup — confirmé

Test plus simple et plus concluant que de forcer une requête API manuelle : ouvrir la commande déjà créée (avec facilitateur "vendeur1") et essayer d'assigner un driver depuis la vue détail. **Confirmé : possible.**

**Conclusion retenue** : flux en deux temps qui correspond exactement à l'architecture visée (§6.8) — la commande est créée avec le facilitateur (identifie la sous-organisation responsable), puis un driver de sa Fleet lui est assigné dans un second temps, potentiellement par l'interface légère "gestionnaire de petite flotte" de cette sous-organisation.

*(Sécurité, note en passant : le payload capturé contenait un jeton `Authorization: Bearer ...` et des cookies de session — sans risque ici car instance locale, mais à ne pas partager publiquement par réflexe à l'avenir.)*

---

## 8. Réflexion produit — construire une interface custom vs. utiliser/adapter Fleetbase

Question posée : est-ce raisonnable de construire notre propre interface alors que celle de Fleetbase est très complète, et sans « casser » Fleetbase ?

**Risque de casser Fleetbase** : jugé quasi nul dans toutes les options envisagées, tant qu'on ne modifie/forke pas le code source de Fleetbase (déjà écarté dans `CLAUDE.md`, § Licence). Deux vraies options identifiées :
1. **App totalement séparée** appelant uniquement l'API REST Fleetbase (option retenue).
2. **Extension Fleetbase officielle** (à la manière de FleetOps/Storefront), réutilisant certains composants de la console.

**Recommandation retenue** : option 1. L'apprentissage de l'architecture interne de Fleetbase (Ember.js, conventions d'extension) représente un coût réel pour une petite équipe, alors que la complexité qu'on cherche justement à éviter (IAM, Ledger, Developers, gestion d'extensions) ne se trouve pas dans les écrans à reproduire (formulaire de commande + suivi, plutôt contenus). Une app Flutter (stack déjà maîtrisé via Echango Order) contre une API REST stable est jugée moins coûteuse que d'apprendre le framework interne de Fleetbase pour réutiliser quelques composants.

**Alternatives à Fleetbase (autres plateformes)** : aucune alternative solide identifiée qui soit à la fois self-hosted/open-source et compatible avec le modèle multi-tenant à pool mutualisé — la plupart des solutions plus simples d'usage (Onfleet, Bringg, Shipday, Tookan) sont des SaaS propriétaires, ce qui irait à l'encontre de la décision self-hosted déjà actée.

**FlutterFlow** : jugé un bon candidat pour accélérer la construction des interfaces custom (commerçant + petite flotte), cohérent avec le stack Flutter déjà utilisé côté Echango Order, génère du code exportable. Tradeoff : outil payant au-delà d'un usage gratuit, logique complexe (dispatch temps réel) nécessitant probablement du code custom en complément du visuel.

**Reconstruire le backend en full custom** : non recommandé. Le point de douleur réel est la console (UI), pas le moteur (dispatch, géolocalisation, gestion driver, app Navigator déjà jugée adaptée). Ne serait à reconsidérer que si un vrai blocage backend/API apparaissait, ou si le coût de la licence AGPL devenait rédhibitoire une fois chiffré sérieusement (point encore non tranché, voir `CLAUDE.md` § Licence).

---

## 9. Calcul d'itinéraire — piste OSRM (non vérifiée)

Repéré dans `scripts/docker-install.sh` (via recherche du contenu du script) : une variable **`OSRM_HOST`**, utilisée dans la configuration `.env.development`/`.env.production` de la console. OSRM = *Open Source Routing Machine*, le moteur de calcul d'itinéraire/distance qu'utilise Fleetbase. **Implication** : le calcul d'itinéraire dépend d'un service séparé (self-hosted ou pointé vers un serveur public) — **à vérifier côté installation locale** si ce service est configuré/actif, sinon distances et temps de trajet risquent d'être vides ou incorrects.

---

## 10. Process de collaboration (git)

Décision actée pendant la session : Claude Code développe désormais sur une **branche dédiée** (`claude/echango-delivery-setup-0skxbu`) et ouvre une **Pull Request** pour chaque changement, que l'utilisateur relit et merge lui-même — plutôt que de pousser directement sur `main`. PR #1 ouverte pour les premiers changements du `CLAUDE.md` (persona commerçant/petite flotte, isolation Organizations).

---

## 11. Récapitulatif — état des questions ouvertes du CLAUDE.md

1. **Granularité des permissions dans une Organization** — **tranché** (§3.3) : aucune isolation native en dessous du niveau Organization, y compris pour un compte lié à un Vendor/facilitateur. Le filtrage sera géré par notre couche BFF.
2. **Un driver Navigator peut-il recevoir des courses de plusieurs commerçants au sein d'une même Organization ?** — partiellement répondu : l'assignation ciblée d'un driver précis à une commande est confirmée possible, à la création (§6.2) comme après coup (§7.5), ce qui réduit la dépendance à la question du broadcast ad hoc natif (notre couche peut choisir elle-même le driver). Reste à tester : Navigator reçoit-il correctement une notification/course quand le driver est assigné ainsi (pas testé avec l'app mobile elle-même).
3. **Navigator est-il adaptable (rebrand/config) ?** — pas encore testé (app pas encore installée/essayée), mais architecture jugée encourageante (§4 : app mono-usage, pas un panel admin).

## 12. Backlog restant (prochaines actions concrètes)

- [ ] Tester en pratique l'architecture Vendor + Fleet + Facilitator de bout en bout (§6.8) : créer un Vendor, une Fleet liée, un driver partagé entre deux Fleets, une commande avec ce Vendor en facilitateur et assignation du driver.
- [ ] Tester "Déposes multiples" (tournée à plusieurs arrêts) en pratique.
- [ ] Vérifier la configuration OSRM (§9) et si le calcul d'itinéraire fonctionne réellement en local.
- [ ] Installer et tester l'app Navigator avec un compte driver réel (question ouverte #3).
- [ ] Vérifier si un driver assigné via Fleet/Facilitateur (plutôt que directement) reçoit bien la course dans Navigator.
- [ ] Reconsidérer la nécessité de créer un compte Fleetbase par commerçant/gestionnaire de flotte (§5) — potentiellement inutile vu l'absence de scoping natif ; un compte de service unique pourrait suffire côté BFF.
- [ ] Scoper les deux interfaces custom (commerçant / gestionnaire de petite flotte) — périmètre, écrans, priorité (déjà noté dans `CLAUDE.md`).
- [ ] Rouvrir la question de la licence AGPL avant toute ouverture B2B réelle (déjà noté dans `CLAUDE.md`).
