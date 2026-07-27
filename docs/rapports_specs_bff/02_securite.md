# Rapport agent — Revue sécurité de `docs/specs_bff.md`

*Produit par un agent spécialisé sécurité, le 27 juillet 2026, en complément de `docs/rapports_specs/01_securite.md`. Reproduit ici intégralement pour traçabilité — la synthèse est intégrée dans `docs/specs_bff.md`.*

---

## Constat général

`specs_bff.md` reprend correctement le **principe** de plusieurs recommandations de `01_securite.md` (jamais transmettre le compte de service à un frontend, filtrer après récupération plutôt qu'en confiance dans la requête). Mais sur les points les plus critiques — gestion des tokens, compte de service, anti-IDOR — le document **cite** les recommandations sans les **opérationnaliser** : elles restent des renvois de pointeur, pas des décisions de conception concrètes avec un mécanisme, un propriétaire, un test.

## 1. Gestion du token Sanctum par compte commerçant (§5)

**Sous-spécifié.** Aucun mécanisme décrit pour : **stockage** (chiffrement au repos ? — une fuite de cette table donne accès à *tous* les comptes commerçants d'un coup) ; **expiration/rafraîchissement** (Sanctum ne définit pas de "refresh token" — un Personal Access Token est valide indéfiniment sauf `config('sanctum.expiration')` positionné ou révocation explicite ; "rafraîchi si besoin" ne correspond à aucun mécanisme Sanctum standard) ; **révocation** (rien sur l'offboarding).

**Risques concrets** : token périmé non rafraîchi → panne silencieuse imprévisible ; token stocké en clair → fuite équivaut à une fuite de *tous* les accès customer-portal simultanément ; token jamais révoqué → identifiant dormant valable indéfiniment.

**Recommandation** : ajouter à §5 (a) chiffrement au repos, (b) mécanisme concret de renouvellement, (c) événement de révocation explicite déclenché par le départ/la suspension d'un commerçant.

## 2. Compte de service à privilège large (persona "petite flotte")

**Écart net avec `01_securite.md` §4a**, qui faisait 5 recommandations (coffre-fort, plusieurs `ApiCredential` scopés plutôt qu'une clé "god mode", rotation, traiter la clé comme faible tant que l'entropie Sqids n'est pas vérifiée + isolation réseau, jamais transmis à un frontend). `specs_bff.md` §5 ne reprend que le dernier point. **Incohérence interne** : §8 liste "un seul compte à privilège large ou plusieurs scopés" comme question ouverte jamais testée, alors que §1/§5/§7 présentent déjà cette architecture comme acquise.

**Ce qui fuiterait exactement en cas de compromission** (non quantifié dans le document) : accès complet en lecture/écriture à toute l'Organization — toutes les commandes de tous les commerçants (PII), tous les drivers/véhicules, l'historique de position à haute fréquence, tous les Vendors — un rayon d'action équivalent à un accès admin complet.

**Recommandation** : ne pas figer "compte de service unique à privilège large" comme architecture cible tant que la question n'est pas résolue ; traiter les 4 mitigations manquantes de `01_securite.md` §4a comme prérequis bloquants, pas options.

## 3. Filtrage "maison" par `facilitator_uuid` — risque IDOR

Le principe correct est mentionné mais sans les 4 mitigations compagnes de `01_securite.md` §4b (tests anti-IDOR en CI, modèle de menace explicite, logging des accès refusés, revue de code systématique) — aucune n'apparaît dans `specs_bff.md`. Alors que ce filtrage était qualifié de *"risque structurant de toute l'architecture"*.

**Point supplémentaire non couvert** : les endpoints par ID unique (`POST /flotte/commandes/{id}/assigner`, `GET /flotte/drivers/{id}/position`) ont besoin de leur **propre vérification explicite d'appartenance**, pas seulement le filtrage de liste.

**Recommandation** : ajouter (a) vérification d'appartenance systématique sur chaque endpoint `{id}`, (b) tests anti-IDOR en CI, (c) logging des accès refusés.

## 4. Normalisation `customer_type`/`facilitator_type` (§6) — insuffisante en portée

Vérifié dans le code : le cast Eloquent `PolymorphicType` (`fleetbase/core-api/src/Casts/PolymorphicType.php`) est appliqué à bien plus de champs que les seuls `Order.customer_type`/`facilitator_type` : `Waypoint.customer_type`, `Entity.customer_type`, `Place.owner_type`, `PurchaseRate.customer_type`, `Transaction.customer_type/payer_type/subject_type/context_type`, `Position.subject_type`, `TrackingNumber.owner_type`, et d'autres.

**Preuve que c'est systémique** : Fleetbase embarque une commande Artisan de remédiation, `FixInvalidPolymorphicRelationTypeNamespaces` (`fleetbase/fleetops/server/src/Console/Commands/`), qui corrige ce type de valeur malformée sur `Order`, `Place`, `Entity`, `PurchaseRate`, `Device` — au moins 5 modèles.

Le périmètre du BFF va très probablement toucher `Waypoint.customer_type` (pickup/dépose), `Place.owner_type` (carnet d'adresses), `Entity.customer_type` (items), `PurchaseRate.customer_type` (facturation) — aucun couvert par §6 actuel, qui ne cite que `Order`.

**Recommandation** : (1) étendre §6 à ces quatre champs, (2) centraliser la normalisation dans un module unique réutilisé partout, (3) ne jamais construire ces chaînes à la main côté BFF, (4) envisager de faire tourner/répliquer `FixInvalidPolymorphicRelationTypeNamespaces` comme vérification de santé périodique.

## 5. Risques omis dans le document

- **Attribution d'audit perdue à cause du compte de service partagé** — risque le plus significatif non identifié. Fleetbase utilise `spatie/laravel-activitylog`. Si toutes les écritures "petite flotte" transitent par le compte de service, les logs côté Fleetbase n'attribueront les actions qu'à ce compte, pas à l'utilisateur réel. Le BFF doit être la seule source de vérité pour "qui a fait quoi" — exigence dure absente du document.
- **Révocation d'accès à l'offboarding** : absente.
- **Rate limiting sur l'API BFF elle-même** : rien sur les endpoints Bearer-token du BFF, en particulier les flux de login/provisioning exposés au brute-force.
- **CSRF** : risque faible en Bearer token pur, mais l'interface "petite flotte" n'a pas de techno figée (spike FlutterFlow peut produire une app web) — il faut figer explicitement Bearer-header uniquement, jamais cookie de session.
- **Gestion multi-device/session** : pas clair si un seul token Fleetbase est partagé entre toutes les sessions Echango d'un même commerçant.
- **Injection de filtres via paramètres client** : si le BFF relaie des paramètres fournis par le client vers Fleetbase plutôt que de construire lui-même la requête, c'est une deuxième voie de contournement du scoping — à interdire explicitement.

## Synthèse actionnable

1. §5 — stockage chiffré, mécanisme de renouvellement Sanctum, révocation à l'offboarding.
2. §5/§8 — ne pas présenter "compte de service unique" comme acquis tant que non tranché ; reprendre les 4 mitigations de `01_securite.md` §4a comme prérequis.
3. §4 — vérification d'appartenance par endpoint `{id}`, tests anti-IDOR en CI, logging des accès refusés.
4. §6 — étendre la normalisation à `Waypoint`/`Place`/`Entity`/`PurchaseRate`, centraliser, interdire la construction manuelle.
5. Ajouter : journalisation applicative comme source d'attribution unique, révocation/offboarding, rate limiting BFF, contrainte Bearer-only, interdiction de relayer des filtres client bruts.

**Fichiers consultés** : `CLAUDE.md`, `docs/rapports_specs/01_securite.md`, `docs/specs_bff.md`, code source public `fleetbase/fleetops` (`Order.php`, `Waypoint.php`, `Entity.php`, `Place.php`, `PurchaseRate.php`, `FixInvalidPolymorphicRelationTypeNamespaces.php`) et `fleetbase/core-api` (`PolymorphicType.php`, `Transaction.php`).
