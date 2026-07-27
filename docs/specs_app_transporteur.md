# Specs — App Transporteur Echango (Flutter)

**Date** : 27 juillet 2026
**Statut** : Spécification fonctionnelle complète, dérivée des specs de Fleetbase Navigator — base de référence avant développement. **Mise à jour (27/07/2026, 1er passage)** : les 3 décisions d'architecture laissées ouvertes en §13 ont été tranchées (auth via BFF §2.1, temps réel push FCM/APN + polling §11.1, géolocalisation open source §11.2). **Mise à jour (27/07/2026, 2e passage)** : périmètre réduit sur décision explicite — chat et rapports carburant retirés (jugés inutiles pour ce projet), système d'incidents générique de Navigator remplacé par un mécanisme ciblé "échec de livraison" (§4.3), seul besoin réel identifié derrière la question initiale.
**Contexte** : suite à `docs/navigator_test_findings.md` (Navigator abandonné — blocages d'installation/compilation structurels, crash au démarrage documenté, dépendances React Native 0.86 instables), décision de construire une **app transporteur custom en Flutter pur** plutôt que d'utiliser/forker Navigator.

**Méthode de ce document** : Navigator (`fleetbase/navigator-app`, React Native, AGPL) est l'app officielle Fleetbase pour les transporteurs, avec un périmètre fonctionnel mature et éprouvé (dispatch, POD, chat, rapports, gestion de flotte). Le document a d'abord repris l'intégralité de ce périmètre par exhaustivité (1er passage, rien omis silencieusement), **puis un périmètre a été explicitement retiré sur décision utilisateur** (2e passage, §6/§7/§8) — chat et rapports carburant jugés inutiles, système d'incidents générique remplacé par un besoin réel plus étroit (échec de livraison, §4.3). Ce qui a été retiré reste documenté à son emplacement d'origine avec la justification, jamais supprimé sans trace.

**Sources** : README officiel, structure complète du code source (`src/screens`, `src/components`, `src/hooks`, `src/constants`, `src/navigation`), et lecture directe de plusieurs écrans clés (`OrderScreen`, `ProofOfDeliveryScreen`, `ChatHomeScreen`, `DriverDashboardScreen`, `DriverOrderManagementScreen`, `FuelReportForm`, `IssueForm`) — repo public `fleetbase/navigator-app`, consulté le 27/07/2026.

---

## 1. Personas et objectif

**Utilisateur unique de cette app** : le **transporteur/driver** — qu'il fasse partie du pool mutualisé "Echango Delivery" ou d'une Fleet dédiée à un gestionnaire de petite flotte (voir `CLAUDE.md` § Architecture). Un seul type d'utilisateur, contrairement aux deux autres interfaces custom du projet (commerçant, gestionnaire de petite flotte).

**Objectif** : recevoir des commandes (adhoc ou assignées), les exécuter (navigation, étapes, preuve de livraison), suivre son statut/historique, et signaler un échec de livraison le cas échéant (§4.3). **Chat et rapports carburant explicitement hors périmètre** (décision utilisateur 27/07/2026, voir §6/§7).

---

## 2. Authentification

Repris intégralement du périmètre Navigator :

- **Connexion email/mot de passe** (écran de login standard)
- **Connexion par téléphone** avec vérification par code (SMS OTP) — deux écrans : saisie du numéro, puis saisie du code de vérification
- **Création de compte** avec vérification (deux écrans symétriques à la connexion par téléphone)
- **Connexion sociale** :
  - Apple Sign-In (`@invertase/react-native-apple-authentication` → équivalent Flutter : `sign_in_with_apple`)
  - Google Sign-In (`@react-native-google-signin/google-signin` → équivalent Flutter : `google_sign_in`)
  - Facebook Login (`react-native-fbsdk-next` → équivalent Flutter : `flutter_facebook_auth`)
- **Écran de démarrage** (Boot/Splash) — vérifie session existante, redirige vers login ou dashboard
- **Écran d'avertissement de configuration** (Setup Warning) — affiché si la config API Fleetbase est absente/invalide au démarrage
- **Gestion de lien d'instance** (Instance Link) — deep link permettant d'ouvrir l'app sur une ressource précise (ex. lien de suivi partagé)

### 2.1 Authentification via BFF — décision (27/07/2026)

Contrairement à Navigator, qui s'authentifie directement contre l'API Fleetbase avec une clé API embarquée au build, **l'app driver passe systématiquement par le BFF** — même principe que les deux autres interfaces custom (`docs/specs_bff.md` §5) : le client Flutter ne détient et n'appelle jamais Fleetbase directement, un seul système d'auth Echango (Bearer token) pour les trois interfaces.

**Modèle retenu : proxy par compte de service, pas de credential Fleetbase individuel par driver** — même schéma que le persona "petite flotte" (`docs/specs_bff.md` §2.2), pour une raison différente mais tout aussi valable :

- Un vrai `Driver`/`User` Fleetbase **doit** exister pour chaque transporteur — contrairement au facilitateur, ce n'est pas contournable : le matching géospatial natif du dispatch adhoc (`HandleOrderDispatched`) et l'assignation ciblée (`driver_assigned_uuid`) opèrent nativement sur ce modèle, déjà validé de bout en bout côté serveur (`docs/specs_echango_delivery.md` §3.2).
- **Ce qui est évitable, en revanche** : que l'app Flutter détienne elle-même un token Fleetbase valide pour ce Driver. Contrairement au persona commerçant (`customer-portal-api`, scoping natif testé et validé), **aucun mécanisme équivalent "driver-portal" n'a été testé ni même repéré côté Fleetbase** — pas de découverte équivalente à `fleetbase/customer-portal` pour ce persona à ce jour. Répliquer le pattern "token Sanctum individuel géré par le BFF" (§5.1 de `docs/specs_bff.md`, pensé pour le commerçant) supposerait de faire confiance à un scoping driver natif jamais vérifié.
- **Décision** : le BFF utilise un **compte de service Fleetbase partagé** (même famille de compte que celui du persona petite flotte, cf. `docs/specs_bff.md` §5.2) pour lire/écrire les ressources driver (commandes assignées, position, statut en ligne, jeton push, activité), et **filtre lui-même** chaque réponse par identité du driver connecté (`driver_assigned_uuid` = le sien, ou commande adhoc dans son rayon) avant de la renvoyer au client — même discipline anti-IDOR que les deux autres personas (`docs/specs_bff.md` §5.3).
- **Bénéfice direct** : cohérence totale des trois interfaces sur un seul modèle de sécurité à auditer (un compte de service Fleetbase par famille de persona non couverte par un portail officiel, jamais de credential Fleetbase individuel chez un client final), plutôt que d'inventer un troisième schéma pour ce troisième persona.
- **Identité du driver côté Echango** : un compte Echango (email/téléphone/social login, §2 ci-dessus) mappé à un `driver_uuid` Fleetbase — ce mapping est déclaré une fois au provisioning (création manuelle du Driver Fleetbase + rattachement, cohérent avec la recommandation "provisioning manuel d'abord" déjà actée pour le commerçant, `docs/specs_bff.md` §2.1).

**Conséquence pour §11 (temps réel)** : voir la décision correspondante ci-dessous — le canal FCM/APN natif de Fleetbase (`OrderPing`) cible directement le `Driver` Fleetbase (champ jeton push sur son enregistrement), pas le compte Echango. Le BFF doit donc, à l'enregistrement du jeton push par l'app, l'écrire sur le `Driver` Fleetbase correspondant via son compte de service — un pont nécessaire entre les deux couches d'identité.

---

## 3. Tableau de bord driver (Dashboard)

Écran d'accueil une fois connecté. Repris de `DriverDashboardScreen` :

- **Statut de tracking** : indicateur si la géolocalisation en tâche de fond est active (Oui/Non, avec code couleur)
- **Données de position en temps réel** : latitude, longitude, cap (heading), altitude — affichées en grille
- **Compteur de commandes actives** : nombre de commandes en cours, affiché en gros chiffres (style "odomètre" animé)
- **Vitesse actuelle** : vitesse du véhicule en temps réel (0 par défaut si indisponible), même style visuel
- **Thème adaptatif** clair/sombre

---

## 4. Gestion des commandes

Le cœur fonctionnel de l'app, réparti sur deux écrans principaux : liste des commandes et détail d'une commande.

### 4.1 Écran de gestion des commandes (liste)

Repris de `DriverOrderManagementScreen` :

- **Vue calendrier** : bandeau de sélection de date (calendar strip), permet de voir les commandes par date sur l'année en cours
- **Trois catégories de commandes affichées** :
  1. **Commandes actives en cours** — commandes non terminées (exclut les statuts "completed", "created", "canceled")
  2. **Commandes adhoc (opportunités)** — commandes non assignées, dispatchées par broadcast géospatial (voir `docs/specs_echango_delivery.md` §3.2) ; les commandes explicitement rejetées ("dismissed") sont masquées
  3. **Commandes historiques** — affichées quand aucune commande en cours n'existe
- **Statistiques d'en-tête** : nombre total de commandes, nombre total d'arrêts (pickup + dropoff + waypoints), durée et distance cumulées
- **Rafraîchissement automatique** :
  - Commandes à proximité (adhoc) : toutes les 5 minutes
  - Commandes en cours : toutes les 15 minutes
  - Écoute en temps réel des événements serveur `order.ready` et `order.ping` (WebSocket/SocketCluster)
- **Pull-to-refresh** manuel

**Cartes de commande** (3 variantes visuelles) :
- Carte standard (commande assignée normale)
- Carte historique (commande passée/terminée)
- Carte adhoc (avec actions Accepter/Rejeter directement sur la carte)

### 4.2 Écran détail d'une commande

Repris de `OrderScreen` — l'écran le plus riche de l'app.

**Actions disponibles selon le type/statut de commande** :

- **Commandes adhoc** :
  - **Accepter** — assigne le driver et démarre immédiatement
  - **Rejeter/Ignorer** — retire la commande de la liste des opportunités (côté driver uniquement, ne bloque pas le retry automatique serveur toutes les ~4 minutes, cf. `docs/specs_echango_delivery.md` §3.2)
- **Commandes standard (assignées)** :
  - **Démarrer la commande** — passe au statut "started"
  - **Mettre à jour l'activité** — fait progresser la commande à travers ses étapes/waypoints (created → dispatched → started → enroute → completed, machine à états native Fleetbase, cf. `docs/specs_echango_delivery.md` §3.1)
  - **Démarrer la navigation** — lance une app de cartographie externe (Google Maps, Waze, Apple Plans) vers la destination actuelle
  - **Changer la destination actuelle** — sélection manuelle d'un autre waypoint comme prochaine destination si la tournée a plusieurs arrêts
- **Preuve de livraison** — navigation vers l'écran dédié POD (§5) quand la config de la commande l'exige (`pod_method`, `require_pod`)

**Données affichées** :

- **Informations de suivi** : QR code, numéro de suivi (tracking number), horodatage de création, badge de statut coloré
- **Détails d'itinéraire** : carte en direct montrant prise en charge, waypoints intermédiaires, dépose
- **Métriques de progression** : distance, ETA, pourcentage de complétion, destination actuelle/suivante
- **Métadonnées de commande** : IDs, type, dates planifiée/dispatchée, champs personnalisés
- **Contenu (payload)** : items et entités associés à chaque destination
- **Détails client** : coordonnées du contact quand disponibles
- **Documentation** : fichiers et preuves déjà attachés à la commande
- **Fil de commentaires** : échange driver ↔ dispatcher/opérateur
- **Notes de commande** : instructions spéciales

**Interactions** :
- Pull-to-refresh
- Écoute des changements de statut serveur en temps réel (WebSocket)
- États de chargement pendant les transitions d'activité
- Éléments UI conditionnels selon le statut (pas commencé / en cours / terminé)

### 4.3 Échec de livraison — remplace le système d'incidents générique de Navigator (décision 27/07/2026)

**Contexte de cette décision** : Navigator a un système de signalement d'incidents séparé (§8, ancien), avec 9 catégories génériques de fleet-management (véhicule, driver, itinéraire, cargo, logiciel, opérationnel, client, sécurité, environnemental) — la plupart sans rapport avec l'usage d'Echango Delivery. Le seul besoin réel confirmé est plus étroit : **signaler qu'une livraison a échoué**, pas un système de ticketing fleet-ops complet.

**Action ajoutée à l'écran détail commande (§4.2)** : en plus de "Démarrer"/"Mettre à jour l'activité", le driver peut marquer une étape (waypoint) comme **échouée** plutôt que complétée :

- **Raison de l'échec** — sélecteur avec une liste courte et spécifique à la livraison (à valider avec l'équipe métier, proposition de départ) : Client absent, Adresse introuvable, Client a refusé le colis, Colis endommagé/manquant, Accès impossible (site fermé, zone inaccessible), Autre (texte libre)
- **Photo optionnelle** — preuve visuelle de la situation (ex. porte fermée, colis endommagé), réutilise la même capacité caméra que la POD (§5, `camera` Flutter)
- **Note libre optionnelle** — complément texte

