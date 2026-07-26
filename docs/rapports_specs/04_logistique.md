# Rapport agent — Logistique / Opérations transport

*Produit par un agent spécialisé last-mile/dispatch, le 26 juillet 2026, en relecture de `CLAUDE.md` et `docs/journal_exploration_fleetbase.md`, avec vérification croisée du code source public `fleetbase/fleetops-api` et `fleetbase/fleetbase`. Reproduit ici intégralement pour traçabilité — la synthèse priorisée est dans `docs/specs_echango_delivery.md`.*

---

## 1. Auto-dispatch par proximité — existe réellement, contrairement à ce que suggérait le test manuel

Le journal concluait que seul un mécanisme d'assignation manuelle avait été testé, et laissait ouverte la question d'un auto-dispatch par proximité. **Cette conclusion est incomplète : le mécanisme existe et est assez développé dans le code**, simplement non activé/testé côté console pendant la session.

Trois pièces s'articulent :

- **`Order::dispatch()`** ne fait que poser `dispatched=true`, `dispatched_at=now()` et émettre l'événement `OrderDispatched`. Le vrai travail est délégué à un listener.
- **`HandleOrderDispatched`**, en réaction à cet événement :
  - Si la commande a un `driver_assigned_uuid` (flux manuel testé) → notifie uniquement ce driver.
  - **Si la commande a le flag `adhoc=true`** → exécute une requête géospatiale réelle : recherche tous les drivers `status=active, online=1` dans un rayon (`distanceSphere`) autour du point de prise en charge, puis envoie une notification `OrderPing` à *chacun* d'entre eux (broadcast, mail, FCM, APN). C'est un vrai broadcast par proximité/disponibilité, pas une simulation.
  - Le rayon vient de `Order::getAdhocDistance()` : `adhoc_distance` de la commande, sinon `company.options.fleetops.adhoc_distance`, sinon **6000 mètres par défaut**.
- **`fleetops:dispatch-adhoc`**, commande console destinée à tourner en tâche planifiée : pour toute commande `adhoc=1` déjà dispatchée depuis ≥4 minutes mais toujours sans driver assigné, elle relance la même recherche géospatiale (filtrée par `company_uuid` de la commande) et rappelle `dispatch(true)` si des drivers sont trouvés à proximité — mécanisme de re-broadcast périodique.
- **`fleetops:dispatch-orders`** gère séparément les commandes **planifiées** (`scheduled_at`).

**Conséquence pour le persona "gestionnaire de petite flotte"** : l'auto-dispatch natif par proximité existe, mais fonctionne au niveau **rayon de distance depuis le point de prise en charge**, pas au niveau Fleet/Zone. Rien ne restreint le broadcast aux seuls drivers d'une `Fleet` donnée (détail au §3). Pour le petit gestionnaire de flotte qui veut que ses courses ne partent qu'à ses propres drivers dédiés, le mode `adhoc` natif ne suffit pas tel quel — il faudrait soit rester sur l'assignation manuelle/ciblée déjà validée, soit construire une couche de filtrage par Fleet dans le BFF.

**Point d'attention à vérifier en pratique** : la version du filtre driver dans `HandleOrderDispatched` (le premier broadcast, pas le retry) ne semble pas contenir de clause explicite `company_uuid = $order->company_uuid` sur la requête principale (`withoutGlobalScopes()` + `whereHas('company', ...)` qui ne referme pas clairement la boucle). Sans impact pratique pour l'architecture "une seule Organization" retenue, mais à re-tester avant de se fier à cette fonctionnalité.

## 2. Tournées multi-arrêts (waypoints) — structure de données présente, aucune optimisation automatique côté backend

- **`Waypoint`** : chaque arrêt est une ligne dédiée avec son propre `place_uuid`, un champ `order` (position dans la séquence), son propre numéro de tracking et sa propre relation `proofs()` — preuve de livraison indépendante par arrêt nativement supportée.
- **`Payload`** expose `setWaypoints()`/`insertWaypoints()`/`updateWaypoints()` et `setNextWaypointDestination()` — gestion de la progression séquentielle, mais **aucune logique d'optimisation d'ordre des arrêts** trouvée.
- **`Support\OSRM::getTrip()`** encapsule bien le service *Trip* d'OSRM (résout l'ordre optimal de passage) — mais **aucun controller ni service n'y fait appel** (vérifié sur `OrderController` Internal v1). Le champ `is_route_optimized` existe dans `$fillable` d'`Order`, ce qui suggère qu'un calcul est censé alimenter ce flag — mais ce câblage n'a pas été trouvé côté API ; s'il existe, il est probablement côté console (Ember), pas dans l'API que consommera l'interface custom Echango.

**Implication concrète** : le toggle "Déposes multiples" crée probablement bien plusieurs `Waypoint`, mais **l'ordre de passage doit être décidé par qui crée la commande**. Si l'optimisation de tournée est un besoin réel, c'est un développement à prévoir dans le BFF, en s'appuyant sur `OSRM::getTrip()` ou équivalent — pas gratuit.

