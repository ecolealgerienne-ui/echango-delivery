# Scoping du BFF Echango Delivery (v2)

**Date** : 27 juillet 2026 (v1 le 27/07, révisée le même jour après relecture croisée par 4 agents spécialisés — architecture, sécurité, validation technique Fleetbase, fonctionnel/produit)
**Statut** : Draft de conception — v2, corrigée et complétée. Les rapports complets des 4 agents sont conservés intégralement dans `docs/rapports_specs_bff/`, ce document en est la synthèse actionnable.

Ce document scope la couche BFF (backend-for-frontend) qu'Echango construit par-dessus Fleetbase, décidée dans `docs/specs_echango_delivery.md` §4-5. Il part du principe déjà acté : le BFF est le **point d'entrée unique** pour toute écriture Fleetbase (interfaces custom + futur connecteur Odoo), il détient les identifiants Fleetbase, jamais exposés aux clients finaux.

---

## 1. Constat structurant : deux personas, deux stratégies d'accès Fleetbase différentes

C'est la découverte la plus importante des tests pratiques et elle conditionne tout le reste de ce document.

`fleetbase/customer-portal-api` (validé par test réel, `docs/specs_echango_delivery.md` §3.1) scope ses commandes sur le champ **`Order.customer`** — confirmé empiriquement par test, **et confirmé structurellement par lecture du code** (`docs/rapports_specs_bff/03_validation_technique.md` #1) : la méthode `PortalOrderService::queryForAccount()` ne contient littéralement aucune clause portant sur `facilitator` — ce n'est pas un résultat de test qui pourrait être un faux négatif, c'est **garanti par construction**. Une commande avec `facilitator` renseigné mais `customer` vide n'apparaîtra jamais dans `GET customer-portal/int/v1/orders`, quel que soit le scénario.

**Conséquence directe sur les deux personas identifiés dans `CLAUDE.md`** :

| Persona | Rôle Fleetbase sur la commande | Couvert par `customer-portal-api` ? |
|---|---|---|
| **Commerçant** (passe commande, suit sa livraison) | `Order.customer` | **Oui** — scoping natif validé par test et par le code |
| **Gestionnaire de petite flotte** (dispatch, voit/assigne les commandes de sa sous-org) | `Order.facilitator` | **Non, structurellement impossible** — ni côté `customer-portal-api`, ni côté IAM/console (confirmé absent, `docs/specs_echango_delivery.md` §3.1, test du compte "vendeur" qui voyait tout) |

Le BFF doit donc implémenter **deux stratégies d'accès Fleetbase distinctes** selon le persona connecté :

- **Commerçant → proxy fin vers `customer-portal-api`**, avec le token Sanctum du compte (obtenu et géré côté BFF, jamais transmis tel quel au client Flutter — voir §5).
- **Petite flotte → aucun proxy possible**, le BFF interroge FleetOps directement avec un **compte de service** (portée à définir, voir §5.2), et **filtre lui-même** les résultats par `facilitator_uuid` = le `Vendor` de la sous-organisation connectée.

**Alternative envisagée et écartée, à documenter comme un choix assumé** (`docs/rapports_specs_bff/01_architecture.md` §1) : abandonner `customer-portal-api` et construire un filtrage maison symétrique pour les deux personas, ce qui donnerait un seul modèle de sécurité à auditer au lieu de deux. Écarté parce que ça jetterait tout ce que `customer-portal-api` fournit déjà et a été validé de bout en bout (auth dédiée, carnet d'adresses scopé, hook facturation Ledger, rôle IAM "Fleet-Ops Customer" dédié, URL de suivi public). **Recommandation d'implémentation pour limiter le coût de cette asymétrie** : encapsuler les deux stratégies derrière un port/interface interne unique côté BFF (ex. `OrderAccessPort` avec deux implémentations, `CustomerPortalAdapter` et `FacilitatorFilteredAdapter`) — garde le bénéfice de `customer-portal-api` tout en donnant aux contrôleurs/DTOs/tests une vue symétrique des deux personas.

**Évolution future possible, hors MVP** : construire côté Fleetbase un vrai "facilitator-portal" (extension PHP interne, à la manière de `customer-portal`) qui filtrerait en base via `vendorPersonnel` plutôt que "fetch large + filtre applicatif" côté BFF externe. Rapprocherait le filtrage de la donnée. Disproportionné pour le MVP.

---

## 2. Modèle de comptes / provisioning

### 2.1 Persona commerçant — via `customer-portal-api`

Chaîne validée par test réel (`docs/specs_echango_delivery.md` §3.1) :

1. Un `User` Fleetbase avec **`type='customer'`** (champ `$guarded`, pas assignable en masse — `forceFill()` ou équivalent requis dans le code de provisioning).
2. Un `Contact` Fleetbase avec **`type='customer'`** et `user_uuid` pointant vers ce `User` (idem, `$guarded`).
3. Ce `Contact` doit être rattaché comme personnel actif du `Vendor` (table `vendorPersonnel`) pour un accès à l'échelle du Vendor.
4. Email à vérifier (`email_verified_at`) avant login possible.
5. Login via `POST customer-portal/int/v1/auth/login` → token Sanctum scopé à ce compte.

**Qui déclenche ce provisioning ?** Pas encore tranché — self-service (le BFF orchestre les 5 étapes avec un compte de service à privilège suffisant) vs provisioning manuel par Echango (aligné avec l'onboarding pilote attendu). **Recommandation inchangée** : commencer manuel, automatiser seulement si le volume le justifie.

### 2.2 Persona petite flotte — Option A retenue définitivement

**Décision tranchée** (27/07/2026, suite à vérification par 2 agents indépendants — `docs/rapports_specs_bff/01_architecture.md` §3 et `03_validation_technique.md` #2) : **Option A — compte Echango pur, aucun `User` Fleetbase dédié.** Le BFF gère sa propre table de comptes, mappée à un `vendor_uuid` Fleetbase. L'authentification est entièrement côté BFF. Le BFF utilise son compte de service pour interroger FleetOps et filtre par `facilitator_uuid`.

**Important — cette décision n'est PAS motivée par ce qu'affirmait la v1 de ce document.** La v1 supposait qu'aucun mécanisme de rattachement `User`↔`Vendor` n'existait côté facilitateur ("Option B non vérifiable"). C'est **factuellement faux** : `vendorPersonnel` est une brique **générique** de FleetOps (pas propre à `customer-portal`), avec un champ `role` en chaîne libre — rattacher un `Contact` à un `Vendor` avec un rôle "facilitateur" est techniquement possible dès aujourd'hui (confirmé par lecture directe de `Vendor.php`/`VendorPersonnel.php`/`VendorController.php`). **L'Option B est techniquement faisable.**

**La vraie raison de retenir l'Option A quand même** : `OrderController` (l'API console classique) n'a aucune Policy/`authorize()` sur les lectures, et aucune barrière n'existe en dessous du niveau Organization (déjà confirmé, `docs/specs_echango_delivery.md` §3.1). Le rôle IAM "restreint" qu'utiliserait l'Option B n'a **jamais été confirmé comme réellement appliqué** — contrairement au rôle "Fleet-Ops Customer" de `customer-portal`, testé et validé de bout en bout. Créer un vrai `User` Fleetbase pour la petite flotte crée donc un **credential Fleetbase valide supplémentaire**, capable en théorie de s'authentifier directement contre l'API Fleetbase (pas seulement via le BFF) et de voir potentiellement toute l'Organization en cas de fuite ou de mauvaise isolation. L'Option A n'a structurellement pas ce mode de défaillance : son seul jeton est un Bearer Echango, inutilisable directement contre Fleetbase même en cas de fuite totale. **Minimiser le nombre de credentials Fleetbase réellement authentifiables est en soi un contrôle de sécurité**, dans un contexte d'Organization unique sans barrière d'autorisation confirmée en dessous.

---

## 3. Surface API — interface commerçant

Le BFF traduit les endpoints déjà validés de `customer-portal-api` (`docs/rapports_specs/05_validation_technique_fleetbase.md`, liste complète) vers des contrats Echango stables (DTOs, §6). Endpoints pour le MVP (formulaire commande + suivi, `CLAUDE.md`) :

- `POST /commercant/commandes` → `POST customer-portal/int/v1/orders`, avec pré-remplissage prise en charge/dépose côté BFF (idée déjà actée, `docs/journal_exploration_fleetbase.md` §7.2)
- `GET /commercant/commandes` (avec **filtre par statut et pagination**, absents de la v1) / `GET /commercant/commandes/{id}` → `GET orders` / `GET orders/{id}`, incluant dans le DTO le **statut détaillé + raison en cas d'échec de livraison** et la **preuve de livraison** (signature/photo, déjà exposée nativement côté Fleetbase mode POD)
- `POST /commercant/commandes/{id}/annuler` → `POST orders/{id}/cancel`
- `POST /commercant/device-token` — enregistrement d'un jeton push, pour déclencher une **vraie notification** au commerçant sur changement de statut (créé, pris en charge, en route, livré, échec) plutôt que du polling passif uniquement (manque MVP identifié, `docs/rapports_specs_bff/04_fonctionnel.md` §1)
- `GET /commercant/adresses` / `POST /commercant/adresses` — **ressource Fleetbase sous-jacente non tranchée** (`address-book` vs `places`) : ne pas laisser cette ambiguïté ouverte jusqu'à l'implémentation, **spike dédié à faire avant de coder cet endpoint**
- `GET /commercant/factures` → `GET invoices` (si Ledger activé — optionnel, décision différée §3.4 de `specs_echango_delivery.md`)

**Suivi temps réel** (position du driver sur une commande en cours) — **remonté en priorité par la revue architecture**, c'est un des deux piliers du MVP annoncé (« formulaire + suivi »), pas un simple détail. `customer-portal` expose une URL de suivi public native (`{CONSOLE_HOST}/track-order?order={tracking_number}`, confirmée `docs/rapports_specs_bff/03_validation_technique.md` #5) — potentiellement suffisant pour l'interface commerçant sans réinventer un endpoint dédié. **Réserve à documenter** : le `tracking_number` est généré via `mt_rand` (PRNG non cryptographique, 10 chiffres) — ce n'est **pas** un jeton sécurisé au sens strict, plutôt un identifiant obscur mais potentiellement énumérable, surtout combiné à un préfixe de société prévisible. À évaluer avant de s'y fier pour un accès censé être privé (voir aussi question ouverte §8).

---

## 4. Surface API — interface petite flotte

Tout est à construire côté BFF (pas de proxy possible, §1). Endpoints pour la "vue dispatch minimaliste" (`CLAUDE.md`) :

- `GET /flotte/commandes` (avec **filtre par statut et pagination**) — liste des commandes où `facilitator_uuid` = le Vendor de la sous-organisation connectée
- `GET /flotte/commandes/{id}` — **détail d'une commande**, ajouté (manquant en v1) : adresses, contact client, instructions, nécessaire avant d'assigner un driver en connaissance de cause
- `GET /flotte/drivers` — liste des drivers de la `Fleet` liée à ce Vendor, **incluant le statut de disponibilité** (`online`/occupé — pas seulement une coordonnée GPS, manque MVP identifié comme plus important que la position elle-même pour dispatcher intelligemment, `docs/rapports_specs_bff/04_fonctionnel.md` §2)
- `GET /flotte/drivers/positions` — **positions groupées de tous les drivers de la Fleet en un seul appel**, ajouté (un appel par driver ne scale pas pour l'écran carte, identifié comme le plus exigeant des deux interfaces custom)
- `POST /flotte/drivers` — **formalisé comme endpoint à part entière** (relégué en aparté dans la v1) : provisioning d'un driver dans la Fleet. Implémentation : relation `Fleet.drivers()` en `hasManyThrough` (pas `belongsToMany`, confirmé par le code — `docs/rapports_specs_bff/03_validation_technique.md` #3), donc pas d'`attach()/sync()` Eloquent standard. Fleetbase lui-même gère ça via création directe d'un enregistrement `FleetDriver` avec vérification d'existence préalable (exemple exact trouvé dans `FleetController.php`, pattern à reproduire).
- `POST /flotte/commandes/{id}/assigner` — assigne un driver précis à une commande (`driver_assigned_uuid`), confirmé possible après création (`docs/specs_echango_delivery.md` §7.5)

**Dépendance non signalée en v1, à traiter comme un risque de blocage MVP** (`docs/rapports_specs_bff/01_architecture.md` §2) : aucune progression de statut de commande (dispatched → started → enroute → completed) n'est utilisable en pratique côté flotte sans un client qui la pilote (Navigator, ou la console). Or **Navigator n'est toujours pas installé/testé** (question ouverte #3 du `CLAUDE.md`, non tranchée). Tant que ce point n'est pas résolu, l'interface "petite flotte" ne pourra afficher qu'un état statique (assigné/pas assigné), pas une vraie vue dispatch en temps réel — **à traiter en priorité avant de committer sur le périmètre exact du MVP flotte.**

**Point non couvert, à vérifier** : que se passe-t-il si le driver assigné ne répond pas/refuse ? Contrairement au mode `adhoc` (qui relance automatiquement toutes les ~4 minutes), rien ne dit si une assignation ciblée a un mécanisme d'accusé de réception ou de timeout — à vérifier côté Fleetbase, et à combler côté BFF si absent (statut "à réassigner" minimum).

**Question ouverte non technique, déjà notée** (`docs/specs_echango_delivery.md` §9 priorité 3, item 9) : un driver de la Fleet dédiée peut-il refuser d'être visible/assignable par cette interface s'il est aussi dans le pool mutualisé ? Aucune règle native — à spécifier. Nécessitera un mécanisme de préférence/consentement porté par le BFF (lié au §5 driver ci-dessous).

---

## 5. Authentification et gestion des identifiants côté BFF

Le BFF expose **un seul système d'authentification Echango** aux deux interfaces custom (Bearer token Echango, pas les tokens Fleetbase/Sanctum bruts) — les clients Flutter ne voient jamais la mécanique Fleetbase sous-jacente.

### 5.1 Token Sanctum par compte commerçant

En interne, le BFF détient/gère le token Sanctum `customer-portal` du compte. Ceci nécessite, précisé suite à la revue sécurité (`docs/rapports_specs_bff/02_securite.md` §1), des mécanismes non spécifiés en v1 :
- **Stockage chiffré au repos** — une fuite de cette table donne accès à *tous* les comptes commerçants d'un coup, pas à un seul (Sanctum ne propose pas nativement de "refresh token" ; un Personal Access Token est valide indéfiniment sauf expiration configurée explicitement).
- **Mécanisme de renouvellement explicite** à concevoir (ré-authentification documentée ou expiration + tâche planifiée) — "rafraîchi si besoin" n'est pas un mécanisme, c'est un vœu.
- **Révocation active** déclenchée par un événement métier explicite (départ/suspension d'un commerçant), pas laissée implicite.

### 5.2 Compte de service pour le persona petite flotte

**Élevé en décision de conception de premier rang** (pas une question différée comme en v1, suite à la revue sécurité) : le nombre et la portée exacte du/des compte(s) de service Fleetbase doivent être tranchés avant implémentation, en reprenant explicitement les mitigations déjà recommandées ailleurs (`docs/rapports_specs/01_securite.md` §4a) comme **prérequis, pas options** : coffre-fort dédié, envisager plusieurs `ApiCredential` scopés plutôt qu'une seule clé "god mode", rotation régulière, isolation réseau stricte (Fleetbase joignable uniquement depuis le BFF).

**Ce qui fuiterait en cas de compromission de ce compte** (à garder à l'esprit pour dimensionner l'effort de protection) : accès complet en lecture/écriture à toute l'Organization — commandes de tous les commerçants (PII clients), tous les drivers/véhicules, l'historique de position à haute fréquence de la table `Position`, tous les Vendors — un rayon d'action équivalent à un accès admin complet de la console.

**⚠️ Hypothèse ci-dessus invalidée par test réel (28/07/2026)** : contrairement à ce qui était supposé, `GET /orders?facilitator_uuid=...` et `GET /drivers?vendor_uuid=...` sont **ignorés côté serveur** — vérifié empiriquement en comparant les résultats avec un filtre valide vs un filtre inexistant/aléatoire : les deux renvoient exactement le même jeu de données, celui de toute la compagnie. Il n'y a **aucun filtrage serveur** à pousser en base sur ces deux paramètres ; le "fetch-all puis filtrer en mémoire" écarté ci-dessus est en réalité la **seule** option sûre. Détail complet du test et de l'implication de sécurité : `docs/journal_implementation_bff.md` §2.8. **Le fetch-all + filtrage applicatif strict côté BFF (jamais de confiance dans un paramètre de query Fleetbase) est donc la méthode retenue et implémentée dans `flotte.service.ts`**, avec la même revalidation d'appartenance en défense en profondeur déjà prévue ici pour chaque ligne renvoyée au client.

### 5.3 Exigences transversales ajoutées suite à la revue sécurité

- **Journalisation applicative comme source d'attribution unique.** Fleetbase utilise `spatie/laravel-activitylog` : si les écritures "petite flotte" transitent par un compte de service partagé, les journaux **côté Fleetbase** n'attribueront jamais l'action à l'utilisateur réel. Le BFF doit donc être la seule source de vérité pour "qui a fait quoi" (identité Echango, IP, horodatage, ressource) — exigence dure, pas optionnelle.
- **Anti-IDOR systématique.** Chaque endpoint paramétré par `{id}` (§3, §4) doit vérifier explicitement l'appartenance de la ressource ciblée au compte connecté avant toute lecture/action — pas seulement le filtrage des listes. Tests automatisés anti-IDOR en CI ("le facilitateur A ne peut jamais agir sur une ressource du facilitateur B") comme condition de merge. Logging systématique des accès refusés.
- **Rate limiting propre aux endpoints du BFF**, indépendant du rate limiting interne Fleetbase — en particulier sur les flux de login/provisioning, exposés au brute-force.
- **Bearer-only, jamais de cookie de session.** À figer explicitement dès maintenant : les deux interfaces custom seront en Flutter pur (décision du 27/07/2026, plus de FlutterFlow — voir `docs/specs_echango_delivery.md` §8), potentiellement déployées en Flutter web pour l'interface "petite flotte" — poser cette contrainte maintenant neutralise structurellement le risque CSRF sans avoir à y revenir plus tard.
- **Interdiction de relayer des paramètres de filtre fournis par le client directement vers Fleetbase.** Le BFF construit toujours lui-même la requête serveur à partir de l'identité authentifiée, jamais à partir d'un paramètre transmis par le client — sans quoi c'est une deuxième voie de contournement du scoping, indépendante du filtrage applicatif décrit en §1/§5.2.
- **Modèle de compte extensible pour un même identifiant portant plusieurs rôles** (`docs/rapports_specs_bff/04_fonctionnel.md` §3) : un même Vendor peut être `customer` sur certaines commandes et `facilitator` sur d'autres (confirmé, `docs/specs_echango_delivery.md` §4) — un commerçant qui grossit et embauche des livreurs dédiés est un chemin de croissance plausible, pas hypothétique. Le modèle de compte Echango (§2) devrait être pensé comme **un identifiant associé à un ou plusieurs profils** (rôle + `vendor_uuid`), pas deux systèmes de comptes complètement cloisonnés — pas un développement à prioriser pour les 3-5 pilotes, mais une contrainte de design à poser dès maintenant pour éviter un refactor plus coûteux.

Ce choix isole complètement les clients Flutter des identifiants Fleetbase, cohérent avec l'objectif produit d'une future **API publique Echango** pour développeurs tiers (§5 de `docs/specs_echango_delivery.md`) — ce sera la même couche d'auth Echango à étendre.

---

## 6. Normalisation des données Fleetbase — DTOs obligatoires

Piège concret déjà rencontré et documenté (`docs/specs_echango_delivery.md` §3.1) : la console Fleetbase peut écrire `customer_type`/`facilitator_type` dans un format incohérent (backslash initial en trop) qui casse silencieusement le scoping de `customer-portal-api`.

**Portée à étendre significativement** (revue sécurité, `docs/rapports_specs_bff/02_securite.md` §4) : ce n'est pas un incident isolé sur `Order`. Le cast Eloquent `PolymorphicType` (`fleetbase/core-api`) est appliqué à une douzaine de champs — au minimum, dans le périmètre probable du BFF : `Waypoint.customer_type` (pickup/dépose), `Place.owner_type` (carnet d'adresses commerçant), `Entity.customer_type` (items du payload), `PurchaseRate.customer_type` (facturation, si Ledger activé). **Preuve que c'est systémique, pas un accident** : Fleetbase embarque une commande Artisan de remédiation dédiée, `FixInvalidPolymorphicRelationTypeNamespaces`, qui corrige ce type de valeur malformée sur au moins 5 modèles (`Order`, `Place`, `Entity`, `PurchaseRate`, `Device`) — preuve que les mainteneurs eux-mêmes savent que ce bug se produit régulièrement.

**Règles à appliquer, étendues à tous ces champs, pas seulement `Order`** :
- Toute écriture doit passer par une normalisation systématique (utiliser l'alias court `fleet-ops:vendor`, confirmé être la pratique du code Fleetbase lui-même — jamais construire la chaîne à la main).
- Toute lecture doit être tolérante aux deux formats (avec/sans backslash, alias court).
- **Centraliser cette normalisation dans un module unique du BFF**, réutilisé par tout endpoint touchant un champ polymorphique — pas une règle répétée field-by-field, pour éviter une divergence future.
- Envisager de faire tourner (ou répliquer côté Echango) `FixInvalidPolymorphicRelationTypeNamespaces` comme vérification de santé périodique sur l'Organization partagée, en signal d'alerte précoce.
- Plus largement : les interfaces custom et le futur connecteur Odoo ne doivent **jamais** voir un nom de champ ou une valeur Fleetbase brute — le BFF traduit systématiquement vers des DTOs Echango stables.

---

## 7. Ce qui reste à construire vs ce que Fleetbase fournit déjà

| Besoin | Fourni nativement | À construire côté BFF |
|---|---|---|
| Scoping des commandes — commerçant | ✅ `customer-portal-api` | Provisioning du compte, DTOs, pré-remplissage adresses, notifications |
| Scoping des commandes — petite flotte | ❌ Aucun mécanisme natif (confirmé structurellement) | Filtrage complet par `facilitator_uuid`, avec compte de service, vérification d'appartenance par endpoint |
| Auto-dispatch par proximité | ✅ mode `adhoc` natif, validé par test | Scoping par Fleet si besoin (le natif n'est pas filtré par Fleet) |
| Assignation ciblée d'un driver | ✅ confirmé possible | Gestion du refus/timeout (mécanisme natif non confirmé) |
| Partage d'un driver entre pool mutualisé et flotte dédiée | ✅ relation `Fleet↔Driver` (many-to-many au niveau données, `hasManyThrough` côté Eloquent) | Règles de priorité/consentement (aucune native), provisioning via `FleetDriver::create()` |
| Facturation commerçant | ✅ si Ledger activé (`PurchaseRateObserver`) | Décision différée — Odoo reste recommandé comme source de vérité |
| Calcul de commission | ❌ absent de Ledger | Entièrement à construire, une fois le modèle de tarification tranché ; **exposition au driver (gains) uniquement possible via le BFF, aucun autre endroit ne peut le faire** |
| Notification temps réel commerçant | ❌ pas de canal `database`/persistant côté Fleetbase pour ce type d'usage | Device token + consommateur d'événements de statut côté BFF |
| Statut de disponibilité driver (vue flotte) | Partiel (`online`/`status` existent sur `Driver`) | Endpoint dédié agrégeant disponibilité + position |

---

## 8. Questions ouvertes avant implémentation

1. **Qui provisionne les comptes commerçant** (self-service vs manuel) — §2.1, lié à la question métier #9 déjà listée.
2. ~~**Option A vs B pour le compte petite flotte**~~ **Tranché (27/07/2026)** : Option A, voir §2.2.
3. **Le suivi de commande** : l'URL de suivi public native de Fleetbase suffit-elle pour l'interface commerçant, ou faut-il un endpoint BFF dédié avec plus de contrôle ? **Nouvelle réserve à trancher dans le même mouvement** : le `tracking_number` n'est pas un jeton cryptographique (`mt_rand`, potentiellement énumérable) — acceptable pour un partage volontaire (« voici le lien de suivi de votre colis ») mais pas pour un accès qu'on voudrait garantir privé.
4. **Compte(s) de service Fleetbase** : un seul à privilège large, ou plusieurs scopés ? Élevé en décision de premier rang (§5.2), toujours pas tranché faute d'avoir testé ce que permet réellement l'IAM Fleetbase pour une clé API.
5. **Ambiguïté `address-book` vs `places`** (§3) : à résoudre par un spike avant de coder l'endpoint carnet d'adresses.
6. **Dépendance Navigator pour la progression de statut côté flotte** (§4) : bloquant potentiel pour le périmètre exact du MVP flotte tant que la question ouverte #3 du `CLAUDE.md` (adaptabilité de Navigator) n'est pas tranchée.
7. **Modèle de compte multi-rôles** (§5.3) : un identifiant Echango unique portant plusieurs profils (commerçant + petite flotte) — à poser comme contrainte de design maintenant, développement différé.
8. **Mécanisme d'accusé de réception/timeout sur une assignation ciblée** (§4) : à vérifier côté Fleetbase avant de considérer l'assignation manuelle fiable pour le MVP flotte.
9. Toutes les règles métier de `docs/specs_echango_delivery.md` §6 restent bloquantes pour finaliser les DTOs de facturation/tarification, même si l'architecture technique du BFF peut avancer sans elles pour la partie commande/dispatch.

---

## Annexes

- `docs/specs_echango_delivery.md` — synthèse technique consolidée (source des faits validés utilisés ici)
- `docs/rapports_specs/` — rapports détaillés des 5 agents de la revue de specs initiale
- `docs/rapports_specs_bff/` — rapports détaillés des 4 agents de la revue de ce document (architecture, sécurité, validation technique, fonctionnel)
- `docs/journal_exploration_fleetbase.md` — journal détaillé des tests
- `CLAUDE.md` — contexte produit et décisions