**Comportement** : la commande/le waypoint passe dans un statut d'échec (mécanisme natif Fleetbase à confirmer — la machine à états `order_config` a déjà une notion d'échec de livraison selon la doc, cf. `docs/specs_echango_delivery.md` §3.1 sur `pod_method`/`require_pod` par étape ; à vérifier si un statut "failed" existe nativement par étape ou s'il faut le simuler via une note + statut "completed" côté Fleetbase avec le détail réel géré uniquement côté BFF/Echango). Le dispatcher/opérateur doit voir cette information pour décider d'une reprogrammation ou d'un remboursement — canal de visibilité (notification au commerçant ? à l'opérateur Echango ?) à définir avec les règles métier de `docs/specs_echango_delivery.md` §6.

**Ce qui n'est PAS repris** : les 9 catégories génériques Navigator (véhicule, driver, itinéraire, logiciel, opérationnel, client, sécurité, environnemental) et leur système de priorité/statut de ticket — jugées hors sujet pour ce projet.

---

## 5. Preuve de livraison (Proof of Delivery — POD)

Repris de `ProofOfDeliveryScreen` — **trois méthodes supportées**, sélectionnées dynamiquement selon le `pod_method` configuré sur la commande :

1. **Scan QR/code-barres** — validation via scanner intégré, appel serveur de capture du code
2. **Capture photo** — ouverture caméra, redimensionnement de l'image, upload en `multipart/form-data`
3. **Signature manuscrite** — canvas de signature interactif (capture tactile)

