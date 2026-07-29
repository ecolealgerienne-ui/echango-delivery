# Plan de migration — appliquer la décision « Fleetbase source de vérité »

**Date : 29 juillet 2026.** Plan d'exécution de la décision prise dans
`docs/architecture_bff_fleetbase.md`.

**Contrainte posée par l'utilisateur, et qui prime sur tout le reste :**

> « Attention de ne pas casser l'existant, je parle d'un point de vue métier,
> normalement on ne touche pas aux écrans. »

Ce plan est donc une **refonte interne à contrat constant**. Tout ce qui suit se
juge d'abord à cette aune.

---

## 0. Invariants — ce qui ne doit pas bouger

À vérifier avant chaque commit de ce chantier.

1. **La forme des réponses HTTP ne change pas.** Les projections
   (`src/common/projections/order.projection.ts`) sont le contrat avec
   l'application : mêmes clés, mêmes types, mêmes valeurs nulles. Un champ qui
   venait du cache local et vient désormais de Fleetbase doit sortir **identique**.
2. **Aucun écran Flutter n'est modifié.** Si un lot semble en exiger un, c'est que
   le contrat a bougé — revoir le lot, pas l'écran. Seule exception prévue et
   assumée : le Lot 4 (validation commerçant) ajoute un écran, il ne modifie
   aucun existant.
3. **Aucune règle métier n'est retouchée.** Plafond de dette, commission, refus
   motivé, transitions d'état, anti-IDOR : ce chantier déplace *d'où vient la
   donnée*, jamais *ce qu'on en fait*.
4. **Le contrôle d'appartenance reste local et systématique.** Le filtrage serveur
   sert à ne pas rapatrier toute la compagnie, **jamais** à autoriser. Un
   paramètre d'URL n'est pas une frontière de sécurité — c'est vrai même
   maintenant qu'on sait que Fleetbase l'applique.
5. **Rien n'est supprimé sur la foi d'une lecture de code.** Chaque lot nomme le
   contrôle du Lot 0 qui le débloque. C'est la lecture de code qui a produit
   l'erreur d'origine (`architecture_bff_fleetbase.md` §4.3).

---

## 1. Ce qui est déjà su, sans test

Vérifié le 29/07/2026 en instrumentant le code :

- **`Order.codAmount` et `Order.codIncludesDelivery` sont écrits et jamais lus.**
  Tous les consommateurs — `assertCashCeiling()`, `settleCashIfDue()`,
  `pickAvailableFavourite()`, `getOrderTemplate()` — lisent déjà
  `meta.cod_amount` en direct chez Fleetbase. Deux colonnes mortes.
- **Aucun modèle n'a de clé étrangère vers `Order`.** `CashCollection`,
  `OrderDecline`, `DeliveryFailure` et `MerchantNotification` référencent tous
  `fleetbaseOrderUuid` en chaîne libre. Seul `MerchantAccount.orders` est une
  vraie relation, et seul `MerchantNotification.orderId` porte encore le cuid
  local. **La table est donc supprimable sans cascade**, une fois son rôle de
  mémoire de transition transféré (Lot 5).
- **`Order.trackingNumber` est lu à deux endroits** : le message de notification
  du réconciliateur et le retour d'annulation commerçant. Il ne peut pas partir
  avant que la lecture en direct soit sûre (Lot 3, dépend du cache).

---

## 2. Lot 0 — Vérifications (utilisateur, ~30 min, aucun code)

Script : `scripts/verify-fleetbase-filters.sh`.

| # | Contrôle | Attendu | Débloque |
|---|---|---|---|
| V1 | `orders?customer=<vendor réel>` vs `customer=<uuid inventé>` | totaux différents | Lot 1 |
| V2 | idem `facilitator` | totaux différents | Lot 1 |
| V3 | idem `driver` | totaux différents | Lot 1 |
| V4 | `drivers?query=<texte réel>` vs texte sans correspondance | totaux différents | Lot 1 |
| V5 | `drivers?phone=x` seul / `drivers?name=x` seul | **500** / **200** | confirme le bug amont |
| V6 | modifier une commande, relire aussitôt | `x-cache-status`, version de `x-cache-key` | Lot 3, Lot 5 |
| V7 | champ de statut du `Vendor`, modifié en console | valeur relue changée | Lot 4 |
| ~~V8~~ | ~~webhook déclaré, commande passée~~ | — | **reporté au VPS**, voir §7 |

**La comparaison valide/invalide de V1 à V4 n'est pas du zèle.** C'est exactement
ce qui manquait au test de juillet : les données cherchées sont présentes dans les
deux réponses, simplement noyées dans l'une. Un filtre qui « a l'air » de marcher
ne prouve rien.

---

## 3. Lot 1 — Filtrage côté serveur

**Gate : V1 à V4.** Environ une demi-journée. Aucune migration.

