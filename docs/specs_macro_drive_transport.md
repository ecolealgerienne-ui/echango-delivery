# Macro Specs — Echango Order & Echango Delivery

**Version** : 1.0  
**Statut** : Draft — validation avant specs détaillées  
**Validé par** : Product Owner · Architecte Solution · Expert Odoo

---

## 1. Vision Projet

### 1.1 Contexte
Création de deux produits distincts mais interconnectés :

- **Produit 1** : Un Echango Order en ligne (commande, préparation, retrait ou livraison)
- **Produit 2** : Une plateforme B2B Echango Delivery en SaaS, dont le Echango Order est le premier client

### 1.2 Modèle Echango Delivery
La Echango Delivery est un produit indépendant, ouvert à tout commerçant local (boulangerie, pharmacie, fleuriste, etc.). Elle met en relation des commerçants qui ont besoin de livrer leurs clients avec un réseau de transporteurs locaux indépendants.

Le Echango Order se connecte à la Echango Delivery comme n'importe quel autre commerçant client — via API.

### 1.3 Positionnement
- Le Echango Order valide le modèle en conditions réelles (dogfooding)
- La Echango Delivery est un actif scalable, ouverte progressivement à d'autres commerçants
- L'effet réseau : plus de commerçants → plus de transporteurs → plus de valeur

---

## 2. Utilisateurs & Profils

| Profil | Produit | Description |
|---|---|---|
| **Client final** | Echango Order | Commande en ligne, choisit livraison ou retrait en magasin |
| **Préparateur** | Echango Order | Prépare les commandes en entrepôt/magasin |
| **Transporteur** | Echango Delivery | Indépendant local, prend des courses à sa convenance |
| **Commerçant avec système** | Echango Delivery | Se connecte via API (ex : Echango Order (Odoo), Shopify...) |
| **Commerçant sans système** | Echango Delivery | Crée ses demandes via le dashboard web Fleetbase |
| **Opérateur plateforme** | Les deux | Gère le réseau transporteurs, les tarifs, la facturation via back-office Fleetbase (web) |

---

## 3. Produit 1 — Echango Order

### 3.1 Backend : Odoo 19

