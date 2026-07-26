# Rapport agent — Métier / Business

*Produit par un agent spécialisé analyse métier/produit (plateformes B2B à effet réseau), le 26 juillet 2026, en relecture de `CLAUDE.md`, `docs/journal_exploration_fleetbase.md` et `docs/specs_macro_drive_transport.md`, avec vérification croisée du code source public de l'extension Fleetbase Ledger. Reproduit ici intégralement pour traçabilité — la synthèse priorisée est dans `docs/specs_echango_delivery.md`.*

---

**Correction préalable** : le nom de dépôt indiqué dans la mission d'origine (`fleetbase/ledger-api`) n'existe pas. Le dépôt réel est **`fleetbase/ledger`** — "Accounting & Invoicing Extension for Fleetbase", PHP, AGPL-3.0, mis à jour activement. Contenu vérifié directement via GitHub (README, arborescence `server/src/{Models,Observers,Services}`, migrations).

---

## 1. Ce que révèle l'extension Ledger — jamais explorée jusqu'ici

### 1.1 Ce qu'elle fournit nativement

- **Comptabilité en partie double** : `Account`, `Journal`, plan comptable, écritures manuelles/système, soldes de compte cachés (cache de perf).
- **Facturation client** : modèle `Invoice` avec cycle de vie complet (`draft → sent → viewed → paid/partial/overdue → void/cancelled`), `InvoiceItem`, templates avec branding, rendu PDF.
- **Portefeuilles numériques (`Wallet`)** : polymorphique — peut appartenir à une `Company`, un `User`, un `Contact`/customer, **ou un `Driver`**. États `ACTIVE/FROZEN/CLOSED`. Opérations : `credit()`, `debit()` (avec vérification de solde), `hasSufficientBalance()`.
- **Transactions** : modèle riche avec `payer_uuid/type`, `payee_uuid/type`, `initiator_uuid/type`, `subject_uuid/type` (polymorphique — peut pointer vers un `Order` ou une `Invoice`), plus `fee_amount`, `tax_amount`, `net_amount`, `settlement_status`. Bonne primitive de traçabilité, mais **c'est une structure de données, pas une règle métier** — rien ne remplit automatiquement `fee_amount` avec un pourcentage de commission.
- **Passerelles de paiement** : drivers Stripe, QPay, Cash, avec webhooks signés, sandbox/prod, `GatewayTransaction` comme journal d'audit/idempotence séparé.
- **Intégration FleetOps automatique** — deux observers clés :
  - **`PurchaseRateObserver`** : à la création d'un `PurchaseRate` (tarif de service lié à une commande FleetOps), il **annule les factures brouillon précédentes** puis **crée automatiquement une `Invoice`** liée à la commande, avec devise/échéance héritées de la commande.
  - **`OrderAccountingObserver`** : ne s'applique **qu'aux commandes de type "storefront"**, pas aux commandes opérationnelles FleetOps.
- **Qui est facturé** : `ledger_invoices.customer_uuid`/`customer_type` — copié depuis `Order.customer`, qui dans `fleetbase/fleetops-api` (`Models/Order.php`) est une relation polymorphique **`Vendor` ou `Contact`** (pas `Company` directement). Point important et non testé dans le journal d'exploration (voir §4).

### 1.2 Ce qu'elle NE fournit PAS — le vrai trou métier

Vérification directe du code :

- **Aucune logique de commission ou de répartition automatique**. `WalletService` expose bien une méthode `creditEarnings()` et `processPayout()`, mais **rien ne les déclenche automatiquement**. Aucun événement de type "commande livrée → calcule la part du transporteur → crédite son wallet" n'existe.
- **Aucun paramètre de taux de commission** dans `config/ledger.php`.
- Le champ `fee_amount` du modèle `Transaction` existe dans le schéma mais n'est renseigné par aucune logique automatique trouvée.

**Conclusion directe** : Fleetbase/Ledger fournit les **briques comptables** (facturation du commerçant, portefeuille et paiement du transporteur, passerelles de paiement) mais **aucun moteur de commission**. Le modèle économique est **entièrement à la charge d'Echango**.

C'est une divergence significative avec le doc macro (§4.1), qui liste **"Facturation automatique des commerçants (commissions par course)"** comme une fonctionnalité native déjà "utilisée" de Fleetbase. Ce n'est pas confirmé par le code : la facturation du commerçant est bien automatisable, le calcul de **commission** ne l'est pas.

---

## 2. Règles métier manquantes ou non tranchées — à statuer avant développement

### 2.1 Modèle de tarification et de commission (bloquant, priorité haute)