**Données capturées** : la commande, le waypoint concerné, l'entité (item) associée, l'activité en cours de traitement.

**Comportement à la soumission** : stockage de l'objet preuve avec métadonnées d'activité/commande, retour à l'écran précédent. Gestion d'erreur avec notification toast si échec de capture/upload.

**Overlay de chargement** pendant traitement.

---

## 6. Chat / Messagerie — ❌ Hors périmètre (décision 27/07/2026)

Navigator propose un système de chat complet (`ChatHomeScreen`, `ChatChannelScreen`, `ChatParticipantsScreen`, `CreateChatChannelScreen` — liste de canaux, fil de messages, pièces jointes, gestion de participants). **Retiré du périmètre sur décision explicite** : jugé inutile pour ce projet.

**Conservé malgré tout** (différent du chat, pas concerné par cette décision) : le fil de commentaires attaché à une commande spécifique (`OrderCommentThread`, mentionné en §4.2) — plus léger qu'un vrai système de chat (pas de canaux, pas de participants à gérer), simple échange de notes driver ↔ dispatcher sur une commande précise. À reconfirmer si toujours souhaité, mais non retiré par cette décision qui visait le chat générique.

---

## 7. Rapports carburant (Fuel Reports) — ❌ Hors périmètre (décision 27/07/2026)