| Fichier | Avant | Après |
|---|---|---|
| `fleetbase-api.client.ts` | `getAllOrders(page, limit)` | `listOrders(filters, page, limit)` |
| `commercant.service.ts` | cache local puis lecture unitaire | `?customer=<vendorUuid>` |
| `flotte.service.ts` | `fetchAllOrders()` + filtre mémoire | `?facilitator=<vendorUuid>`, méthode supprimée |
| `transporteur.service.ts` | balayage mémoire sur `driver_assigned_uuid` | `?driver=<uuid>` |
| `commercant.searchDrivers()` | tous les conducteurs + filtre mémoire | `?query=<texte>` |

⚠️ **`query`, jamais `phone`** — `DriverFilter::phone()` renvoie 500
(`architecture_bff_fleetbase.md` §5.1).

**Invariant à surveiller** : la pagination. Aujourd'hui le total renvoyé au client
est calculé **après** filtrage mémoire. Avec le filtre serveur, il vient de la
méta Fleetbase. Les deux doivent coïncider, sinon l'application affichera un
nombre de pages faux — sans erreur, et sans qu'aucun écran ne change.

Gain : le plafond de 100 cesse d'être un problème, et quatre balayages complets
disparaissent.

---

## 4. Lot 2 — Colonnes mortes

**Aucun gate.** Environ une heure + migration.

Suppression de `Order.codAmount` et `Order.codIncludesDelivery` (§1).

Invisible de bout en bout : rien ne les lit, aucune projection ne les expose.
`CashCollection.expectedAmount` continue de figer le montant au moment de
l'encaissement — c'est l'exception §3.3 de la décision, elle ne bouge pas.

---

## 5. Lot 3 — Colonnes miroir restantes

**Gate : V6.** Environ une demi-journée + migration.

Suppression de `trackingNumber`, `driverName`, `fleetbaseCreatedAt`,
`fleetbaseUpdatedAt`.

⚠️ **Dépend entièrement du cache Redis.** Si une lecture immédiatement après
écriture peut être périmée, ce lot attend le Lot 5 — ou impose de conserver
`trackingNumber`, seul champ du groupe réellement lu.

`status` et `driverAssignedUuid` **restent** : ils sont la mémoire qui rend les
transitions détectables, donc les notifications possibles. Ils partent au Lot 5,
pas avant.

---

## 6. Lot 4 — Validation du commerçant

**Gate : V7.** Environ une journée, serveur + application.

- Lecture du statut `Vendor` à la connexion, refus tant qu'il n'est pas validé
- L'inscription devient une **demande** : compte et `Vendor` créés, connexion
  refusée
- **Seul écran ajouté de tout le chantier** : « demande en cours ». Un refus de
  connexion sec ferait croire à un mot de passe erroné — c'est un changement
  métier voulu, pas un effet de bord.

---

## 7. Lot 5 — Webhooks — **reporté au déploiement VPS (29/07/2026)**

**Gate : V8 + Lot 1.** Environ une journée et demie. Le lot le plus structurant.

> ### ⏸️ Reporté, et pour une raison qui se règle d'elle-même
>
> **Fleetbase refuse toute URL de webhook non publique** — ni `localhost`, ni
> `host.docker.internal`, ni une adresse privée : *« The url must be a public
> HTTP or HTTPS URL »*. Observer les évènements en développement impose donc un
> tunnel (`cloudflared`, `ngrok`), c'est-à-dire exposer un service sur Internet
> pour un contrôle de dix minutes.
>
> Cet obstacle **n'existe plus sur le VPS** : il y aura un domaine et un
> certificat, donc l'URL sera publique sans rien monter. Faire le contrôle
> maintenant coûterait plus cher que d'attendre le moment où il devient gratuit.
>
> **Ce qui reste en place entre-temps, et fonctionne** : `OrderReconcilerService`
> et les colonnes `Order.status` / `Order.driverAssignedUuid` qui lui servent de
> mémoire. La chaîne a été **constatée de bout en bout le 29/07/2026** — une
> commande assignée depuis la console remonte jusqu'à l'application commerçant
> (journal §23.5). Ce n'est pas un pis-aller en attente de réparation : c'est un
> mécanisme qui marche, simplement plus coûteux et plus lent qu'un webhook.
>
> **Ce qui a été retiré** : l'endpoint `POST /webhooks/fleetbase` du BFF, écrit
> puis supprimé le même jour. Une route publique sans vérification de signature
> qu'on ne toucherait plus avant le VPS finirait par y être déployée telle
> quelle. Elle est dans l'historique git, et le §7 ci-dessous dit quoi
> reconstruire.
>
> **Ce qui est conservé** : `scripts/webhook-listener.js`, un écouteur autonome
> sans dépendance. C'est un outil de développement, pas une route du serveur —
> il ne peut rien exposer qu'on ne lance pas exprès.
>
> **Au moment de le reprendre**, dans l'ordre :
> 1. déclarer le webhook depuis la console (Developers → Webhooks) vers l'URL
>    publique du VPS, **tous** les identifiants API et **tous** les évènements —
>    on ne connaît pas encore leur vocabulaire réel ;
> 2. observer avec `scripts/webhook-listener.js` pour relever le **nom et le
>    format de l'en-tête de signature**, les noms d'évènements, et la forme du
>    corps (commande entière, ou simples identifiants ? cela décide si le
>    réconciliateur peut vraiment disparaître) ;
> 3. seulement ensuite recréer l'endpoint, **signature d'abord, effets ensuite**.

