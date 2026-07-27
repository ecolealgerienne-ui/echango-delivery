# CLAUDE.md — Echango Delivery

Ce fichier guide Claude Code (et tout contributeur) sur le contexte, les décisions et les questions ouvertes du projet **Echango Delivery**. Écrit dans le même esprit que le `CLAUDE.md` d'`echangoorder` : décisions + justification, pas juste l'état courant.

## Contexte projet

Echango Delivery est le **Produit 2** de l'écosystème Echango : une plateforme B2B qui met en relation des commerçants locaux (boulangerie, pharmacie, fleuriste... et **Echango Order**, premier client en dogfooding) avec un réseau de transporteurs locaux indépendants. Vision complète : `docs/specs_macro_drive_transport.md` dans [`echangoorder`](https://github.com/ecolealgerienne-ui/echangoorder) (§4 pour la partie Delivery spécifiquement).

Positionnement produit (macro doc §1.3) : l'effet réseau est la thèse centrale — **plus de commerçants → plus de transporteurs → plus de valeur**. Ça suppose un pool de transporteurs **mutualisé** entre commerçants, pas une flotte dédiée par commerçant.

## Pourquoi un repo séparé (décision produit, 2026-07-26)

Echango Delivery est backé par **Fleetbase** (self-hosted, AGPL-3.0) — un logiciel tiers, pas notre code. Le vendoriser dans `echangoorder` mélangerait les licences (AGPL vs le code propriétaire d'Echango Order) et une stack complètement différente (Node.js/MySQL/Redis/SocketCluster vs Odoo/Postgres). Ce repo contient **nos** scripts de déploiement, notre config, et nos notes de décision — **pas le code source de Fleetbase lui-même**, cloné à part en local (voir § Installation locale). On ne fork pas Fleetbase pour l'instant : pas nécessaire tant qu'on ne modifie pas son code (voir § Licence).

## État actuel — phase d'exploration (2026-07-26)

Rien de déployé en réel pour l'instant. Étape en cours : déploiement Fleetbase **en local** (côté utilisateur, WSL/Docker — voir § Installation locale) pour explorer les fonctionnalités réelles avant de figer une architecture. Voir § Questions ouvertes ci-dessous pour ce qu'on cherche à vérifier.

## Architecture envisagée (hypothèse de travail — à valider en testant, pas encore tranchée)

- **Une seule Organization Fleetbase "Echango Delivery"**, pas une par commerçant. Les "Organizations" Fleetbase sont un mécanisme d'isolation totale (drivers, commandes, utilisateurs, clés API — rien ne traverse). Une Organization par commerçant cloisonnerait leurs transporteurs respectifs et casserait l'effet réseau visé. Modèle cohérent avec le doc macro §2 : "Opérateur plateforme gère le réseau transporteurs via back-office Fleetbase" — un seul opérateur, un seul réseau.
- Les commerçants n'ont pas forcément de système/site web à eux : ils doivent pouvoir commander un transporteur via **une interface fournie par Echango** (décision produit explicite, pas une intégration API obligatoire côté commerçant). **Tranché par observation manuelle de la console (2026-07-26)** : ce ne sera pas la console Fleetbase elle-même, même avec un rôle restreint (question ouverte #1 toujours à tester, mais déjà écarté sur le principe) — la console (navigation à onglets Fleet-Ops/Storefront/Developers/Ledger/IAM, gestion d'extensions, etc.) est conçue pour un opérateur/dispatcher, pas pour un petit commerçant qui veut juste déclarer une livraison. Il faut une **interface custom Echango, légère, construite par-dessus l'API Fleetbase** (essentiellement : formulaire de commande + suivi) — cohérent avec le choix déjà fait côté Echango Order de construire une app préparateur custom plutôt que de forcer l'UI Odoo sur ce public.
- **Deuxième persona identifié (2026-07-26)** : une **organisation qui gère elle-même une petite flotte de transporteurs** (ni Echango l'opérateur réseau, ni un simple commerçant) a aussi besoin d'une interface simple — pas la console Fleetbase complète (trop lourde pour ce cas d'usage non plus), mais plus qu'un simple formulaire : une vue dispatch minimaliste (commandes entrantes, assignation à un driver disponible, position des drivers). Hypothèse de travail, **pas encore scopée** : une deuxième interface custom légère, distincte de celle des commerçants, construite sur la même API Fleetbase.
- **Recommandation découlant des deux points ci-dessus** (réflexion, pas encore un plan de dev) : ça dessine une architecture à 3 niveaux d'interface, toutes par-dessus la même API Fleetbase et la même Organization unique — (1) console Fleetbase = réservée à l'opérateur Echango (accès complet, existant) ; (2) interface custom légère "commerçant" = commande + suivi ; (3) interface custom légère "gestionnaire de petite flotte" = dispatch minimaliste. Aucune des deux interfaces custom (2) et (3) n'est développée à ce stade — périmètre, écrans et priorité à discuter avant d'écrire la moindre ligne de code.
- **Confirmé par test manuel (2026-07-26)** : l'isolation entre Organizations est totale au niveau data, pas seulement au niveau permissions — un driver (et plus largement un user) créé dans l'Organization A n'est ni visible ni réutilisable depuis l'Organization B ; en recréer un "identique" dans B génère un enregistrement entièrement distinct (ID différent), sans aucun lien natif entre les deux. Conséquence directe pour l'hypothèse multi-Organization évoquée ci-dessus (une organisation avec sa propre flotte dédiée = sa propre Organization Fleetbase) : un driver de cette flotte dédiée ne peut PAS nativement aussi piocher dans le pool mutualisé "Echango Delivery" — il faudrait une double saisie manuelle, sans synchronisation (statut, position, historique dupliqués et désynchronisés). Si cette flexibilité est un objectif produit réel, ça n'est pas fourni nativement par Fleetbase : il faudra construire nous-mêmes une couche d'identité driver par-dessus l'API, qui référence plusieurs IDs Fleetbase pour une même personne réelle.
- Extension **FleetOps** nécessaire (dispatch/commandes/flotte). Extension **Storefront** (marketplace e-commerce Fleetbase) **pas nécessaire** — Echango Order a déjà son propre frontal (app Flutter), pas besoin de la vitrine intégrée de Fleetbase.
- App conducteur : **décision (27/07/2026) — on reste sur Navigator** (app officielle Fleetbase, React Native, open source, AGPL) plutôt que de construire une app transporteur custom from scratch. Le doc macro d'Echango Order avait écarté Navigator ("remplacé par l'app transporteur custom") sans justification documentée ; construire une app custom voudrait dire refaire nous-mêmes géolocalisation en tâche de fond, notifications push, capture photo pour la preuve de livraison et résilience hors-ligne — un chantier bien plus lourd que les deux interfaces custom commerçant/petite flotte. **Pas encore testée en pratique** (question ouverte #3).
- Interfaces custom (commerçant + petite flotte) : **décision (27/07/2026) — Flutter pur, pas FlutterFlow.** FlutterFlow avait été envisagé un temps pour son éditeur visuel, mais cet argument ne tient pas dès lors que c'est Claude Code qui écrit le code (pas un développeur humain à qui l'éditeur glisser-déposer ferait gagner du temps) — un agent IA n'a pas de moyen efficace de piloter une interface web visuelle pensée pour un humain. Écrire directement du code Dart/Flutter est plus rapide, reste dans le repo git comme le reste du projet, sans dépendance à un outil externe. Détail : `docs/specs_echango_delivery.md` §8.

## Questions ouvertes à trancher en testant en local

1. **Granularité des permissions à l'intérieur d'une Organization** — **✅ tranchée (26/07/2026)** : la console/API classique ne fournit aucune isolation en dessous du niveau Organization (confirmé par test manuel + code). MAIS le package officiel `fleetbase/customer-portal-api` fournit une vraie isolation par compte, **validée par test réel de bout en bout** (compte `Contact` rattaché à un `Vendor`, login, `GET orders` correctement scopé). Détail complet : `docs/specs_echango_delivery.md` §3.1.
2. Un driver Navigator peut-il recevoir des courses de **plusieurs commerçants différents** au sein d'une même Organization (modèle pool partagé), ou le broadcast ad hoc est-il pensé pour une seule entreprise ? **Partiellement répondu** : le pipeline serveur du dispatch adhoc (broadcast géospatial par proximité) est validé de bout en bout par test réel (26/07/2026, `docs/specs_echango_delivery.md` §3.2) ; l'assignation ciblée d'un driver précis à une commande est aussi confirmée possible. Reste à tester : la réception réelle par un driver, qui nécessite l'app Navigator installée (question #3 ci-dessous).
3. Navigator est-il réellement adaptable (rebrand, configuration) pour servir d'app transporteur Echango ? **❌ Révision de décision (27/07/2026)** : test d'installation et compilation mené côté utilisateur (Windows, Android). Obstacles sérieux identifiés et confirmés par recherche GitHub :
   - **Erreurs de codegen systémiques** : `react-native-camera-roll` incompatible avec React Native 0.86 (même sur branche "legacy" 0.76) — `UnionTypeAnnotation` non supportée par le générateur de code Fleetbase
   - **Crash au startup même après build réussi** : Hermes engine error, documenté dans issue #101 du repo Navigator (aussi reproductible sur d'autres OS comme Arch Linux)
   - **Documentation incomplète** : tokens Facebook/Transistor non mentionnés, mais requis pour fonctionner
   - **Workarounds nécessaires** : patches manuels sur dependencies, upgrades forcées, configurations non documentées
   - **Support/maintenance incertain** : 9 issues actives liées à build/compilation, pas de pattern clair de fermeture
   
   **Conclusion** : Navigator a des frictions d'installation trop sérieuses pour être un MVP fiable sans fork/patching massif. Coût de maintenance à long terme élevé et non maîtrisé.
   
   **Prochaines étapes** : 
   - **Option A (recommandée)** : construire une app transporteur custom en **Flutter pur** (cohérent avec stack Echango Order, contrôle complet, maintenance claire)
   - **Option B** : forker + patcher Navigator (maintenance plus lourde, dépendance à upstream instable)
   - **Option C** : utiliser console Fleetbase pour les transporteurs (rejeté avant, trop complexe)

## Licence — position actuelle (à rouvrir avant l'ouverture B2B réelle)

**AGPL-3.0 self-hosted retenu par défaut pour l'instant** (gratuit ; obligation de publier nos modifications si le service est exposé en réseau à des tiers — clause "network use"). La licence commerciale Fleetbase (FCL, qui lève cette obligation) est écartée pour l'instant — montant trouvé en recherche non fiable/contradictoire, **jamais vérifié officiellement**, à ne pas utiliser comme base de décision budgétaire. Ce point est explicitement différé : il ne bloque pas la phase d'exploration actuelle, mais devra être retranché avant la Phase 3 du roadmap macro (ouverture B2B à des commerçants tiers, `docs/specs_macro_drive_transport.md` §8.3).

## Installation locale (à exécuter par l'utilisateur — pas de Docker fonctionnel dans le sandbox Claude Code)

Prérequis (vérifiés contre la doc officielle Fleetbase, pas supposés) : Docker + Docker Compose, Node.js v22, Git.

Deux méthodes officielles :

```bash
# Méthode 1 — CLI Fleetbase (recommandée par l'éditeur)
npm install -g @fleetbase/cli
flb install-fleetbase

# Méthode 2 — clone + script manuel (celle utilisée par scripts/setup-local.sh de ce repo)
git clone https://github.com/fleetbase/fleetbase.git
cd fleetbase && ./scripts/docker-install.sh
```

Extension FleetOps (dispatch/commandes/flotte, nécessaire pour nous — pas installée par défaut) :

```bash
flb install fleetbase/fleetops
```

Ports par défaut (doc officielle) : Console `http://localhost:4200`, API `http://localhost:8000`, SocketCluster `38000`.

**Non vérifié ici** (limite d'environnement — `docker` CLI présent dans ce sandbox mais aucun daemon actif, `/var/run/docker.sock` absent, même limite que `backend/` côté `echangoorder`) : le contenu exact de `docker-compose.yml`/`.env.example`/`docker-compose.override.yml.example` de Fleetbase, le comportement réel de l'extension FleetOps, la granularité des rôles/permissions (questions ouvertes ci-dessus). Tout ça à valider en réel côté utilisateur (WSL/Docker, comme pour Odoo dans `echangoorder`) et à reporter dans ce fichier une fois testé.

## Specs consolidées (26 juillet 2026)

Après la phase d'exploration ci-dessus, une revue croisée par 5 agents spécialisés (sécurité, architecture, métier, logistique, validation technique Fleetbase) a été menée sur ce fichier et `docs/journal_exploration_fleetbase.md`, avec vérification systématique contre le code source public et la documentation officielle de Fleetbase. Résultat : **`docs/specs_echango_delivery.md`** — synthèse priorisée, avec un plan d'action concret avant tout développement, et une liste de contradictions entre agents à vérifier en premier (rapports complets dans `docs/rapports_specs/`).

**Découvertes majeures à retenir** : un package officiel `fleetbase/customer-portal` (jamais repéré avant cette revue) fournit déjà une isolation par compte native pour le persona commerçant, potentiellement en remplacement d'une bonne partie du BFF prévu à construire nous-mêmes. Le calcul d'itinéraire n'est pas self-hosted par défaut malgré le narratif du projet. Un auto-dispatch par proximité existe nativement. Le doc macro (`docs/specs_macro_drive_transport.md`) contient plusieurs affirmations obsolètes à corriger.

**✅ Spikes validés par tests réels (26/07/2026)** : `customer-portal-api` installé et testé de bout en bout (compte de test créé, rattaché à un Vendor, commande visible via l'API scopée — un bug de format Fleetbase trouvé et documenté au passage) ; dispatch adhoc testé de bout en bout côté serveur (broadcast géospatial déclenché sans erreur). **Priorités 1 et 2 du plan d'action closes** — voir `docs/specs_echango_delivery.md` §9 pour le détail complet des tests et §3 pour toutes les découvertes. Étape en cours : scoper le BFF (Priorité 4).

## Prochaines étapes

Voir le plan d'action détaillé et priorisé dans `docs/specs_echango_delivery.md` §9. Résumé :

- [x] Installer Fleetbase + FleetOps en local (utilisateur, WSL/Docker) — `scripts/setup-local.sh`. Fait le 26/07/2026 (bug MySQL rencontré et corrigé, voir journal §1.1).
- [x] **Priorité 1** : contradictions résolues, spike `fleetbase/customer-portal` validé de bout en bout par test réel. Fait le 26/07/2026.
- [x] **Priorité 2** : vérifications techniques closes — créneaux horaires OK, dispatch `adhoc` validé par test réel, OSRM et facturation Ledger reclassés non-bloquants (réponses déjà connues, tâches de mise en prod plutôt que prérequis dev). Fait le 26/07/2026.
- [ ] **Priorité 3** : trancher les règles métier non tranchées (tarification, commission, annulations, SLA, onboarding — liste complète dans `docs/specs_echango_delivery.md` §6).
- [x] **Priorité 4, scoping BFF** : `docs/specs_bff.md` (v2, 27/07/2026, relu par 4 agents spécialisés — rapports dans `docs/rapports_specs_bff/`) — découverte structurante : `customer-portal-api` ne couvre que le persona commerçant (scope sur `Order.customer`, confirmé structurellement par le code), pas la petite flotte (`Order.facilitator`, aucun mécanisme natif). Décision tranchée : compte Echango pur (pas de `User` Fleetbase dédié) pour la petite flotte, par minimisation des credentials Fleetbase valides. Reste : 9 questions ouvertes du scoping BFF (§8 du document, notamment la dépendance à Navigator pour le MVP flotte).
- [x] **Décisions app (27/07/2026, révisée le même jour)** : décision initiale de rester sur **Navigator** pour l'app transporteur — **inversée après test réel d'installation** (blocages structurels : erreur de codegen reproductible sur toutes les versions testées, crash au démarrage documenté par d'autres utilisateurs, dépendances React Native 0.86 instables — détail complet `docs/navigator_test_findings.md`). **Nouvelle décision : app transporteur custom en Flutter pur**, comme les deux autres interfaces (commerçant, petite flotte) — cohérence totale du stack sur les 3 interfaces, plus de dépendance à un tiers instable. Spec fonctionnelle complète (reprenant l'intégralité du périmètre Navigator, rien omis) : `docs/specs_app_transporteur.md`. Reste à faire : trancher les questions ouvertes du document (§13 — auth directe Fleetbase vs BFF, temps réel WebSocket vs push, périmètre MVP vs V2), puis démarrer le développement des trois interfaces.
- [ ] Revenir documenter les réponses **avant** de concevoir le connecteur Odoo → Fleetbase (qui vivra dans `echangoorder/backend/addons/echango_order/`, pas dans ce repo).
- [ ] Rouvrir la question de la licence AGPL avec un juriste avant la Phase 3 B2B.

## Repo lié

- [`echangoorder`](https://github.com/ecolealgerienne-ui/echangoorder) — Echango Order (Produit 1). `docs/specs_macro_drive_transport.md` pour la vision macro complète des deux produits.
