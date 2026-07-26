# Scoping du BFF Echango Delivery (v1)

**Date** : 27 juillet 2026
**Statut** : Draft de conception — première passe de scoping, basée sur les tests réels documentés dans `docs/specs_echango_delivery.md`. À challenger avant implémentation.

Ce document scope la couche BFF (backend-for-frontend) qu'Echango construit par-dessus Fleetbase, décidée dans `docs/specs_echango_delivery.md` §4-5. Il part du principe déjà acté : le BFF est le **point d'entrée unique** pour toute écriture Fleetbase (interfaces custom + futur connecteur Odoo), il détient les identifiants Fleetbase, jamais exposés aux clients finaux.

---

## 1. Constat structurant : deux personas, deux stratégies d'accès Fleetbase différentes

C'est la découverte la plus importante des tests pratiques et elle conditionne tout le reste de ce document.

`fleetbase/customer-portal-api` (validé par test réel, `docs/specs_echango_delivery.md` §3.1) scope ses commandes sur le champ **`Order.customer`** — confirmé empiriquement : une commande avec `facilitator` renseigné mais `customer` vide n'apparaît **pas** dans `GET customer-portal/int/v1/orders`, même pour un compte rattaché comme personnel du même Vendor. Il a fallu que `customer` = ce Vendor pour que ça marche.

**Conséquence directe sur les deux personas identifiés dans `CLAUDE.md`** :

| Persona | Rôle Fleetbase sur la commande | Couvert par `customer-portal-api` ? |
|---|---|---|
| **Commerçant** (passe commande, suit sa livraison) | `Order.customer` | **Oui** — scoping natif validé par test |
| **Gestionnaire de petite flotte** (dispatch, voit/assigne les commandes de sa sous-org) | `Order.facilitator` | **Non** — aucun mécanisme natif, ni côté `customer-portal-api`, ni côté IAM/console (déjà confirmé absent, `docs/specs_echango_delivery.md` §3.3, test du compte "vendeur" qui voyait tout) |

Le BFF doit donc implémenter **deux stratégies d'accès Fleetbase distinctes** selon le persona connecté, pas une seule couche uniforme :

- **Commerçant → proxy fin vers `customer-portal-api`**, avec le token Sanctum du compte (obtenu et géré côté BFF, jamais transmis tel quel au client Flutter — voir §5).
- **Petite flotte → aucun proxy possible**, le BFF interroge FleetOps directement avec un **identifiant de service à privilège large** (compte Organization complet ou clé API scopée large), et **filtre lui-même** les résultats par `facilitator_uuid` = le `Vendor` de la sous-organisation connectée. C'était déjà l'hypothèse de départ avant la découverte de `customer-portal-api` — elle reste entièrement valable pour ce persona précis, `customer-portal-api` ne la rend pas obsolète, seulement partiellement.

---

## 2. Modèle de comptes / provisioning

### 2.1 Persona commerçant — via `customer-portal-api`

Chaîne validée par test réel (`docs/specs_echango_delivery.md` §3.1) :

1. Un `User` Fleetbase avec **`type='customer'`** (champ `$guarded`, pas assignable en masse — `forceFill()` ou équivalent requis dans le code de provisioning).
2. Un `Contact` Fleetbase avec **`type='customer'`** et `user_uuid` pointant vers ce `User` (idem, `$guarded`).
3. Pour un accès à l'échelle d'un Vendor (le cas qui nous intéresse, un commerçant = un Vendor "customer" dans Fleetbase) : ce `Contact` doit être rattaché comme personnel actif du `Vendor` (table `vendorPersonnel`).
4. Email à vérifier (`email_verified_at`) avant login possible.
5. Login via `POST customer-portal/int/v1/auth/login` → token Sanctum scopé à ce compte.