- `POST /webhooks/fleetbase`, **vérification de signature obligatoire** — endpoint
  public, donc la signature n'est pas optionnelle
- Les notifications commerçant naissent d'un évènement reçu au lieu d'une
  comparaison
- Suppression de `Order.status` et `Order.driverAssignedUuid`
- **`OrderReconcilerService` conservé en filet**, intervalle allongé à 15 min. Les
  webhooks se perdent, et le cas « un admin assigne depuis la console » ne doit
  jamais redevenir invisible.

Une fois ce lot passé, **la table `Order` peut disparaître** (§1) : l'appartenance
se résout en comparant `customer_uuid` de la commande au `fleetbaseVendorUuid` du
commerçant. `MerchantNotification.orderId` bascule sur `fleetbaseOrderUuid`.

---

## 8. Lot 6 — Position en cache mémoire

**✅ Fait le 29/07/2026** (journal §28). Environ deux heures + migration.

> **La réserve initiale de ce lot était un contresens**, et elle figurait ici :
> « `positions` n'a réellement aucun filtre par conducteur ». C'est vrai, mais
> `Position` est l'**historique** — la position **courante** vit sur
> `Driver.location`, que `fetchOwnedDrivers()` rapatriait déjà sans la lire.
> Le lot ne remplace donc pas un appel par un autre : il supprime un chemin
> d'écriture. Détail et pièges (`[lon,lat]`, `[0,0]`) dans le journal.

Suppression de `lastLatitude`, `lastLongitude`, `lastPositionAt` sur
`DriverAccount`, remplacées par un cache mémoire à durée de vie (exception §3.1).

**Rapport le moins favorable du plan, et il faut le dire** : `positions` n'a
réellement aucun filtre par driver — c'est une des rares absences confirmées par
lecture de `PositionFilter` (journal §2.11), pas une erreur de nom. On échangerait
trois colonnes contre un rapatriement complet à chaque rafraîchissement de carte.
À faire par cohérence, pas par nécessité.

---

## 9. Ordre d'exécution

```
Lot 0 ✅ → Lot 2 ✅ → Lot 1 ✅ → Lot 3 ✅ → Lot 4 ✅ → Lot 6 ✅ → ⏸ Lot 5 (au VPS)
```

**L'ordre initial plaçait le Lot 5 avant le Lot 3**, au motif que c'est lui qui
libère `status`. Le report du Lot 5 a inversé les deux, sans dommage : le Lot 3
n'a retiré que les colonnes dont il pouvait se passer seul
(`trackingNumber`, `driverName`, les deux horodatages), et `status` comme
`driverAssignedUuid` sont restées — elles restent la mémoire du réconciliateur
tant qu'aucun webhook ne le remplace.

Le Lot 6 vient après le Lot 5 pour la même raison : c'est le dernier, et le
moins utile.

---

## 10. Prérequis transverses

Indépendants de ce plan, mais bloquants pour tout déploiement.

- **`npm run prisma:migrate` puis `prisma generate`** — les migrations de
  `CashCollection`, `CashRemittance`, `DriverEarning`, `OrderDecline`,
  `MerchantNotification` et `CashRemittance.direction` n'ont **jamais été
  appliquées**. Le client Prisma n'a pas pu être régénéré dans le bac à sable
  (proxy bloquant `binaries.prisma.sh`), donc les modèles récents ne sont pas
  vérifiés en types.
- **`flutter analyze`** sur l'application fusionnée — jamais exécuté, et beaucoup
  de Dart récent n'a jamais été compilé.
- **La chaîne encaissement → dette → remise → confirmation** n'a jamais été jouée
  de bout en bout.
- Au déploiement VPS, trois choses à reprendre ensemble :
  1. `APP_DEBUG=false` côté Fleetbase — le 500 observé le 29/07/2026 renvoyait
     une page d'erreur Laravel complète, avec chemins de fichiers et requêtes ;
  2. la reconfiguration du contournement de preuve photo (`CLAUDE.md`) ;
  3. **le Lot 5, webhooks** (§7) — c'est là qu'il devient faisable sans tunnel.

---

## 11. Ce qui ne bouge pas

Caisse, rémunérations, commission, favoris, invitations, refus motivés,
notifications, carnet d'adresses, journal d'audit, comptes, jetons d'appareil.

**Douze modèles Prisma sur quinze.** C'est notre métier ; Fleetbase n'en connaît
rien et n'a pas vocation à en connaître. Ce chantier ne les touche pas.
