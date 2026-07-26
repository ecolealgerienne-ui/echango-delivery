# Rapport agent — Sécurité

*Produit par un agent spécialisé sécurité applicative, le 26 juillet 2026, en relecture de `CLAUDE.md` et `docs/journal_exploration_fleetbase.md`, avec vérification croisée du code source public de Fleetbase. Reproduit ici intégralement pour traçabilité — la synthèse priorisée est dans `docs/specs_echango_delivery.md`.*

---

## 0. Méthodologie et limites de vérification

J'ai relu intégralement `/home/user/echango-delivery/CLAUDE.md` et `/home/user/echango-delivery/docs/journal_exploration_fleetbase.md`, puis vérifié les mécanismes de sécurité directement dans le code source public de Fleetbase via l'API de recherche de code GitHub (accès en lecture seule, aucune modification effectuée). `docs.fleetbase.io` n'a pas été retenté (403 déjà constaté côté journal) ; le code source fait foi ici.

**Limite technique à signaler** : l'outil de recherche disponible dans cette session (`search_code`) renvoie des fragments de fichier centrés sur les mots-clés recherchés, pas le fichier complet — l'accès direct au contenu intégral des repos `fleetbase/*` était bloqué pour cette session (restriction de périmètre, seul `ecolealgerienne-ui/echango-delivery` est « attaché »). Les constats ci-dessous sont donc fondés sur des extraits de code réels (noms de classes, signatures, migrations, config), mais certains points (notamment la validation des webhooks entrants IntegratedVendor) n'ont pas pu être tracés jusqu'à une preuve à 100 % exhaustive — signalé explicitement où c'est le cas, plutôt que présenté comme confirmé.

## 1. Correction à apporter au journal (fait vérifié)

Le journal (§3.3, §6.3–6.6) cite le code source dans **`fleetbase/fleetops-api`**. Vérification faite : ce repo existe bien, mais **il est archivé** (`archived: true`, dernière mise à jour avril 2025). Le code actif et maintenu est dans **`fleetbase/fleetops`** (non archivé, dernière mise à jour juillet 2026), avec une arborescence différente (`server/src/Models/...` au lieu de `src/Models/...`). J'ai retrouvé tous les éléments cités dans le journal (`Fleet.php`, `Vendor.php`, `IntegratedVendor.php`, la relation polymorphique `facilitator`, l'exclusivité driver/facilitateur) dans le repo actif `fleetbase/fleetops` — **le contenu technique du journal reste donc correct**, seule la référence de repo est obsolète. À corriger dans le `CLAUDE.md`/journal pour éviter qu'une future recherche de code reparte sur le mauvais repo (archivé, non maintenu — un audit de sécurité qui s'y fierait manquerait les correctifs récents).

> **⚠️ Contradiction entre agents à noter** : l'agent « Validation technique Fleetbase » (rapport 05) continue de citer `fleetbase/fleetops-api` comme « la branche main v1.2.0, celle que l'équipe déploierait aujourd'hui » sans mentionner d'archivage. Voir `docs/specs_echango_delivery.md` § Contradictions à vérifier.

## 2. Authentification API Fleetbase — ce que le code confirme