## 3. ServiceArea / Zone / Fleet — non reliés au dispatch géographique réel

- `ServiceArea` porte une frontière géographique (`MultiPolygon`) et une méthode `inZone()`/`pointsInZone()`.
- `Zone` est un sous-découpage d'une `ServiceArea`, également polygonal.
- Ces deux modèles sont des **constructions géographiques déclaratives**, mais **ni `DispatchAdhocOrders`, ni `HandleOrderDispatched` ne les consultent** pour restreindre le pool de drivers éligibles. Le seul filtre géographique du dispatch natif est le rayon en mètres.
- Le modèle `Driver` **n'a pas de champ `zone_uuid` ni `service_area_uuid`** — seul `Fleet` porte ces champs, sans répercussion sur le dispatch.

**Conclusion opérationnelle** : le zonage géographique est aujourd'hui de la **donnée descriptive sans effet de filtrage automatique**. Si Echango veut restreindre le broadcast adhoc à une zone de couverture, il faudra le construire soi-même dans le BFF.

## 4. Preuve de livraison (POD) — mécanisme réel, mais fenêtre de configuration limitée

- **`Proof`** : table dédiée, liée à une commande et polymorphiquement à un **waypoint ou toute autre entité**, avec un champ `data` (JSON libre) — assez flexible pour signature, photo, ou données de scan.
- **`Support\Flow::bindPodFlagsToFlow()`** calcule dynamiquement, à l'activité "completed", si une preuve est requise (`pod_required`) et selon quelle méthode (`pod_method`, défaut `'scan'`). `config/api.php` liste `scan`, `signature` (pas de mention explicite de "photo" comme méthode distincte, à confirmer en pratique).
- Mécanisme réel côté modèle de données, mais reste un simple binaire requis/pas requis + une méthode, sans logique de gestion des refus/échecs de preuve — relève de l'app Navigator/driver, pas de la couche que nous contrôlons a priori.

## 5. Routing / OSRM — le point le plus important à corriger dans le journal

Le journal (§9) notait `OSRM_HOST` comme "à vérifier". **La vérification va plus loin et change la conclusion pratique :**

- `scripts/docker-install.sh` fixe **`OSRM_HOST="https://router.project-osrm.org"` par défaut** — le **serveur de démonstration public** du projet OSRM (gratuit, capacité limitée, "fair use", explicitement non garanti pour un usage commercial/production). Cette valeur est injectée dans les `.env` du **frontend console** uniquement.
- Le `docker-compose.yml` racine **ne déploie aucun conteneur `osrm-backend`** — rien de routing self-hosted n'est provisionné par défaut.
- Côté API (`fleetops-api`), la classe `Support\OSRM` utilisée pour tout calcul d'itinéraire/distance (`getRoute`, `getTable`, `getTrip`, `getNearest`, `getMatch`) pointe vers **`https://bundle.routing.fleetbase.io`, une URL codée en dur dans la classe** (pas de lecture d'`OSRM_HOST`) — un service hébergé par Fleetbase Pte Ltd elle-même, dont on ne connaît pas le SLA.

**Donc, malgré le narratif "self-hosted AGPL"** du projet, **le calcul d'itinéraire n'est pas self-hosted par défaut** : il dépend soit du serveur de démo public OSRM (frontend), soit d'un service tiers opéré par l'éditeur Fleetbase (backend API) — deux dépendances externes non contractualisées.

**Recommandation opérationnelle** : pour un usage réel en ville, ne pas s'appuyer sur cette configuration par défaut.
1. **Déployer son propre conteneur `osrm-backend`** avec un extrait OpenStreetMap de la zone de couverture — cohérent avec la position AGPL/self-hosted actée, mais un vrai travail d'ingénierie (extraction/traitement des données OSM, hébergement, mises à jour périodiques).
2. **Basculer sur un service de routing commercial** (Google Maps Platform, Mapbox) si la couverture OSM pour la zone cible s'avère insuffisante, ou si un SLA contractuel est nécessaire. Pas de connecteur natif visible dans `fleetops-api` — ce serait probablement un remplacement de la classe `Support\OSRM`, donc un fork ou une extension, à évaluer au regard de la décision "ne pas forker Fleetbase" déjà actée.

À traiter **avant** tout engagement commercial sur des délais/ETA — un ETA basé sur un moteur de routing non fiable est pire qu'une absence d'ETA.

## 6. Dispatch manuel vs auto-dispatch — le manuel testé est-il suffisant au volume visé ?

Le flux manuel confirmé (facilitateur/Vendor à la création + assignation driver a posteriori) fonctionne, mais implique qu'**une personne** regarde chaque commande entrante et choisit un driver à la main. Gérable à quelques commandes/jour ; **à l'échelle visée par la thèse produit** (effet réseau, potentiellement des dizaines de commandes/jour mutualisées), ce mode devient un goulot d'étranglement humain :
- Pas de garantie de réactivité.
- Pas de prise en compte automatique de la charge déjà assignée à chaque driver (aucun champ de capacité/charge courante trouvé sur `Driver`).
- Le persona "petite flotte" ne peut pas fonctionner à l'échelle sans un minimum d'automatisation.

