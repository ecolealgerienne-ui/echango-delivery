# Revue métier et parcours produit — Echango Delivery, 28/07/2026

*Agent : general-purpose (Sonnet). Périmètre : `echango_delivery/lib/screens/{commercant,transporteur}/`, `backend/bff/src/{commercant,transporteur}/`, `schema.prisma`, specs. Lecture seule. Convention : **[CODE]** = manque d'implémentation, **[PRODUIT]** = décision métier à trancher.*

## BLOQUANT PILOTE

**1. [CODE] L'app transporteur ne peut recevoir aucune commande en pratique — rien n'est branché côté client.**
Quatre pièces nécessaires au dispatch existent côté SDK/backend mais ne sont appelées nulle part dans l'UI :
- `setOnline()` (`bff_api_client.dart:307`) n'est invoqué par aucun écran — aucun toggle en ligne/hors ligne n'existe, alors que c'est la condition nécessaire au dispatch adhoc par proximité.
- `LocationService.startBackgroundTracking()` (`location_service.dart:68`) n'est jamais appelé — le driver n'envoie jamais sa position réelle.
- `flutter_foreground_task` est déclaré en dépendance mais jamais utilisé.
- `NotificationService.initialize()` est appelé (`main.dart:34`) mais le jeton FCM n'est jamais récupéré ni transmis au BFF (`registerDeviceToken()` n'a aucun appelant).
- Aucun polling automatique dans `order_state.dart` — seul le pull-to-refresh manuel charge les commandes.
Conséquence cumulée : un driver de test n'apparaîtra jamais « online » à Fleetbase, n'enverra jamais sa position, ne recevra jamais de push, et ne verra une nouvelle commande que s'il tire manuellement l'écran pile au bon moment. Avec deux vrais transporteurs, le pilote échouera silencieusement — un fait vérifiable dans le code tel quel.
*Recommandation* : câbler ces quatre éléments avant toute journée de test réelle — c'est du raccordement, pas de la conception nouvelle.

**2. [CODE, aggravé par une décision PRODUIT déjà actée] Les adresses sans carte convergent toutes vers les mêmes coordonnées, cassant le dispatch géospatial.**
`create_order_screen.dart:24-42` et `addresses_screen.dart:89-91` : tout pickup/dropoff non issu du carnet d'adresses retombe sur `36.7538, 3.0588` (centre d'Alger) — la même paire de coordonnées, y compris pickup **et** dropoff sur une même commande. La décision de différer la carte est actée et documentée, mais son effet à l'échelle n'a pas été mesuré : toute commande sans adresse préenregistrée atterrit au même point GPS fictif — le rayon de recherche de `HandleOrderDispatched` cherchera des drivers autour de ce point, pas de la vraie boutique, sans erreur visible (juste « en attente » indéfiniment).
*Recommandation* : pour le pilote, interdire la saisie libre — n'autoriser que des adresses du carnet pré-saisies (vraies coordonnées) par un opérateur.