**Modules natifs utilisés**
- Vente (`sale.order`) — gestion des commandes clients
- Inventaire (`stock.picking`, `stock.quant`) — gestion du stock et préparation
- E-commerce — gestion du catalogue produits (back-office uniquement, le frontal client est l'app mobile)
- Paiement — intégration moyens de paiement (Stripe ou équivalent)
- Facturation — génération automatique des factures clients

**Développements custom Odoo**
- Module connecteur Odoo → Fleetbase : publication automatique d'une course quand une commande est prête à livrer
- Réception webhook Fleetbase → mise à jour du statut de livraison dans Odoo
- Gestion des créneaux de retrait en magasin (Click & Collect)
- Champ statut livraison spécifique (en attente transporteur / assigné / livré)

**Version cible** : Odoo 19 (déploiement prévu après octobre 2026)  
**Modules OCA à évaluer** : `OCA/delivery-carrier`, `OCA/sale-workflow`, `OCA/e-commerce`

### 3.2 App Mobile Client (React Native — iOS & Android)

**Fonctionnalités**
- Authentification (inscription, connexion, mot de passe oublié)
- Catalogue produits avec recherche et filtres par catégorie
- Fiche produit (photo, description, prix, disponibilité stock)
- Panier et validation de commande
- Choix du mode de réception : livraison à domicile ou retrait en magasin avec créneau
- Paiement en ligne intégré
- Suivi des statuts de commande avec notifications push
- Historique des commandes

**Langue** : Français + Arabe (RTL natif dès le départ)

### 3.3 App Mobile Préparateurs (React Native — iOS & Android)

**Fonctionnalités**
- Authentification sécurisée (profil interne uniquement)
- Liste des commandes à préparer, triées par priorité et créneau
- Détail d'une commande : liste des produits, quantités, emplacement en entrepôt
- Scan code-barres produits (natif Odoo 19 — GS1/EAN13)
- Gestion des ruptures de stock : signalement et substitution
- Changement de statut : En préparation → Prête
- Déclenchement automatique de la demande de course vers Fleetbase à la validation

**Langue** : Français + Arabe (RTL)

---

## 4. Produit 2 — Echango Delivery

### 4.1 Backend : Fleetbase (self-hosted, AGPL-3.0)

**Fonctionnalités natives utilisées**
- Gestion multi-commerçants (Networks) — onboarding commerçants partenaires
- Réception des demandes de transport (via API ou dashboard web)
- Gestion et qualification du pool de transporteurs locaux
- Broadcast des courses disponibles vers les transporteurs
- Dispatch et assignation des courses
- Suivi des statuts de livraison
- Historique des courses par commerçant et par transporteur
- Facturation automatique des commerçants (commissions par course)
- APIs REST documentées pour les commerçants avec système propre
- Webhooks sortants vers les systèmes des commerçants

**Hébergement** : Self-hosted sur VPS ou cloud (pas de dépendance Fleetbase Cloud)  
**Module Navigator** : Non utilisé — remplacé par l'app transporteur custom

### 4.2 Dashboard Web Fleetbase (existant, fourni par Fleetbase)

Destiné aux commerçants sans système propre.

**Fonctionnalités**
- Création manuelle d'une demande de transport (adresse retrait, adresse livraison, description)
- Suivi en temps réel des statuts de livraison
- Historique des courses
- Consultation des factures et commissions
- Gestion du compte commerçant

### 4.3 App Mobile Transporteur (React Native custom — iOS & Android)

**Fonctionnalités**
- Authentification et profil transporteur (photo, véhicule, zone d'intervention)
- Statut disponibilité : en ligne / hors ligne
- Liste des courses disponibles en temps réel (toutes origines commerçants confondues)
- Détail d'une course : commerçant, adresse de retrait, adresse de livraison, description colis, rémunération
- Accepter ou refuser une course
- Bouton navigation → ouvre Google Maps / Waze / Plans natif avec adresse pré-remplie
- Changement de statuts : En route retrait → Colis récupéré → En route livraison → Livré
- Preuve de livraison : photo obligatoire à la livraison
- Historique des courses livrées et gains

**Langue** : Français + Arabe (RTL natif dès le départ)  
**GPS** : Délégué aux apps de navigation natives (pas de GPS intégré dans l'app)

---

## 5. Intégrations & Connecteurs

> **Note Architecte** : Odoo 19 expose ses données principalement en JSON-RPC. Fleetbase consomme et expose du REST. Le module connecteur custom Odoo gère cette translation de protocole.

### 5.1 Odoo → Fleetbase
- Déclencheur : commande marquée "Prête" par le préparateur dans l'app
- Action : création automatique d'une course dans Fleetbase via API REST
- Données transmises : adresse retrait (entrepôt), adresse livraison (client), référence commande, description

### 5.2 Fleetbase → Odoo
- Déclencheur : statut de livraison mis à jour par le transporteur
- Action : webhook Fleetbase → mise à jour statut dans Odoo + notification push client
- Statuts synchronisés : Assigné / En route / Livré

### 5.3 Commerçants tiers → Fleetbase
- Connexion via API REST Fleetbase documentée
- Compatible avec tout système e-commerce (Shopify, WooCommerce, etc.)
- Webhook retour vers le système du commerçant pour suivi statut

---

## 6. Stack Technique

| Brique | Technologie | Justification |
|---|---|---|
| Echango Order backend | Odoo 19 | Modules natifs vente/stock/paiement, APIs JSON-RPC |
| Echango Delivery | Fleetbase self-hosted | Multi-commerces natif, open source AGPL-3.0 |
| Apps mobiles | React Native | iOS + Android en un seul codebase, support RTL |
| Notifications push | Firebase Cloud Messaging | Standard industrie, intégré React Native et Odoo |
| Navigation GPS | Lien natif (Maps/Waze) | Zéro développement, zéro coût, UX connue |
| Hosting | VPS ou cloud (à définir) | Self-hosted pour maîtrise des coûts et données |

---

## 7. Points de Vigilance

### 7.1 Product Owner
- Valider les parcours utilisateurs pour chaque profil avant tout développement
- Prioriser le MVP : Echango Order + app transporteur avant l'ouverture B2B
- Définir les critères d'acceptation pour chaque fonctionnalité
- Cadrer le modèle économique : tarification commerçants, commission transporteurs

### 7.2 Architecte Solution
- Valider la compatibilité des APIs Fleetbase avec Odoo 19 (JSON-RPC vs REST)
- Anticiper la montée en charge multi-commerçants sur Fleetbase self-hosted
- Définir la stratégie d'hébergement (séparation Odoo / Fleetbase)
- Évaluer le support RTL dans React Native pour les deux apps mobiles
- Valider la sécurité : isolation des données entre commerçants (multi-tenant)

### 7.3 Expert Odoo
- Confirmer les modules OCA compatibles Odoo 19 (branche 19.0 disponible ou non)
- Estimer l'effort du module connecteur Odoo → Fleetbase
- Valider la gestion des créneaux Click & Collect en natif ou custom
- Confirmer le fonctionnement des webhooks entrants dans Odoo 19
- Évaluer les modules de paiement disponibles sur le marché cible

---

## 8. Roadmap Macro

### 8.1 Priorité absolue — Echango Order (1 mois)

| Étape | Durée | Contenu |
|---|---|---|
| **Développement** | Semaines 1-2 | App client Echango Order : catalogue, panier, paiement, suivi statuts, bilingue FR/AR |
| **Tests & corrections** | Semaine 3 | Tests fonctionnels, validation RTL arabe, corrections |
| **Publication stores** | Semaine 4 | Soumission App Store + Google Play (validation Apple incompressible) |

**Opérations manuelles pendant ce temps :**
- Préparation commandes → Odoo back-office directement
- Coordination transporteurs → WhatsApp / téléphone
- Suivi client → notifications manuelles

### 8.2 Phase 2 — Apps opérationnelles (selon traction)

| Phase | Délai post-live | Contenu |
|---|---|---|
| **App Préparateurs** | 1 à 2 mois | Remplacement du process manuel préparation |
| **App Transporteur Echango Delivery** | 2 à 3 mois | Remplacement du process manuel livraison |

### 8.3 Phase 3 — Ouverture B2B Echango Delivery

| Phase | Délai post-live | Contenu |
|---|---|---|
| **Commerçants pilotes** | 3 à 6 mois | Onboarding 3 à 5 commerçants, activation Fleetbase Networks |
| **Scalabilité** | 6 mois+ | Extension géographique, acquisition commerçants, modèle économique consolidé |

---

## 9. Hors Périmètre (MVP Echango Order)

**Reporté en Phase 2 (apps opérationnelles) :**
- App Préparateurs → process manuel via Odoo back-office en attendant
- App Transporteur Echango Delivery → coordination manuelle WhatsApp/téléphone en attendant
- Intégration Fleetbase active → non nécessaire avant la Phase 2

**Reporté en Phase 3+ :**
- Ouverture B2B Echango Delivery aux commerçants tiers
- Système de notation des transporteurs et commerçants
- Optimisation automatique des tournées multi-livraisons
- Tracking GPS temps réel du transporteur visible par le client
- Programme de fidélité client
- Application web client
- Gestion des litiges et remboursements (process manuel en MVP)
- Intégration comptabilité avancée

---

*Document à compléter avec les specs détaillées par module après validation de ce macro.*
