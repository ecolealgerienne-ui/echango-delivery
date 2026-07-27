# Rapport agent — Revue architecture critique de `docs/specs_bff.md`

*Produit par un agent spécialisé architecture (subagent "Plan"), le 27 juillet 2026, en relecture critique du document de scoping BFF, avec vérification croisée du code source public de Fleetbase pour trancher la question ouverte #2. Reproduit ici intégralement pour traçabilité — la synthèse est intégrée dans `docs/specs_bff.md`.*

---

## Méthode

Lecture dans l'ordre de `CLAUDE.md`, `docs/specs_echango_delivery.md` (§1-9 + rapports `docs/rapports_specs/01_securite.md` et `05_validation_technique_fleetbase.md`), puis `docs/specs_bff.md`. Pour trancher la question ouverte #2 (existence d'un équivalent à `vendorPersonnel` côté facilitateur), vérification directe du code source public de `fleetbase/fleetops` (`server/src/Models/Vendor.php`, `VendorPersonnel.php`, `server/src/Http/Controllers/Internal/v1/VendorController.php`, `ContactController.php`, `routes.php`) et `fleetbase/core-api/src/Traits/HasApiControllerBehavior.php` — pas le repo archivé `fleetbase/fleetops-api`.

---

## 1. L'architecture à deux stratégies est-elle la bonne approche ?

**Oui, sur le fond — elle est imposée par le modèle de données Fleetbase, pas un choix arbitraire d'Echango.** `Order.customer` et `Order.facilitator` sont deux champs polymorphiques indépendants, et un même `Vendor` peut jouer les deux rôles simultanément sur des commandes différentes (confirmé : `Vendor::facilitatorOrders()` et `Vendor::customerOrders()` sont deux relations `HasMany` distinctes dans `Vendor.php`). On ne peut donc pas fusionner les deux personas sur un seul mécanisme d'accès sans perdre la distinction métier réelle.

**Alternative sérieusement envisageable et rejetée à raison, mais pour de mauvaises/absentes justifications dans le document** : abandonner `customer-portal-api` et construire un filtrage maison symétrique pour les deux personas. Ce serait plus homogène à auditer (un seul modèle de sécurité au lieu de deux), avantage réel vu le risque déjà identifié ("le BFF devient le point de panne unique en sécurité"). Mais ça jetterait tout ce que `customer-portal-api` fournit déjà et a été validé de bout en bout par test réel. Le document ne discute pas explicitement ce compromis.

**Recommandation concrète non présente dans le document** : masquer cette asymétrie derrière un port/interface interne unique côté BFF (type `OrderAccessPort` avec deux implémentations, `CustomerPortalAdapter` et `FacilitatorFilteredAdapter`). Ça garde le bénéfice de réutiliser `customer-portal-api` là où c'est rentable, tout en donnant aux contrôleurs/DTOs/tests du BFF une vue symétrique des deux personas.

Alternative non mentionnée, probablement disproportionnée pour le MVP mais à noter comme évolution future : construire côté Fleetbase un vrai "facilitator-portal" (extension PHP interne, à la manière de `customer-portal`) qui filtre en base via `vendorPersonnel` plutôt que "fetch large + filtre applicatif" côté BFF externe.

---

## 2. Surface API §3-4 : cohérence, RESTful, trous