**Qui déclenche ce provisioning ?** Pas encore tranché — deux options :
- **Self-service** : le commerçant s'inscrit lui-même via l'interface Echango, le BFF orchestre les 5 étapes ci-dessus côté serveur avec un compte de service Fleetbase à privilège suffisant pour créer `User`/`Contact`/`Vendor`.
- **Provisioning manuel par Echango** (cohérent avec l'onboarding "3 à 5 commerçants pilotes" du doc macro Phase 3, question métier #9 de `docs/specs_echango_delivery.md`) : un opérateur crée le compte via un outil interne ou directement en base/API, communique les identifiants au commerçant.

**Recommandation** : commencer par le provisioning manuel (aligné avec le rythme d'onboarding pilote attendu), automatiser le self-service seulement si le volume le justifie — évite de construire un flux d'inscription public avant d'en avoir besoin.

### 2.2 Persona petite flotte — pas de solution native, à définir

Puisque `customer-portal-api` ne couvre pas ce rôle, deux options architecturales, à trancher avant implémentation :

**Option A — Compte Echango pur, aucun `User` Fleetbase dédié.** Le BFF gère sa propre table de comptes (`bff_accounts` ou équivalent), mappée à un `vendor_uuid` Fleetbase. L'authentification est entièrement côté BFF (email/mot de passe ou autre, gérés par nous). Le BFF utilise son identifiant de service à privilège large pour interroger FleetOps et filtre par `facilitator_uuid`. **Avantage** : aucune dépendance aux mécanismes de compte Fleetbase (pas de piège `$guarded`, pas de flux de vérification email Fleetbase à répliquer). **Inconvénient** : deux systèmes d'identité différents à maintenir (Fleetbase pour commerçant, Echango pur pour petite flotte).

**Option B — Réutiliser un `User` Fleetbase (rôle IAM restreint), mais BFF fait quand même tout le filtrage.** Un `User` standard (pas `type='customer'`) avec un rôle IAM minimal (voir `docs/specs_echango_delivery.md` §3.3, question posée mais jamais tranchée sur la liste exacte des rôles disponibles). Le BFF authentifie ce `User` via Sanctum classique (pas customer-portal), récupère son `Vendor` associé (relation à construire/documenter — pas de mécanisme équivalent à `vendorPersonnel` connu pour ce cas), puis interroge FleetOps avec le compte de service et filtre par `facilitator_uuid`. **Avantage** : un seul système d'identité (Fleetbase) pour tous les comptes liés à une Organization. **Inconvénient** : dépend d'un mécanisme de rattachement `User`↔`Vendor` côté "facilitateur" qu'on n'a jamais vérifié exister (contrairement à `vendorPersonnel` côté customer-portal, confirmé par le code) — **à vérifier avant de retenir cette option**.

**Recommandation provisoire** : partir sur l'Option A (compte Echango pur) tant que l'existence d'un mécanisme équivalent à `vendorPersonnel` pour le rôle facilitateur n'est pas confirmée — c'est le choix qui ne dépend d'aucune inconnue Fleetbase supplémentaire. À rouvrir si un test rapide confirme un mécanisme natif équivalent.

---

## 3. Surface API — interface commerçant

Le BFF n'a pas besoin de réinventer grand-chose ici : il peut exposer une API fine qui **traduit** les endpoints déjà validés de `customer-portal-api` (`docs/rapports_specs/05_validation_technique_fleetbase.md`, liste complète des routes) vers des contrats Echango stables (DTOs, voir §6). Endpoints prioritaires pour le MVP (formulaire commande + suivi, `CLAUDE.md`) :

- `POST /commercant/commandes` → `POST customer-portal/int/v1/orders`, avec pré-remplissage prise en charge/dépose côté BFF (adresse magasin enregistrée une fois, adresse client saisie/récupérée — idée déjà actée, `docs/journal_exploration_fleetbase.md` §7.2)
- `GET /commercant/commandes` / `GET /commercant/commandes/{id}` → `GET orders` / `GET orders/{id}`
- `POST /commercant/commandes/{id}/annuler` → `POST orders/{id}/cancel`
- `GET /commercant/adresses` / `POST /commercant/adresses` → `GET/POST address-book` ou `places`
- `GET /commercant/factures` → `GET invoices` (si Ledger activé — **optionnel**, décision différée §3.3 de `specs_echango_delivery.md`)

**Non couvert par customer-portal, à vérifier séparément si besoin** : suivi temps réel de la position du driver sur une commande en cours (customer-portal expose l'URL de suivi public découverte lors des tests — `docs/specs_echango_delivery.md` §7.5 — potentiellement suffisant pour l'interface commerçant sans réinventer un endpoint dédié, à évaluer).

---

## 4. Surface API — interface petite flotte

Ici, tout est à construire côté BFF (pas de proxy possible, §1). Endpoints nécessaires pour la "vue dispatch minimaliste" décrite dans `CLAUDE.md` :

- `GET /flotte/commandes` — liste des commandes où `facilitator_uuid` = le Vendor de la sous-organisation connectée. Implémentation : requête FleetOps avec le compte de service, filtre applicatif côté BFF (jamais de filtre transmis tel quel à Fleetbase en espérant qu'il soit respecté — leçon du rapport sécurité, `docs/rapports_specs/01_securite.md` §4b).
- `GET /flotte/drivers` — liste des drivers de la `Fleet` liée à ce Vendor (relation `hasManyThrough` confirmée par le code, `docs/rapports_specs/05_validation_technique_fleetbase.md` #2 — pas d'`attach()`/`sync()` Eloquent standard, à gérer via création directe d'enregistrements `FleetDriver` si le provisioning de driver passe par le BFF).
- `POST /flotte/commandes/{id}/assigner` — assigne un driver précis à une commande (`driver_assigned_uuid`), confirmé possible après création (`docs/specs_echango_delivery.md` §7.5).
- `GET /flotte/drivers/{id}/position` — position courante d'un driver (pas d'historique complet, cf. recommandation vie privée du rapport sécurité sur la table `Position` à haute fréquence).

**Question ouverte non technique, à trancher avant implémentation** (déjà notée `docs/specs_echango_delivery.md` §9 priorité 3, item 9) : un driver de la Fleet dédiée peut-il refuser d'être visible/assignable par cette interface s'il est aussi dans le pool mutualisé ? Aucune règle native — à spécifier.

---

## 5. Authentification côté BFF

Le BFF expose **un seul système d'authentification Echango** aux deux interfaces custom (Bearer token Echango, pas les tokens Fleetbase/Sanctum bruts) — les clients Flutter ne voient jamais la mécanique Fleetbase sous-jacente. En interne :

- **Commerçant** : le BFF détient/gère le token Sanctum `customer-portal` du compte (obtenu au provisioning ou au premier login, rafraîchi si besoin), l'utilise pour ses appels vers `customer-portal-api`.
- **Petite flotte** : le BFF authentifie via sa propre table de comptes (Option A, §2.2) ou un `User` Fleetbase (Option B), mais dans les deux cas utilise ensuite son **identifiant de service à privilège large** pour les appels FleetOps réels — jamais le compte de l'utilisateur final.

Ce choix isole complètement les clients Flutter des identifiants Fleetbase, cohérent avec la recommandation sécurité (`docs/rapports_specs/01_securite.md` §4a) de ne jamais transmettre le compte de service à un frontend, et avec l'objectif produit d'une future **API publique Echango** pour développeurs tiers (§5 de `docs/specs_echango_delivery.md`) — ce sera la même couche d'auth Echango à étendre, pas une nouvelle à inventer.

---

## 6. Normalisation des données Fleetbase — DTOs obligatoires

Piège concret déjà rencontré et documenté (`docs/specs_echango_delivery.md` §3.1) : la console Fleetbase peut écrire `customer_type`/`facilitator_type` dans un format incohérent (backslash initial en trop) qui casse silencieusement le scoping de `customer-portal-api`. **Le BFF ne doit jamais faire confiance à un format brut** venant de Fleetbase ou écrit par un tiers (console, futur connecteur Odoo) :

- Toute écriture de `customer_type`/`facilitator_type` par le BFF doit passer par une normalisation systématique (utiliser l'alias court `fleet-ops:vendor` documenté, jamais construire la chaîne à la main).
- Toute lecture doit être tolérante aux deux formats (avec/sans backslash, alias court) plutôt que de supposer un format unique.
- Plus largement : les interfaces custom et le futur connecteur Odoo ne doivent **jamais** voir un nom de champ ou une valeur Fleetbase brute — le BFF traduit systématiquement vers des DTOs Echango stables (déjà recommandé, `docs/specs_echango_delivery.md` §4, risque "couplage aux internals non documentés de Fleetbase").

---

## 7. Ce qui reste à construire vs ce que Fleetbase fournit déjà

| Besoin | Fourni nativement | À construire côté BFF |
|---|---|---|
| Scoping des commandes — commerçant | ✅ `customer-portal-api` | Provisioning du compte, DTOs, pré-remplissage adresses |
| Scoping des commandes — petite flotte | ❌ Aucun mécanisme natif | Filtrage complet par `facilitator_uuid`, avec compte de service |
| Auto-dispatch par proximité | ✅ mode `adhoc` natif, validé par test | Scoping par Fleet si besoin (le natif n'est pas filtré par Fleet, `docs/specs_echango_delivery.md` §3.2) |
| Assignation ciblée d'un driver | ✅ confirmé possible | — |
| Partage d'un driver entre pool mutualisé et flotte dédiée | ✅ many-to-many `Fleet↔Driver` | Règles de priorité/consentement (aucune native) |
| Facturation commerçant | ✅ si Ledger activé (`PurchaseRateObserver`) | Décision différée — Odoo reste recommandé comme source de vérité |
| Calcul de commission | ❌ absent de Ledger | Entièrement à construire, une fois le modèle de tarification tranché (priorité 3, métier) |

---

## 8. Questions ouvertes avant implémentation

1. **Qui provisionne les comptes commerçant** (self-service vs manuel) — §2.1, lié à la question métier #9 déjà listée.
2. **Option A vs B pour le compte petite flotte** (§2.2) — vérifier d'abord si un mécanisme type `vendorPersonnel` existe côté facilitateur avant de trancher.
3. **Le suivi de commande** (position driver en direct) : l'URL de suivi public native de Fleetbase suffit-elle pour l'interface commerçant, ou faut-il un endpoint BFF dédié avec plus de contrôle (marque Echango, données custom) ?
4. **Compte(s) de service Fleetbase** : un seul à privilège large, ou plusieurs scopés (recommandation sécurité déjà notée, `docs/rapports_specs/01_securite.md` §4a) ? Dépend de ce que permet réellement l'IAM Fleetbase pour une clé API — jamais testé précisément.
5. Toutes les règles métier de `docs/specs_echango_delivery.md` §6 restent bloquantes pour finaliser les DTOs de facturation/tarification, même si l'architecture technique du BFF peut avancer sans elles pour la partie commande/dispatch.

---

## Annexes

- `docs/specs_echango_delivery.md` — synthèse technique consolidée (source des faits validés utilisés ici)
- `docs/rapports_specs/` — rapports détaillés des 5 agents spécialisés
- `docs/journal_exploration_fleetbase.md` — journal détaillé des tests
- `CLAUDE.md` — contexte produit et décisions