**3. [PRODUIT non tranchée + manque d'outillage] Le maillon « dispatch manuel opérateur » n'a aucune visibilité ni alerte.**
`commercant.service.ts::createOrder()` ne pose ni `adhoc: true` ni n'appelle de dispatch — la commande reste en `created` jusqu'à une action manuelle sur la console Fleetbase. Rien ne signale une commande en attente depuis longtemps. Tenable à quelques commandes/jour si l'opérateur surveille en continu ; ingérable vers la centaine. Le pipeline `adhoc` est déjà validé de bout en bout — l'activer à la création serait un changement mineur.
*Recommandation* : trancher pour le pilote entre (a) opérateur astreint à surveiller la console pendant le créneau, ou (b) `adhoc: true` automatique à la création côté BFF.

**4. [CODE + PRODUIT §6 non tranchée] Annulation en cours de route sans garde-fou ni notification effective au transporteur.**
`commercant.service.ts:210-212` : `cancelOrder()` ne bloque que `completed/cancelled/failed` — un commerçant peut annuler alors que le statut est `started`/`enroute`. Aucune notification n'est envoyée au driver, et le constat n°1 (pas de polling, pas de push) signifie qu'il ne le saura qu'en rouvrant l'app, potentiellement après avoir livré. Terrain d'un litige quasi garanti dès la première annulation en vol.
*Recommandation* : au minimum, bloquer/confirmer fortement l'annulation après `started`, et pousser une notification (même dégradée) au driver.

## IMPORTANT

**5. [CODE d'affichage + PRODUIT §6.1 non tranchée] Le commerçant ne voit ni prix, ni délai estimé, ni distance — et rien ne les calcule.**
Aucun champ price/eta/distance dans les écrans commerçant. Le modèle `Commission` existe dans `prisma/schema.prisma` (lignes 232-258) mais aucune écriture (`Commission.create`) n'existe nulle part dans `backend/bff/src` — confirmé par grep : lu (`include: { commissions: true }`) mais jamais rempli. Un vrai commerçant commande à l'aveugle sur le coût.

**6. [CODE] La preuve de livraison n'est pas branchée côté client, alors que le serveur l'attend déjà.**
`order_detail_screen.dart:288-290` le documente lui-même. `pubspec.yaml` sans dépendance caméra. L'écran d'échec affiche un placeholder (« Photo capture will be available in future updates ») alors que le backend attend un champ `photo` opérationnel. Si un `OrderConfig` du pilote exige une preuve, le comportement réel n'est pas vérifié.

**7. [CODE, périmètre spec non couvert] Aucune navigation externe (Google Maps/Waze).**
`specs_app_transporteur.md` §4.2 liste « Démarrer la navigation » au périmètre. Aucune dépendance `url_launcher`/`map_launcher`, aucun bouton. Le driver navigue de mémoire ou copie l'adresse à la main. Manque simple à combler, fort impact quotidien.

**8. [CODE] Aucune notification push commerçant — seulement du pull-to-refresh manuel.**
`specs_bff.md` §3 prévoit `POST /commercant/device-token` pour notifier chaque changement de statut ; absent du contrôleur commerçant (grep négatif). Aucun timer d'auto-poll dans `merchant_order_state.dart`. Pour un usage boutique, gouffre d'attention.

**9. [CODE] Le persona « petite flotte » n'a aucun écran, et sa route casse le routeur.**
`app_router.dart` ne définit que `/transporteur` et `/commercant` ; `auth_state.dart` définit `UserRole.flotte` avec `homePath => '/flotte'`. Un `FleetAccount` qui se connecte serait redirigé vers une route jamais déclarée — crash/écran blanc probable. Sans impact sur un pilote commerçant+transporteur, mais à garder en tête.

## AMÉLIORATION

**10. [CODE UX] Le retry adhoc natif (~4 min) est invisible pour le commerçant** — « En attente d'attribution » identique après 2 minutes ou 2 heures, aucune alerte opérateur au-delà d'un seuil.

**11. [CODE] Aucune alerte si la position du transporteur cesse de se mettre à jour** (téléphone mort, app tuée). « Pris en charge par X » figé sans indication de fraîcheur. Non bloquant à 2 transporteurs, à traiter avant scale-up.

**12. [PÉRIMÈTRE à confirmer] Les multi-arrêts (waypoints) ne sont exploités nulle part côté UI commerçant** — le champ existe côté modèle/API, `create_order_screen.dart` ne permet que pickup+dropoff. Non bloquant si le pilote reste point-à-point.

## Les 5 choses à faire avant un pilote (un vrai commerçant, deux vrais transporteurs), dans l'ordre

1. **Câbler le parcours transporteur minimal** : toggle en ligne visible, `startBackgroundTracking()` à la connexion, jeton FCM enregistré au login, et un polling REST de secours (1-2 min) — sans ça, aucune commande n'atteint un vrai livreur (constat #1).
2. **Verrouiller la géolocalisation des adresses du pilote** : pré-saisir les vraies coordonnées des commerçants/destinataires pilotes, interdire la saisie libre sans carte (constat #2).
3. **Décider et afficher un prix/délai minimal**, même un forfait fixe (constat #5).
4. **Garde-fou sur l'annulation en cours de route** + notification au transporteur, au moins via le polling du point 1 (constat #4).
5. **Trancher le mode de dispatch du pilote** : opérateur dédié sur la console, ou `adhoc: true` automatique à la création (constat #3).