**Recommandation** : le mode `adhoc` natif (§1) couvre une bonne partie du besoin et devrait être activé/testé en priorité, plutôt que de développer un moteur de matching maison from scratch. Le vrai travail côté Echango est de :
- décider comment scoper ce broadcast à la bonne sous-population de drivers (Fleet du gestionnaire, faute de filtrage natif),
- gérer la file d'attente/timeout si personne n'accepte (retry à 4 minutes existant nativement, politique exacte à confirmer en observant le scheduler réel),
- construire l'écran "dispatch minimaliste" évoqué dans `CLAUDE.md` pour donner de la visibilité humaine en secours.

Le mode purement manuel reste pertinent comme **filet de sécurité**, mais ne doit pas être le mode par défaut si le volume augmente.

## 7. Besoins opérationnels non couverts identifiés

- **Créneaux de livraison (`time_window_start`/`time_window_end`)** : ces champs, capturés dans le payload réel, **n'apparaissent ni dans `$fillable` d'`Order`, ni dans celui de `Payload`, ni dans les règles de validation de `CreateOrderRequest`** (vérifié explicitement — absents des trois). **Probablement ignorés silencieusement** par le mass-assignment Laravel s'ils sont envoyés. **À vérifier en priorité en pratique** (créer une commande avec ces champs et observer si l'information survit en base) avant de promettre un engagement de créneau horaire — sinon, les faire transiter par le champ `meta` (JSON libre disponible sur `Order`), ou les gérer entièrement côté BFF.
- **Gestion des livraisons ratées / retours** : le champ `return_uuid`/relation `return()` existe (une Place de retour optionnelle), mais aucune logique métier ("client absent → tentative 2 → retour magasin → remboursement") n'a été trouvée. Flux entièrement à concevoir côté Echango.
- **Contraintes de capacité véhicule** (poids, volume, type de marchandise) : absentes du modèle `Vehicle` (`$fillable` : `make/model/year/trim/type/plate_number/vin` — pas de champ capacité/poids/volume dédié). Pourrait être casé dans le `meta` JSON, mais aucune contrainte de capacité n'existe côté dispatch.
- **Horaires de travail / disponibilité planifiée des drivers** : le modèle `Driver` n'a qu'un flag `online` binaire (temps réel) — pas de notion de shift/planning. Le dispatch adhoc ne peut réagir qu'à la disponibilité déclarée en direct, pas à un planning prévisionnel. Lacune réelle pour un gestionnaire de petite flotte qui veut planifier sa journée à l'avance.
- **Zones de couverture géographique opposables** ("on ne livre pas au-delà de X km") : comme noté au §3, `ServiceArea`/`Zone` existent mais ne sont reliées à aucune logique de refus/filtrage de commande. Un contrôle à implémenter côté Echango si c'est un besoin produit.

## 8. Récapitulatif des corrections apportées au journal d'exploration

| Constat du journal | Statut après vérification code |
|---|---|
| "Pas de mécanisme d'auto-dispatch par proximité/disponibilité testé ou confirmé" | **À nuancer** : le mécanisme existe et est assez complet côté code, simplement non activé/testé dans la session. Non câblé au zonage/Fleet cependant. |
| OSRM "self-hosted ou pointé vers un serveur public, jamais vérifié" | **Confirmé et précisé** : par défaut ce n'est **pas** self-hosted — frontend pointe vers le serveur de démo public OSRM, backend API vers un service hébergé par Fleetbase lui-même (URL codée en dur). Aucun conteneur OSRM dans le `docker-compose.yml` par défaut. |
| Champs `time_window_start`/`time_window_end` du payload capturé | **Signal d'alerte ajouté** : absents de `$fillable` et des règles de validation observées — probablement non persistés tels quels. |
| `Fleet.service_area_uuid`/`zone_uuid` "potentiellement pertinent pour du zonage de dispatch" | **Confirmé non exploité** : non référencés dans les deux logiques de dispatch trouvées. Purement descriptif. |
| Reste du journal (isolation Organizations, Fleet many-to-many, Vendor/Facilitator, mutuelle exclusivité driver/facilitateur) | Cohérent avec ce qui a été observé côté code, rien à corriger. |

**Fichiers de référence consultés** : `fleetbase/fleetops-api` — `src/Models/Order.php`, `src/Models/Payload.php`, `src/Models/Waypoint.php`, `src/Models/Driver.php`, `src/Models/Vehicle.php`, `src/Models/Proof.php`, `src/Models/ServiceArea.php`, `src/Models/Zone.php`, `src/Listeners/HandleOrderDispatched.php`, `src/Console/Commands/DispatchAdhocOrders.php`, `src/Console/Commands/DispatchOrders.php`, `src/Support/OSRM.php`, `src/Support/Flow.php`, `src/Http/Requests/CreateOrderRequest.php`, `src/Http/Controllers/Internal/v1/OrderController.php`, `config/api.php` ; `fleetbase/fleetbase` — `scripts/docker-install.sh`, `docker-compose.yml`.