Navigator propose un formulaire de rapport carburant (`FuelReportForm` — statut, odomètre, volume, coût ; écrans de création/édition/détail). **Retiré du périmètre sur décision explicite** : jugé inutile pour ce projet.

---

## 8. Échec de livraison — remplace le signalement d'incidents générique de Navigator

**Ancien périmètre Navigator** (`IssueForm`/`CreateIssueScreen`/`EditIssueScreen`/`IssueScreen`) : système de ticketing générique fleet-ops, 5 champs (type, catégorie, priorité, statut, rapport texte) et **9 catégories** couvrant véhicule, driver, itinéraire, cargo/colis, logiciel/technique, opérationnel, client, sécurité, durabilité environnementale — la plupart hors sujet pour Echango Delivery (ex. "vulnérabilités de sécurité logicielle", "empreinte carbone").

**Clarification faite le 27/07/2026** : le vrai besoin derrière "incident" n'est pas ce système générique, mais un signalement d'**échec de livraison** (client absent, adresse introuvable, colis refusé/endommagé) — mécanisme différent, intégré à la commande elle-même plutôt qu'un système de tickets séparé. **Voir §4.3** pour la spec complète de ce remplacement (raison d'échec + photo optionnelle + note, action ajoutée directement à l'écran détail commande).