Non traité dans aucun des trois documents ni dans le code Fleetbase :
- Le prix d'une course est-il fixé par Echango, négocié par le transporteur, ou calculé dynamiquement ?
- Quel est le taux de commission Echango, uniforme ou variable ?
- Qui porte le risque de change/arrondi de devise ?
- Le transporteur est-il payé **par course** ou en **relevé périodique** ?
- Le champ `fee_amount`/`net_amount` de `Transaction` est le bon endroit technique pour matérialiser la commission une fois le modèle métier tranché, mais la formule reste à écrire.

### 2.2 Qui facture qui, exactement (lié à la question du "customer" Ledger)

Le mécanisme natif observé facture **`Order.customer`** (Vendor ou Contact), pas directement la `Company` propriétaire de la commande. Ceci n'a **jamais été testé** dans le journal d'exploration — le journal a testé et documenté en détail le champ `facilitator`, **pas le champ `customer`**. Deux lectures possibles, à trancher par un test réel :
- Si le commerçant (persona 1) est modélisé comme un `Vendor` dans `Order.customer`, la facturation automatique fonctionne nativement.
- Si le commerçant n'est pas explicitement posé en `customer` sur chaque commande, l'`Invoice` générée risque d'être adressée à la mauvaise entité ou à rien du tout.

**Recommandation** : ajouter au backlog de test pratique — créer une commande avec `customer` = Vendor représentant un commerçant simple et vérifier que `PurchaseRateObserver` génère bien une facture cohérente.

### 2.3 Annulations et livraisons ratées

- Aucune règle définie sur les remboursements/pénalités en cas d'annulation tardive, refus du transporteur, ou colis non livrable.
- Le doc macro §9 classe explicitement "Gestion des litiges et remboursements" en **hors périmètre MVP, process manuel**. Ledger montre que la comptabilisation d'une annulation *est* gérée nativement pour les commandes storefront (extourne), **pas** pour les commandes FleetOps.
- Question ouverte : un transporteur qui accepte puis abandonne une course — réassignation automatique, pénalité de réputation, impact wallet ? Rien ne l'automatise ; à définir comme règle produit.

### 2.4 SLA et délais garantis

Aucun engagement de délai n'est mentionné nulle part (pas de champ `sla_deadline`/`promised_at` repéré). À trancher : Echango Delivery promet-il un délai ? Implications sur tarification et dispatch (priorisation).

### 2.5 Propriété de la relation client final

Qui possède la relation avec le destinataire final ?
- Le modèle `Contact` supporte des rôles `facilitatorOrders`/`customerOrders`, suggérant que le destinataire final *pourrait* être modélisé comme un `Contact` distinct — notifications Fleetbase natives possibles.
- Alternative : le destinataire n'est qu'une adresse de dépose sans identité propre, tout le contact/suivi reste porté par le commerçant.
- Impact business fort sur le positionnement produit, pas seulement l'implémentation.

### 2.6 Onboarding commerçant / sous-organisation

- Inscription self-service ou onboarding manuel/commercial (la mention "3 à 5 commerçants pilotes" en Phase 3 suggère un onboarding manuel au départ) ?
- Qui crée le `Vendor` Fleetbase correspondant ?
- Pour la sous-organisation à flotte dédiée : qui valide/paramètre la `Fleet` liée à son `Vendor`, et qui a le droit d'y ajouter des drivers déjà présents dans le pool mutualisé ?

### 2.7 Facturation et paiement — mécanique concrète

- Fréquence de facturation du commerçant ?
- Moyen de paiement du commerçant (prélèvement Stripe via Ledger, virement, autre) ?
- Fréquence et moyen de paiement du transporteur ?
- TVA/fiscalité : le champ `tax` existe sur `Invoice`, mais aucune règle de calcul n'est définie.

---

## 3. Cohérence des 3 personas et du modèle Vendor/Fleet/Facilitator vs vision macro

### 3.1 Persona 2 (gestionnaire de petite flotte) absent du doc macro d'origine

`specs_macro_drive_transport.md` §2 ne liste que 2 profils côté Delivery : "Commerçant avec système", "Commerçant sans système", "Opérateur plateforme". **Le persona 2 n'existe pas dans la vision macro d'origine** — découverte faite pendant l'exploration technique, documentée dans `CLAUDE.md` mais jamais reportée dans le doc macro. **Le doc macro devra être mis à jour** avant que les specs détaillées ne s'appuient dessus.

### 3.2 Le doc macro présuppose des fonctionnalités Fleetbase non confirmées, voire probablement inexistantes

- **"Gestion multi-commerçants (Networks)"** (macro §4.1, §8.3) : le terme **"Networks"** en tant que concept Fleetbase natif **n'apparaît nulle part** dans le journal ni dans le code inspecté. Soit confusion terminologique avec "Organization", soit avec le "réseau de transporteurs mutualisé" en tant que concept produit. **Risque réel** : planifier une "activation Networks" en Phase 3 en pensant à une fonctionnalité Fleetbase existante risquerait une découverte tardive qu'il faut la construire soi-même. À corriger dans le doc macro.
- **"Facturation automatique des commerçants (commissions par course)"** (macro §4.1) : comme détaillé en §1.2, la facturation automatique existe, le calcul de commission non. Le doc macro sur-attribue une maturité native à Fleetbase.

