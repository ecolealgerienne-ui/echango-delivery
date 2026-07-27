# Rapport agent — Fact-checking technique Fleetbase de `docs/specs_bff.md`

*Produit par un agent spécialisé Fleetbase, le 27 juillet 2026, chargé de vérifier chaque affirmation technique du document de scoping BFF contre le code source réel. Reproduit ici intégralement pour traçabilité — la synthèse est intégrée dans `docs/specs_bff.md`.*

---

Méthode : lecture directe du code source sur GitHub (`fleetbase/customer-portal` et `fleetbase/fleetops`, branche `main`), repos correctement identifiés (`fleetbase/fleetops`, pas le repo archivé `fleetops-api`).

## 1. Affirmation centrale (§1) : `customer-portal` scope exclusivement sur `Order.customer`

**Verdict : CONFIRMÉ — et plus solidement que ne le suggère le document.** C'est garanti structurellement, pas juste un résultat de test. `server/src/Services/PortalOrderService.php`, méthode `queryForAccount()` :
```php
public function queryForAccount(array $context)
{
    $accountCustomerFilters = $this->accountCustomerFilters($context);
    return Order::where('company_uuid', session('company'))
        ->where(function ($query) use ($accountCustomerFilters) {
            if (empty($accountCustomerFilters)) { $query->whereRaw('1 = 0'); return; }
            foreach ($accountCustomerFilters as $filter) {
                $query->orWhere(function ($accountQuery) use ($filter) {
                    $accountQuery->where('customer_uuid', $filter['uuid'])->where('customer_type', $filter['type']);
                });
            }
        })
        ->whereNull('deleted_at')->withoutGlobalScopes();
}
```
Recherche exhaustive du mot "facilitator" sur le fichier entier (234 lignes) : **zéro occurrence**. `PortalAccountResolver::resolve()` ne résout que des comptes via `Contact.type='customer'` ou `Vendor::whereHas('vendorPersonnel', ...)` — jamais rien lié à `facilitator`. Il n'existe structurellement aucun chemin pour que `facilitator` soit jamais pris en compte, quel que soit le scénario.

## 2. Équivalent de `vendorPersonnel` pour le rôle facilitateur (§2.2)

**Verdict : CONFIRMÉ qu'aucun équivalent n'existe — point le plus important de cette revue.** `PortalAccountResolver.php` : la seule logique de rattachement User→Vendor est codée en dur sur `type='customer'`. `VendorPersonnel.php` a un champ `role` libre, mais rien dans le code (customer-portal ni fleetops) ne l'exploite pour distinguer un rôle facilitateur. `Vendor::facilitatorOrders()` n'est qu'une relation "commandes où ce Vendor est facilitateur", pas un mécanisme de rattachement utilisateur. Recherche GitHub globale pour `facilitatorPersonnel` : 0 résultat.

**Conclusion** : la recommandation provisoire du document (Option A) devient définitive — il n'y a rien à attendre côté Fleetbase.

## 3. `Fleet.drivers()` en `hasManyThrough` (§4)

**Verdict : CONFIRMÉ**, avec exemple canonique trouvé dans le code Fleetbase lui-même (`FleetController.php`, action console "ajouter un driver à une flotte") :
```php
$exists = FleetDriver::where([...])->exists();
if (!$exists) {
    $added = FleetDriver::create(['fleet_uuid' => $fleet->uuid, 'driver_uuid' => $driver->uuid]);
}
```
Pattern à reproduire côté BFF. Note : §7 dit "many-to-many", §4 dit "hasManyThrough" — pas une contradiction (many-to-many au niveau modèle de données, `hasManyThrough` au niveau implémentation Eloquent), mais à clarifier dans le document.

## 4. Endpoint `GET order-configs` (§3)

**Verdict : CONFIRMÉ**, existe (`OrderController::orderConfigs()`) et retourne `key`, `name`, `namespace`, `description`, `tags`, `status`, `version`, `flow` (machine à états, `pod_method`/`require_pod` par étape) — exploitable pour le BFF.

## 5. URL de suivi public native (§3)

**Verdict : CONFIRMÉ dans l'existence, NUANCÉ sur la sécurité.** Générée via `Utils::consoleUrl('track-order', ['order' => $this->tracking_number])`. Le `tracking_number` n'est **pas** un jeton cryptographique : `TrackingNumber::generateNumber()` utilise `mt_rand(0, 9)` (PRNG non cryptographique) pour 10 chiffres, préfixés par le nom de société. Pas infaisable à énumérer, même famille de risque que l'entropie Sqids des clés API déjà notée ailleurs. **À documenter comme réserve dans `specs_bff.md`.**

## 6. Autres vérifications

- Chaîne de provisioning §2.1 : cohérente avec le code lu, rien à corriger.
- Alias court `fleet-ops:vendor` (§6) : confirmé utilisé en interne par Fleetbase lui-même (`accountCustomerFilters()`), la recommandation du document est alignée avec la pratique du code source.

## Synthèse des verdicts

| # | Affirmation | Verdict |
|---|---|---|
| 1 | `customer-portal` scope uniquement sur `Order.customer`, jamais `facilitator` | **CONFIRMÉ** (structurellement) |
| 2 | Aucun équivalent `vendorPersonnel` pour le rôle facilitateur | **CONFIRMÉ** — trancher définitivement pour l'Option A |
| 3 | `Fleet.drivers()` est `hasManyThrough`, pas de `attach/detach/sync` natifs | **CONFIRMÉ**, exemple `FleetDriver::create()` trouvé |
| 4 | `GET order-configs` existe et est utile | **CONFIRMÉ** |
| 5 | URL de suivi public générée nativement | **CONFIRMÉ** ; **NUANCÉ** sur la sécurité — `mt_rand`, pas un jeton cryptographique |
| 6 | "many-to-many" (§7) vs "hasManyThrough" (§4) | Pas une erreur, deux niveaux de description à clarifier |

**Fichiers consultés** : `fleetbase/customer-portal:server/src/Services/PortalOrderService.php`, `PortalAccountResolver.php`, `server/src/Http/Controllers/Internal/v1/OrderController.php`, `server/src/routes.php` ; `fleetbase/fleetops:server/src/Models/Fleet.php`, `Vendor.php`, `VendorPersonnel.php`, `Driver.php`, `Order.php`, `TrackingNumber.php`, `server/src/Http/Controllers/Internal/v1/FleetController.php`.