**Ce paragraphe est conservé à cet emplacement** (plutôt que supprimé) pour la traçabilité : il documente explicitement ce qui a été écarté du périmètre Navigator et pourquoi, cohérent avec la méthode de ce document (ne rien omettre silencieusement, §"Méthode" en tête de document).

---

## 9. Gestion de flotte et véhicule

Repris de `FleetScreen`, `VehicleScreen`, `DriverFleetScreen` :

- Vue de la/des Fleet(s) auxquelles le driver appartient
- Détail véhicule assigné
- **Cohérence avec notre modèle** : un driver peut appartenir à plusieurs Fleets simultanément (many-to-many natif Fleetbase, cf. `docs/journal_exploration_fleetbase.md` §6.3) — ex. pool mutualisé + Fleet dédiée d'un gestionnaire de petite flotte. L'app doit donc pouvoir afficher/refléter cette appartenance multiple, pas supposer une seule Fleet par driver.

---

## 10. Compte et profil

Repris de `DriverAccountScreen`, `DriverProfileScreen`, `EditAccountPropertyScreen` :

- Vue du compte (infos générales, paramètres)
- Vue/édition du profil (nom, photo, coordonnées)
- Édition individuelle de propriétés de compte (écran générique réutilisable pour éditer un champ à la fois)

**Autres écrans transverses repris** :
- `EntityScreen` — détail d'une entité/item de commande
- `EditLocationScreen` / `EditLocationCoordScreen` — édition d'une position (adresse ou coordonnées GPS directes)
- `LocationPermissionScreen` — demande/statut de la permission de géolocalisation
- `DriverOnlineToggle` (composant, pas écran dédié) — bascule en ligne/hors ligne, condition nécessaire pour recevoir des commandes adhoc (cf. `docs/specs_echango_delivery.md` §3.2, le driver de test devait être mis `online=1` manuellement faute de ce toggle actif)
- `DriverReportScreen` (Navigator) — dans l'original, vue consolidée carburant + incidents ; **non repris tel quel** (carburant hors périmètre, §7) — remplacé si besoin par un historique des échecs de livraison du driver (§4.3), à faire vivre plutôt dans l'historique de commandes (§4.1) que comme écran séparé
- `TestScreen` — écran de développement/diagnostic, non destiné à la prod (à ne pas répliquer)

---

## 11. Capacités techniques transverses (mapping RN → Flutter)

Repris de l'analyse des dépendances `package.json` de Navigator, avec équivalent Flutter proposé :