- **Ambiguïté non résolue** : `GET/POST /commercant/adresses` → « `GET/POST address-book` **ou** `places` ». Une spec ne devrait pas laisser la ressource sous-jacente indéterminée — à trancher par un spike avant dev.
- **Le suivi temps réel** (question ouverte #3) est le point le moins défini alors que c'est un des deux piliers du MVP (« formulaire + suivi »). À remonter en priorité.
- **Provisioning driver côté flotte** : `POST /flotte/drivers` n'apparaît qu'en aparté, pas comme endpoint formel — incohérence de niveau de détail.
- **Dépendance cachée à Navigator** : la surface flotte (§4) n'expose aucune progression de statut de commande (dispatched → started → enroute → completed) — utilisable en pratique seulement si Navigator (question ouverte #3 du `CLAUDE.md`, toujours non tranchée) gère cette progression. Risque de blocage du MVP flotte non signalé dans le document.
- Nommage mixte français/anglais (« drivers » vs « commandes »/« adresses »).
- **Absence de pagination** dans toute la spec.

---

## 3. Option A vs Option B — verdict tranché

### Ce que le code confirme (résout la question ouverte #2)

Contrairement à l'hypothèse du document, **`vendorPersonnel` n'est pas un mécanisme spécifique à `customer-portal`** — c'est une brique générique de FleetOps :
- `Vendor.php` : `vendorPersonnel(): HasMany` → `VendorPersonnel`, et `Vendor` expose séparément `facilitatorOrders()` et `customerOrders()`.
- `VendorPersonnel.php` : `$fillable = ['vendor_uuid', 'contact_uuid', 'role', 'status', 'invited_by_uuid']` — le champ `role` est une chaîne libre, aucune contrainte qui le limiterait au persona "customer".
- Les routes internes `{id}/personnels` (GET/POST/DELETE) sont une fonctionnalité générique de la console FleetOps, utilisée par `customer-portal-api` mais pas possédée par elle.

**Conclusion factuelle** : rattacher un `Contact` à un `Vendor` avec `role='facilitator'` via `vendorPersonnel` est techniquement possible dès aujourd'hui. **L'Option B est techniquement faisable** — l'hypothèse de départ du document était incorrecte sur ce point précis.

### Mais ça ne tranche pas en faveur de B — un risque plus important, absent du document

`OrderController` n'a aucun `authorize()`/Policy sur les lectures, et aucune barrière n'existe en dessous du niveau Organization. Le rôle IAM "restreint" évoqué en Option B est une étiquette de permission côté console générique — **rien ne prouve qu'il bloque réellement la lecture d'autres commandes de l'Organization** (contrairement au rôle "Fleet-Ops Customer" de `customer-portal`, confirmé enforced par `PortalOrderService::queryForAccount()`).

Conséquence : créer un vrai `User` Fleetbase pour la petite flotte crée un **credential Fleetbase valide supplémentaire** capable, en théorie, de s'authentifier directement contre l'API Fleetbase (pas seulement via le BFF) et — vu l'absence de barrière sous le niveau Organization — de voir potentiellement **toutes** les commandes de l'unique Organization si ce token fuite ou est mal isolé.

L'Option A n'a structurellement pas ce mode de défaillance : son seul jeton est un Bearer Echango, inutilisable directement contre Fleetbase, même en cas de fuite totale.

**Recommandation tranchée : Option A**, mais pour une raison différente et plus solide que celle du document. Ce n'est pas parce que le mécanisme d'attachement manque (il existe) — c'est parce qu'avec une Organization unique et aucune barrière d'autorisation confirmée sous ce niveau, minimiser le nombre de credentials Fleetbase réellement authentifiables est en soi un contrôle de sécurité.

---

## 4. Risques non-fonctionnels

- **Compte de service à privilège large — sous-traité dans le document.** Pivot de toute l'architecture flotte, mais n'apparaît qu'en question ouverte #4 en fin de document, alors que c'est déjà qualifié ailleurs de « secret à criticité maximale ». À élever en décision de conception de premier rang.
- **Fetch-puis-filtre ne passera pas à l'échelle.** `HasApiControllerBehavior` (core-api) documente un filtrage générique par paramètre de requête (`?facilitator_uuid=...`) appliqué côté serveur Fleetbase. Rien n'empêche de pousser le filtre en base plutôt que de rapatrier tout l'historique de l'Organization pour filtrer en mémoire côté BFF. **Recommandation concrète** : utiliser le filtre serveur Fleetbase avec la valeur dérivée côté BFF (jamais transmise par le client) comme optimisation, **et** revalider systématiquement chaque ligne retournée côté BFF comme garde-fou (défense en profondeur — précédent concret : le bug de format `customer_type`, qui montre qu'on ne peut pas faire confiance aveuglément au filtrage Fleetbase). Pagination absente — à ajouter.
- **Quotas par sous-organisation** déjà identifiés comme risque ailleurs mais jamais opérationnalisés dans `specs_bff.md`.
- **SPOF** : cohérent avec la décision déjà actée (BFF stateless), pas un défaut propre à ce document.

---

## 5. Incohérences avec `specs_echango_delivery.md`

- **Citation erronée §1** : renvoie à « §3.3 » pour le test du compte "vendeur" — en réalité dans le corps du §3.1. À corriger.
- **Citations « §7.5 » inexistantes** (§3 et §4) : `specs_echango_delivery.md` §7 (Logistique) n'a pas de sous-numérotation `.5`. À corriger.
- **Incohérence de fond corrigée par cette revue** : l'affirmation du §2.2 (« pas de mécanisme équivalent à `vendorPersonnel` connu ») est factuellement fausse au vu du code — voir §3 ci-dessus.
- Pas d'incohérence relevée sur Ledger, adhoc/dispatch, ou le reste du tableau §7.

---

## Synthèse des recommandations concrètes

1. Garder les deux stratégies d'accès (justifié par le modèle de données Fleetbase), mais les encapsuler derrière un port/interface interne unique côté BFF.
2. Retenir l'**Option A** pour le compte petite flotte — reformuler la justification (le blocage `vendorPersonnel` est levé, mais l'argument décisif est la minimisation des credentials Fleetbase valides vu l'absence de barrière d'autorisation confirmée sous le niveau Organization).
3. Résoudre l'ambiguïté `address-book` vs `places`, ajouter les endpoints manquants, clarifier explicitement la dépendance du persona flotte à Navigator.
4. Faire du scoping du/des compte(s) de service Fleetbase une décision de conception de premier rang, pas une question différée.
5. Documenter l'usage du filtre serveur Fleetbase en complément — jamais en remplacement — de la revalidation applicative côté BFF ; ajouter la pagination.
6. Corriger les deux citations erronées.