### 3.3 Le doc macro contredit une décision déjà actée sur l'interface commerçant

Macro §2 et §4.2 : "Commerçant sans système → Crée ses demandes via le dashboard web Fleetbase", présenté comme la solution retenue, incluant "Consultation des factures et commissions".

Ceci est **directement contredit** par la décision actée dans `CLAUDE.md` (console jugée "très compliquée pour des petits commerçants, inutilisable dans l'état" par test manuel direct). Le doc macro est donc **obsolète sur ce point précis** et doit être corrigé.

### 3.4 Navigator : décision non justifiée, actuellement rouverte

Macro §4.1 : "Module Navigator : Non utilisé — remplacé par l'app transporteur custom", présenté comme une décision arrêtée. Le `CLAUDE.md` note lui-même que cette décision n'avait "aucune justification documentée" et la rouvre explicitement (question ouverte #3). Le doc macro, non mis à jour, continue d'afficher cette décision comme tranchée — incohérence de statut à corriger.

### 3.5 Le modèle Vendor/Fleet/Facilitator est cohérent avec la thèse réseau, avec une réserve

L'architecture retenue **est cohérente** avec la thèse centrale du doc macro (§1.3 : effet réseau, pool mutualisé, pas de flotte cloisonnée). Point positif : la solution technique retenue préserve bien la thèse produit.

**Réserve identifiée** (rejoint §2.2 ci-dessus) : le modèle utilise `Vendor` à **deux fins distinctes et non testées ensemble** — (a) `facilitator` = sous-organisation responsable de l'exécution (testé), et (b) potentiellement `customer` = le commerçant demandeur (jamais testé). Rien ne garantit que ces deux usages de `Vendor` coexistent proprement sur une même commande. Ce point mérite un test explicite avant de figer le modèle de données du connecteur Odoo → Fleetbase.

---

## 4. Incohérence relevée dans le journal d'exploration lui-même

Le journal (§6.4) écarte la piste `connect_company_uuid` du modèle `Vendor` comme "non concluante". Or ce champ ressemble structurellement à un mécanisme conçu précisément pour lier un `Vendor` à une **seconde Organization** — potentiellement pertinent pour le persona 2 si une sous-organisation *voulait* malgré tout garder sa propre Organization Fleetbase distincte tout en étant reliée à l'Organization "Echango Delivery" comme Vendor. Le journal a bien noté prudemment "à ne pas utiliser comme base d'architecture sans démonstration concrète" — bonne posture — mais ce champ mérite d'être noté explicitement comme "piste non fermée" plutôt que silencieusement abandonnée.

---

## 5. Synthèse — liste des règles métier à trancher avant développement

| # | Règle métier | Bloquant pour |
|---|---|---|
| 1 | Modèle de tarification d'une course (grille, distance, zone) | Connecteur Odoo→Fleetbase, app transporteur |
| 2 | Taux/mécanique de commission Echango | Ledger (`fee_amount`/`net_amount`), facturation commerçant, paiement transporteur |
| 3 | Cadence et moyen de paiement du transporteur | App transporteur, `WalletService` |
| 4 | Cadence et moyen de facturation du commerçant | Interface custom commerçant, `PurchaseRateObserver`/`Invoice` |
| 5 | Confirmation technique : qui doit être posé en `Order.customer` pour cibler la bonne facturation | Test pratique préalable, connecteur Odoo→Fleetbase |
| 6 | Règles d'annulation et de livraison ratée | Interfaces commerçant + petite flotte, app transporteur |
| 7 | Existence et niveau d'un SLA de délai | Tarification, dispatch, contrat commercial |
| 8 | Propriété de la relation client final | Positionnement produit, modèle `Contact` |
| 9 | Parcours d'onboarding commerçant / sous-organisation | Interface custom commerçant, couche BFF |
| 10 | TVA / fiscalité sur les factures | `Invoice.tax`, conformité |
| 11 | Statut de la piste `connect_company_uuid` (fermée ou à revisiter) | Architecture multi-Organization, si le besoin resurgit |

**Mise à jour documentaire recommandée** : `docs/specs_macro_drive_transport.md` contient plusieurs affirmations obsolètes ou non vérifiées (concept "Networks", facturation automatique des commissions, dashboard Fleetbase comme solution commerçant retenue, décision Navigator non rouverte) qui devraient être corrigées pour rester cohérentes avec les constats de `CLAUDE.md` et du journal d'exploration.