| Capacité | Lib React Native (Navigator) | Équivalent Flutter proposé |
|---|---|---|
| **Géolocalisation en tâche de fond** | `react-native-background-geolocation` (Transistor Software, commercial) | **`geolocator` + `flutter_foreground_task`** — voir décision et justification ci-dessous, choix délibérément open source |
| **Cartes** | `react-native-maps` + `react-native-maps-directions` | `google_maps_flutter` + calcul d'itinéraire via API dédiée (OSRM/Google Directions) |
| **Navigation externe** | `react-native-launch-navigator` | `map_launcher` ou intents natifs (`url_launcher` avec schémas Google Maps/Waze/Apple Plans) |
| **Caméra** | `react-native-vision-camera` | `camera` (package Flutter officiel) |
| **Accès galerie photo** | `@react-native-camera-roll/camera-roll` | `photo_manager` ou `image_picker` |
| **Sélection/redimensionnement image** | `react-native-image-picker` + `@bam.tech/react-native-image-resizer` | `image_picker` + `flutter_image_compress` |
| **Notifications push** | `react-native-notifications` | `firebase_messaging` (FCM) + `flutter_local_notifications` |
| **Tâches en arrière-plan** | `react-native-background-fetch` | `workmanager` |
| **Stockage local rapide** | `react-native-mmkv` | `shared_preferences` (simple) ou `hive`/`isar` (structuré) |
| **Stockage sécurisé (credentials)** | `react-native-keychain` | `flutter_secure_storage` |
| **Accès système de fichiers** | `react-native-fs` | `path_provider` + `dart:io` |
| **Connexion Apple** | `@invertase/react-native-apple-authentication` | `sign_in_with_apple` |
| **Connexion Google** | `@react-native-google-signin/google-signin` | `google_sign_in` |
| **Connexion Facebook** | `react-native-fbsdk-next` | `flutter_facebook_auth` |
| **Internationalisation** | `react-native-i18n` + `react-native-localize` | `flutter_localizations` + `intl` |
| **WebSocket temps réel** | `socketcluster-client` | **Non repris — remplacé par push FCM/APN natif + polling REST**, voir décision et justification ci-dessous |
| **Scan QR code** | (composant `QrCodeScanner`, lib non identifiée précisément) | `mobile_scanner` |
| **Signature manuscrite** | `SignatureCanvas` (composant) | `signature` (package Flutter) |
| **Animations** | `react-native-reanimated` | Animations Flutter natives (`AnimationController`) |
| **Framework UI** | `tamagui` | Widgets Flutter natifs + `Material`/`Cupertino` |

### 11.1 Stratégie temps réel — décision (27/07/2026)

**Retenu : push FCM/APN natif Fleetbase comme déclencheur, polling REST via BFF pour tout le reste. Pas de client SocketCluster en Dart.**

Raisonnement :