- Fleetbase utilise **Laravel Sanctum** (`laravel/sanctum` en dépendance, `config/sanctum.php`, guard `sanctum` appliqué à tous les modèles IAM — `Role`, `User`, `CompanyUser`, `Policy`). Deux mécanismes d'authentification coexistent : jetons Sanctum (session console / utilisateurs) et un modèle **`ApiCredential`** dédié (table `api_credentials`, colonnes confirmées : `company_uuid`, `user_uuid`, `key`, `secret`, `test_mode`, `expires_at`).
- **Scoping par Organization confirmé au niveau code** (pas seulement par la migration citée dans le journal) : `DeveloperSearchController` filtre explicitement par `ApiCredential::where('company_uuid', session('company'))`, et `DeveloperMetricsController` compte les clés actives par `company_uuid`. C'est cohérent avec l'hypothèse d'architecture (clés scopées par Organization).
- **Point d'attention concret trouvé dans le code** : `ApiCredential::generateKeys($encode, $testKey)` génère les clés via `Sqids::encode($encode)` — **Sqids est une bibliothèque d'obfuscation d'ID réversible, pas un générateur cryptographique de secrets**. Le seed (`$encode`) vu dans `ApiCredentialObserver::created()` est construit à partir de `strtotime($apiCredential->created_at)` concaténé à l'`id` de l'enregistrement — donc dérivé d'un **horodatage + identifiant incrémental**, pas d'une source d'entropie aléatoire forte (type `random_bytes`/`Str::random`). Je n'ai pas pu lire le corps complet de la fonction (limite d'accès décrite en §0) pour confirmer si le `secret` final est simplement cet encodage Sqids ou s'il subit un traitement cryptographique supplémentaire en aval — **à vérifier explicitement avant toute mise en production**, car si le secret API dérive directement d'un timestamp de création + un ID de séquence, il devient potentiellement prévisible/reconstituable (surtout si la date de création de l'Organization est connue ou devinable à quelques secondes près). Recommandation : demander confirmation à l'éditeur ou tester en local la variance réelle entre deux clés générées à quelques secondes d'écart.
- **Rate limiting existe nativement** : middleware `Fleetbase\Http\Middleware\ThrottleRequests`, appliqué aux groupes de routes API (`fleetbase.api`, `fleetbase.platform-api`) et aux routes d'authentification publiques. Configurable via `config/api.php` (`THROTTLE_ENABLED`, activé par défaut) avec un mécanisme de **bypass explicite par clé API** (`THROTTLE_UNLIMITED_API_KEYS`) — utile pour nos propres appels BFF→Fleetbase à fort volume, mais **à auditer avec prudence** : toute clé placée dans cette liste de bypass devient un vecteur de déni de service si elle fuite (plus de limite du tout).
- **CORS** : géré de façon standard Laravel (`Illuminate\Http\Middleware\HandleCors`, `config/cors.php` dans `fleetbase/fleetbase`), configurable via variable d'environnement `CONSOLE_HOST`. Le script d'installation officiel (`docker-install.sh`) a une étape dédiée « Security & CORS Configuration » — donc pas de config CORS figée en dur, mais dépend de ce qui est réellement saisi à l'installation (non vérifiable en sandbox, cohérent avec la limite déjà notée dans `CLAUDE.md`).

## 3. Webhooks — deux mécanismes distincts à ne pas confondre

Le code révèle **deux systèmes de webhooks différents**, pertinents différemment pour Echango Delivery :

1. **`WebhookEndpoint` (sortant, Fleetbase → tiers)** : une Organization peut enregistrer une URL pour recevoir les événements de cycle de vie de ses ressources. Signature confirmée dans le code : `DefaultSigner::sign()` calcule `hash_hmac('sha256', $payloadJson, $secret)` (package `spatie/laravel-webhook-server`). **C'est un point positif** : si notre BFF s'abonne à ces webhooks Fleetbase (au lieu de poller), il devra vérifier cette signature HMAC pour authentifier chaque appel entrant — recommandation à documenter explicitement dans les specs du BFF.
2. **`IntegratedVendor.webhook_url` (mécanisme différent, lié au provider externe)** : le code (`server/src/Models/IntegratedVendor.php`) montre que si `webhook_url` est vide à la création, Fleetbase le remplit automatiquement avec `Utils::apiUrl('listeners/' . $this->provider)` — c'est-à-dire une **URL de listener interne à Fleetbase**, pas une URL arbitraire fournie par le tiers. Autrement dit, ce champ sert probablement à indiquer *au tiers* (ex. Lalamove, dont l'intégration concrète existe dans `server/src/Integrations/Lalamove/`) où renvoyer ses callbacks de statut de commande. **Je n'ai pas pu localiser le contrôleur qui reçoit ces callbacks (`listeners/{provider}`) ni confirmer s'il valide une signature du tiers avant traitement** (les recherches ciblées sur ce contrôleur n'ont rien retourné, possiblement une limite de l'indexation de recherche plutôt qu'une absence réelle). **C'est un point à considérer comme non vérifié, potentiellement critique** : si ce endpoint de listener accepte des payloads sans authentification/signature forte, un tiers malveillant connaissant l'URL pourrait falsifier des mises à jour de statut de commande (usurpation de statut de livraison). À auditer en priorité en local avant d'envisager d'exposer un jour un mécanisme équivalent pour des transporteurs tiers.

## 4. Analyse par axe de risque

### (a) Authentification du BFF et gestion de ses identifiants de service Fleetbase

- Le BFF détiendra un (ou plusieurs) `ApiCredential` Fleetbase à privilège élevé (accès à toute l'Organization). C'est un **secret à criticité maximale** : sa fuite équivaut à un accès complet à toutes les données de tous les commerçants et transporteurs.
- Recommandations concrètes :
  - Stocker le(s) secret(s) API Fleetbase dans un coffre-fort de secrets dédié (Vault, AWS/GCP Secrets Manager, etc.), jamais en variable d'environnement en clair sur l'hôte applicatif du BFF, jamais committé.
  - Envisager **plusieurs `ApiCredential`** à portée plus réduite plutôt qu'une seule clé « god mode », si Fleetbase permet de restreindre les capacités d'une clé — à tester en local.
  - Politique de rotation régulière du secret (`ApiCredentialController::roll()` existe côté Fleetbase pour régénérer une clé).
  - Traiter cette clé comme **potentiellement plus faible qu'un token aléatoire classique** tant que le doute sur l'entropie (§2) n'est pas tranché : limiter sa portée réseau (le BFF doit être le seul appelant autorisé à joindre l'API Fleetbase, via réseau privé/VPC, pas d'exposition publique du endpoint Fleetbase lui-même).
  - Le compte de service ne doit être joignable qu'en sortie depuis le BFF (egress contrôlé), jamais transmis, même de façon indirecte, à un front-end (mobile/web).

### (b) Risque de fuite de données par bug de filtrage du BFF

C'est le risque structurant de toute l'architecture retenue, puisque **Fleetbase ne fournit aucune barrière en dessous du niveau Organization** (confirmé par les tests manuels documentés dans le journal, ET par l'absence de toute logique d'autorisation trouvée par recherche de code dans les contrôleurs FleetOps). Le filtrage par commerçant/sous-organisation devient donc **une fonction de sécurité critique développée par nous, sans filet Fleetbase derrière**.

Recommandations :
- Traiter chaque endpoint du BFF exposé à un commerçant ou un gestionnaire de flotte comme devant *prouver* le filtrage — tests automatisés dédiés (« commerçant A ne peut jamais voir/modifier une ressource de commerçant B ») exécutés en CI à chaque changement de code touchant les contrôleurs d'accès aux commandes.
- Filtrer côté BFF **après** récupération chez Fleetbase (retirer les champs/objets non autorisés), jamais uniquement côté requête.
- Prévoir un **modèle de menace explicite** dans les specs : que se passe-t-il si un commerçant essaie de deviner/énumérer des identifiants de commande d'un autre commerçant (IDOR) ? Le BFF doit valider l'appartenance de la ressource à l'entité authentifiée à chaque appel, pas seulement au moment de lister.
- Logger côté BFF tout accès refusé pour permettre la détection d'anomalies.
- Le BFF devient également le point de **panne unique en sécurité** : une revue de code systématique (pas seulement des tests) sur toute la couche d'autorisation est justifiée.

### (c) Ouverture d'une API publique Echango pour développeurs tiers (transporteurs)

- Cette API publique doit **envelopper** l'API Fleetbase (déjà acté), jamais l'exposer, y compris indirectement.
- Scoping des clés délivrées aux tiers : chaque transporteur/développeur tiers doit recevoir une clé Echango (pas Fleetbase) scopée a minima à ses propres ressources — jamais une vision, même partielle, du pool mutualisé global ou des données d'autres commerçants/transporteurs.
- **Rate limiting propre à l'API publique**, indépendant du rate limiting interne Fleetbase déjà en place.
- **Webhooks sortants vers les tiers** : reprendre le même modèle que celui déjà présent côté Fleetbase pour `WebhookEndpoint` — signature HMAC-SHA256 du payload avec un secret propre à chaque abonné, re-vérification obligatoire côté récepteur, politique de retry avec backoff et plafond de tentatives.
- **Webhooks entrants** : vu le doute non résolu en §3 sur la validation des callbacks `listeners/{provider}` côté Fleetbase, **ne pas répliquer aveuglément ce mécanisme** pour l'API publique Echango sans avoir vérifié/durci la validation de signature. Exiger une signature HMAC sur tout webhook entrant, avec fenêtre de validité temporelle et vérification par IP/allowlist en complément si possible.
- Documentation/versionnage de l'API publique : s'assurer que cette API publique a son propre cycle de versionnage (ex. `/v1/`) indépendant des versions internes Fleetbase.
- Surface d'attaque supplémentaire : CAPTCHA ou vérification manuelle à l'inscription développeur, logging de l'usage par clé, capacité de révocation immédiate d'une clé tierce compromise ou abusive.

### (d) Vie privée — géolocalisation des drivers et données clients

- Le code confirme l'existence d'une table `Position` dédiée dans FleetOps (`server/src/Models/Position.php`, migration `create_positions_table`), décrite dans un commentaire du code source lui-même comme une **« high-frequency Position table »** distincte des champs `location` courants sur `Driver`/`Vehicle` — donc un historique de géolocalisation potentiellement très granulaire, avec relecture possible via un service `PositionPlayback`. C'est une donnée personnelle sensible au sens RGPD.
- Recommandations :
  - Définir une **politique de rétention explicite** pour cet historique de position — rien dans le code parcouru n'indique une purge native ; à vérifier en local et, si absent, à implémenter nous-mêmes.
  - Documenter la base légale du traitement de géolocalisation et informer les transporteurs (mentions CGU driver/Navigator).
  - Restreindre l'accès à l'historique de position complet aux seuls rôles qui en ont un besoin fonctionnel réel (l'opérateur Echango) — un commerçant ou un gestionnaire de petite flotte n'a probablement besoin que d'une position courante/temps réel de ses courses en cours, pas d'un historique fin.
  - Pour les données client transitant par Fleetbase : même logique de minimisation — le BFF ne doit exposer aux transporteurs tiers que le strict nécessaire à l'exécution de la course.
  - Envisager un **numéro de téléphone masqué/proxy** entre client et transporteur plutôt que de transmettre le numéro réel du client à un transporteur tiers inconnu du client final.

### (e) Autres risques identifiés

- **Secrets observés en clair pendant les tests locaux** (Bearer token, cookies de session, mot de passe root MySQL) : sans risque sur l'environnement local isolé, mais point de vigilance procédural à formaliser avant tout environnement partagé (staging).
- **Licence AGPL-3.0** : le code source confirme (`LICENSE.md`, `README.md` de `fleetbase/fleetbase`) que l'obligation de publication porte sur les **modifications** du code lorsqu'il est exposé en réseau à des tiers. Tant qu'Echango **ne modifie pas** le code Fleetbase et se contente de consommer son API, l'obligation de publication ne devrait *a priori* pas s'appliquer au BFF ni aux interfaces custom — mais c'est une interprétation, pas un avis juridique ; à confirmer avec un juriste avant la Phase 3.
- **Base de données MySQL partagée par Organization unique** : toute l'isolation métier reposant sur le BFF, une compromission de la base MySQL elle-même (ou un accès direct non passé par l'API) contournerait entièrement le futur filtrage BFF. Recommandation : n'autoriser aucun accès direct à la base de données Fleetbase en dehors de l'API.
- **Dépendance à un service de routage externe (OSRM)** : si le calcul d'itinéraire pointe vers un serveur OSRM public tiers, cela peut constituer une fuite d'adresses de prise en charge/dépose vers un tiers non contractualisé.
- **Extension Storefront désactivée** : bon réflexe sécurité en soi — moins de code/surface d'attaque activée que nécessaire.

## 5. Synthèse actionnable

1. Corriger la référence de repo `fleetbase/fleetops-api` → `fleetbase/fleetops` (archivé vs actif) dans `CLAUDE.md`/journal — **sous réserve de la contradiction avec le rapport 05, à vérifier en priorité**.
2. Avant mise en prod : clarifier l'entropie réelle du secret `ApiCredential` (Sqids sur timestamp+ID).
3. Auditer en local le endpoint `listeners/{provider}` (IntegratedVendor) pour vérifier la présence/absence de validation de signature.
4. Exiger et documenter un modèle de menace + tests automatisés anti-IDOR pour toute la couche de filtrage du BFF.
5. Politique de secrets pour le(s) `ApiCredential` Fleetbase détenu(s) par le BFF.
6. Politique de rétention/minimisation pour la table `Position` et pour les données client transmises à des tiers.
7. Spécifier, pour la future API publique développeurs : scoping strict des clés, rate limiting dédié, signature HMAC obligatoire, versionnage indépendant.
8. Confirmer avec un juriste l'analyse AGPL avant la Phase 3 B2B.
9. Interdire tout accès direct à MySQL hors API.

**Fichiers de référence utilisés** : `/home/user/echango-delivery/CLAUDE.md`, `/home/user/echango-delivery/docs/journal_exploration_fleetbase.md`, code source public `fleetbase/core-api`, `fleetbase/fleetops` (anciennement cité à tort comme `fleetbase/fleetops-api`, désormais archivé), `fleetbase/fleetbase`.
