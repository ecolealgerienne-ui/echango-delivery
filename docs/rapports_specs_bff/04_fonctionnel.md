# Rapport agent — Revue fonctionnelle/produit de `docs/specs_bff.md`

*Produit par un agent spécialisé produit/fonctionnel, le 27 juillet 2026, pour évaluer si la surface API proposée pour le BFF couvre réellement les besoins des deux personas. Reproduit ici intégralement pour traçabilité — la synthèse est intégrée dans `docs/specs_bff.md`.*

---

## 1. Persona commerçant (§3) — le cycle de vie n'est pas complet

**Vrais manques MVP** :
- **Notification de changement de statut.** Seul `GET .../{id}` est prévu — du polling passif. Il manque un enregistrement de device token et un consommateur des événements de statut Fleetbase pour déclencher une vraie notification.
- **Gestion de l'échec de livraison côté commerçant.** Rien ne couvre le cas d'échec (client absent, adresse erronée, refus) — le commerçant doit voir la raison et l'étape suivante.
- **Modification d'une commande avant assignation.** Seule l'annulation existe — une erreur de frappe oblige à annuler puis recréer.
- **Historique/recherche avec filtres.** Pas de filtre par statut/date, pas de pagination mentionnée.
- **Preuve de livraison visible.** Le mode POD existe côté Fleetbase mais rien ne dit que le BFF le traduit pour le commerçant.

**Peut attendre** : multi-boutiques, devis de prix avant confirmation (dépend du modèle de tarification, non tranché), déposes multiples côté commerçant, chat driver/commerçant, édition/suppression d'adresse.

## 2. Persona petite flotte (§4) — deux angles morts structurants

**Vrais manques MVP** :
- **Disponibilité des drivers, pas seulement leur position.** Rien n'expose si un driver est en ligne/déjà en course — plus important que la position pour dispatcher intelligemment.
- **Positions groupées pour la vue carte.** Un appel par driver ne scale pas pour l'écran identifié comme le plus exigeant du spike FlutterFlow — il faut un endpoint qui retourne toutes les positions en un appel.
- **Filtre par statut sur les commandes.** Sans ça, ni le flux entrant à traiter en priorité ni l'historique ne sont utilisables.
- **Détail d'une commande.** Pas de `GET /flotte/commandes/{id}` explicite avant d'assigner un driver en connaissance de cause.
- **Visibilité/réaction à un refus d'assignation.** Rien sur ce qui se passe si le driver assigné ne répond pas — à vérifier côté Fleetbase (accusé de réception pour une assignation ciblée ?) et à combler si absent.

**Peut attendre** : tableau de bord agrégé (calculable côté client), annulation côté flotte, CRUD des drivers, contrainte de capacité (inexistante côté Fleetbase de toute façon).

## 3. Un même compte avec les deux rôles — non anticipé

C'est un scénario plausible, pas hypothétique : `docs/specs_echango_delivery.md` §4 confirme lui-même qu'un même Vendor peut jouer les deux rôles selon la commande. Un commerçant qui grossit et embauche des livreurs dédiés est un chemin de croissance naturel.

Le design actuel a deux mécanismes d'authentification internes distincts et **non composables** — token Sanctum customer-portal vs table `bff_accounts` propre. "Un seul système d'authentification Echango" est vrai en façade côté client, mais rien ne prévoit qu'une seule identité Echango porte les deux rôles simultanément.

**Recommandation** : pas à prioriser pour les 3-5 pilotes, mais le modèle de compte devrait être conçu dès maintenant pour être extensible — un identifiant Echango associé à un ou plusieurs "profils" (rôle + `vendor_uuid`), le BFF choisissant la stratégie d'accès par profil actif. Évite un refactor plus coûteux plus tard. À noter explicitement comme question ouverte, pas laissé implicite.

## 4. Le driver comme consommateur du BFF — absence partiellement justifiée, mais un vrai trou

Pour la majorité des besoins (accepter une course, naviguer, capturer une preuve), l'absence du driver dans `specs_bff.md` est cohérente : Navigator parle directement à l'API Fleetbase.

Mais **la consultation des gains/historique de paiement** est un vrai oubli : `docs/specs_echango_delivery.md` §3.4 confirme qu'aucune logique de commission n'existe côté Fleetbase — cette donnée n'existera nulle part dans Fleetbase, seulement dans un moteur de commission qu'Echango doit construire. Le BFF (ou un service adjacent) est donc le seul endroit possible pour exposer ça au driver. Ce n'est pas un choix architectural différé, c'est une conséquence mécanique déjà actée — à faire apparaître explicitement dans `specs_bff.md`.

Second point lié : la question déjà ouverte du document ("un driver de la Fleet dédiée peut-il refuser d'être visible par le pool mutualisé ?") va nécessiter un mécanisme de préférence/consentement driver, qui devra aussi être porté par le BFF.

## Synthèse priorisée

**Vrais manques MVP (à ajouter avant implémentation)** :
1. Notification de changement de statut côté commerçant
2. Visibilité échec de livraison + raison, côté commerçant
3. Statut de disponibilité des drivers, pas seulement position, côté flotte
4. Endpoint positions groupées des drivers, côté flotte
5. Filtre par statut + pagination sur les listes de commandes
6. Détail de commande côté flotte
7. Modèle de compte Echango pensé pour porter plusieurs rôles (contrainte de design à poser maintenant, pas un développement immédiat)
8. Acter explicitement le driver comme futur consommateur du BFF pour les gains/commission

**Peut attendre** : modification de commande, multi-boutiques, devis de prix, tournées multi-arrêts côté commerçant ; tableau de bord agrégé, annulation, CRUD drivers, capacité côté flotte ; préférence pool/flotte dédiée côté driver (avant le premier onboarding de flotte dédiée seulement).