- **Aucun client SocketCluster mature n'existe pour Flutter/Dart** — implémenter le protocole nous-mêmes (`web_socket_channel` + réimplémentation du protocole SocketCluster côté client) serait un chantier disproportionné pour un besoin déjà couvert autrement.
- **Le canal qui compte vraiment (dispatch adhoc + assignation ciblée) est déjà natif et déjà validé de bout en bout côté serveur** : `OrderPing` (`docs/specs_echango_delivery.md` §3.2) implémente `ShouldQueue` avec des canaux `broadcast` (WebSocket), `FcmChannel` et `ApnChannel` — **le canal FCM/APN ne nécessite aucun développement serveur supplémentaire**, juste la configuration d'un projet Firebase Echango (voir ci-dessous) et l'enregistrement du jeton push sur le `Driver` Fleetbase correspondant.
- **Tout le reste** (rafraîchissement de la liste de commandes, progression du détail d'une commande, messages de chat) **passe en polling REST via le BFF** — cohérent avec la recommandation déjà actée pour les deux autres interfaces custom (`docs/specs_echango_delivery.md` §8 : "polling recommandé pour V1"). Garde une seule stratégie temps réel across les trois apps, plus simple à maintenir qu'un mélange WebSocket + polling.

**Implémentation concrète** :
1. Un projet **Firebase** dédié à Echango (pas celui de Fleetbase) — `google-services.json` / `GoogleService-Info.plist` intégrés à l'app Flutter (`firebase_messaging`).
2. Les identifiants serveur de ce même projet Firebase configurés côté backend Fleetbase (variables d'environnement FCM déjà prévues nativement par `FcmChannel`, aucun code à écrire côté Fleetbase).
3. À la connexion, l'app enregistre son jeton FCM auprès du BFF (`POST /transporteur/device-token`) ; le BFF l'écrit sur le `Driver` Fleetbase correspondant via son compte de service (§2.1).
4. Réception d'un `OrderPing` → notification système → l'app réveille et déclenche un fetch REST via BFF pour récupérer le détail de la commande (jamais de payload métier transmis directement dans la notification push elle-même, uniquement un identifiant + déclencheur, principe de précaution sur des données potentiellement sensibles transitant par un tiers Firebase).

**Limite assumée, à valider par un test réel une fois l'app construite** : ce choix reproduit exactement le test qu'on voulait faire avec Navigator (§ session du 27/07/2026) — la seule vraie preuve que ça fonctionne est un device réel avec l'app installée, jeton FCM enregistré, recevant effectivement une commande adhoc. Rien de nouveau à inventer côté serveur, mais la boucle complète reste à re-valider avec notre propre client, pas avec Navigator.

### 11.2 Géolocalisation en tâche de fond — décision (27/07/2026) : open source uniquement

**Rejeté** : `flutter_background_geolocation` (Transistor Software) — même éditeur que la librairie React Native utilisée par Navigator, mais **licence commerciale**. Écarté par principe : préférence explicite pour des solutions open source sur ce projet.

**Retenu : `geolocator` (MIT) + `flutter_foreground_task` (MIT)** :
- **`geolocator`** — API de position (ponctuelle + flux continu), multiplateforme, aucune dépendance à un service commercial.
- **`flutter_foreground_task`** — service Android de premier plan (foreground service) avec notification persistante, nécessaire pour que la géolocalisation continue de fonctionner quand l'app est en arrière-plan (obligatoire de toute façon sur Android 10+ pour un accès fiable à la position en tâche de fond, indépendamment du choix de librairie). Sur iOS, complété par la configuration native standard (`UIBackgroundModes: location` dans `Info.plist`) et la permission "Toujours autoriser" — capacité native de la plateforme, pas une fonctionnalité tierce.

**Compromis assumé et à documenter comme risque, pas à ignorer** : les solutions commerciales comme Transistor existent précisément parce que la géolocalisation fiable en arrière-plan sur mobile est difficile à faire robuste dans la durée (gestion fine de la précision/fréquence pour économiser la batterie, résilience aux politiques agressives de kill d'app par les OEM Android, heuristiques propriétaires accumulées sur des années). La pile open-source retenue est fonctionnellement suffisante pour un MVP mais **doit être testée en conditions réelles tôt** (device physique, usage prolongé, différents fabricants Android) avant d'être considérée fiable pour une flotte de transporteurs en production — à inscrire explicitement dans le plan de test du développement de cette app, pas supposé acquis par ce document.

---

## 12. Modèles de données impliqués

Cohérents avec les modèles Fleetbase déjà validés dans `docs/specs_echango_delivery.md` et `docs/journal_exploration_fleetbase.md` :

- **Order** — commande, avec `facilitator`/`customer` polymorphiques, `driver_assigned_uuid`, `adhoc`, machine à états (`order_config`), waypoints, `required_skills`, `time_window_start/end`
- **Waypoint** — arrêt d'une commande (pickup/dropoff/étape intermédiaire)
- **Entity** — item/colis associé à un waypoint
- **Driver** — le transporteur, avec `location`, `online`/statut, `skills`
- **Vehicle** — véhicule assigné au driver
- **Fleet** — regroupement de drivers (many-to-many), potentiellement rattaché à un `Vendor`

**Retirés du périmètre** (§6/§7, décision 27/07/2026) : Chat channel/message, FuelReport — non nécessaires, pas de modèle de données à prévoir pour ces deux fonctionnalités.

**Échec de livraison** (§4.3, remplace Issue) : pas de nouveau modèle Fleetbase — s'appuie sur le statut/activité existant de `Order`/`Waypoint`, complété d'une raison + photo optionnelle. **Point à vérifier avant dev** : existe-t-il un statut natif "failed" par étape dans la machine à états `order_config` (cf. `docs/specs_echango_delivery.md` §3.1), ou faut-il gérer ce détail uniquement côté BFF/Echango (Fleetbase voit juste "completed", le détail réel de l'échec vit dans notre propre couche) ? Non testé en pratique à ce jour.

---

## 13. Questions ouvertes avant développement

### Décisions actées (27/07/2026)

1. ~~Authentification directe Fleetbase vs via BFF~~ **✅ Tranché : via BFF**, modèle proxy par compte de service (§2.1), même famille de solution que le persona petite flotte.
2. ~~Temps réel : WebSocket SocketCluster vs push FCM/APN~~ **✅ Tranché : push FCM/APN natif comme déclencheur + polling REST pour le reste** (§11.1), pas de client SocketCluster Dart.
3. ~~`flutter_background_geolocation` (licence commerciale)~~ **✅ Tranché : rejeté, remplacé par `geolocator` + `flutter_foreground_task` (open source)** (§11.2) — compromis d'implémentation assumé, à valider en test réel avant mise en prod (voir §11.2, limite documentée).

### Périmètre tranché (27/07/2026, 2e passage)

4. ~~Chat~~ **❌ Retiré du périmètre** (§6) — jugé inutile.
5. ~~Rapports carburant~~ **❌ Retiré du périmètre** (§7) — jugé inutile.
6. ~~Signalement d'incidents générique (9 catégories fleet-ops)~~ **❌ Retiré, remplacé par un mécanisme ciblé "échec de livraison"** (§4.3/§8) — seul besoin réel confirmé derrière la question initiale.

### Reste ouvert

7. **Statut natif "failed" par étape ?** (§4.3, §12) — la machine à états `order_config` de Fleetbase a-t-elle un statut d'échec par waypoint, ou faut-il gérer ce détail entièrement côté BFF ? Non testé en pratique à ce jour.
8. **Provisioning du compte driver** — qui crée le `Driver`/`User` Fleetbase et le mapping vers le compte Echango (§2.1) ? Même question que pour le commerçant (`docs/specs_bff.md` §2.1, §8.1) : self-service vs manuel. Recommandation par défaut inchangée : commencer manuel.
9. **Test réel de la boucle FCM/APN une fois l'app construite** (§11.1) — la conception s'appuie sur un pipeline serveur déjà validé, mais la réception effective par un vrai device n'aura été testée avec aucun client (ni Navigator, abandonné avant d'y arriver, ni notre app, pas encore construite) tant que ce test n'est pas refait avec notre propre client.
10. **Robustesse terrain de la géolocalisation open source** (§11.2) — à tester sur device physique, usage prolongé, plusieurs fabricants Android, avant de la considérer fiable pour une flotte en production.
11. **Portée MVP vs V2 sur le périmètre restant** — proposition de découpage à valider avec l'équipe produit :
    - **MVP plausible** : authentification simple (email/password), dashboard, liste + détail commande, actions dispatch (accepter/rejeter adhoc, démarrer, mettre à jour activité, navigation externe), POD (au moins une méthode, ex. signature ou photo), toggle en ligne/hors ligne, échec de livraison (§4.3)
    - **V2 plausible** : connexions sociales (téléphone/Apple/Google/Facebook — email/password suffit en MVP), POD multi-méthodes (QR + photo + signature, une seule méthode suffit en MVP), gestion de flotte/véhicule détaillée, internationalisation
    - **Cette proposition est une suggestion, pas une décision** — à valider explicitement, pas à déduire silencieusement de ce document.

---

## 14. Rebranding

Contrairement à Navigator (app tierce à rebrander), notre app étant construite from scratch en Flutter, le rebranding est natif dès la conception :
- Nom, identifiant de bundle, icône, splash screen : définis dès le scaffold initial du projet (`flutter create` avec les bons paramètres), pas une étape de patch a posteriori
- Palette de couleurs, thème : définis comme design system Flutter dès le départ, cohérent avec les deux autres interfaces custom (commerçant, petite flotte) et avec l'identité Echango

---

## Annexes

- `docs/navigator_test_findings.md` — pourquoi Navigator est abandonné (blocages techniques réels)
- `docs/specs_echango_delivery.md` — modèle Fleetbase validé (Vendor/Fleet/Facilitator/Customer, dispatch adhoc, customer-portal-api)
- `docs/specs_bff.md` — architecture BFF pour les deux autres interfaces custom (commerçant, petite flotte) — principes potentiellement applicables à cette app driver, point ouvert §13.1
- `CLAUDE.md` — décisions produit et questions ouvertes du projet
- Repo source consulté : [`fleetbase/navigator-app`](https://github.com/fleetbase/navigator-app) (React Native, AGPL-3.0)
