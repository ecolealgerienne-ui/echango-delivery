# Echango Delivery

Plateforme B2B de mise en relation commerçants ↔ transporteurs locaux indépendants (livraison à la demande), backée par [Fleetbase](https://github.com/fleetbase/fleetbase) (self-hosted, AGPL-3.0).

Produit 2 de l'écosystème Echango — voir [`echangoorder`](https://github.com/ecolealgerienne-ui/echangoorder) (Produit 1, Echango Order, premier client en dogfooding) et `docs/specs_macro_drive_transport.md` de ce repo pour la vision macro complète.

**Statut** : phase d'exploration — pas encore déployé en réel, pas de connecteur avec Odoo pour l'instant. Voir `CLAUDE.md` pour le détail des décisions produit et les questions ouvertes en cours.

## Installation locale

Ce repo ne contient **pas** le code source de Fleetbase (logiciel tiers, AGPL-3.0) — seulement nos scripts et notre config de déploiement. Voir `CLAUDE.md` § Installation locale pour le détail et les prérequis.

```bash
./scripts/setup-local.sh
```

## Structure

- `CLAUDE.md` — contexte produit, décisions, questions ouvertes (à tenir à jour à chaque avancée).
- `docs/specs_macro_drive_transport.md` — copie de la vision macro (source : `echangoorder`).
- `scripts/setup-local.sh` — clone Fleetbase (upstream, non versionné ici) et lance l'installation Docker officielle.
