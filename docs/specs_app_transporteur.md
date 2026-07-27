# Specs — App Transporteur Echango (Flutter)

**Date** : 27 juillet 2026
**Statut** : Spécification fonctionnelle complète, dérivée des specs de Fleetbase Navigator — base de référence avant développement.
**Contexte** : suite à `docs/navigator_test_findings.md` (Navigator abandonné — blocages d'installation/compilation structurels, crash au démarrage documenté, dépendances React Native 0.86 instables), décision de construire une **app transporteur custom en Flutter pur** plutôt que d'utiliser/forker Navigator.

**Méthode de ce document** : Navigator (`fleetbase/navigator-app`, React Native, AGPL) est l'app officielle Fleetbase pour les transporteurs, avec un périmètre fonctionnel mature et éprouvé (dispatch, POD, chat, rapports, gestion de flotte). Plutôt que de repartir de zéro, ce document **reprend l'intégralité de son périmètre fonctionnel** (écrans, actions, données, intégrations techniques) et le retranscrit comme spec cible pour notre propre app Flutter — **rien n'est volontairement omis** à ce stade ; le tri MVP vs V2 est fait explicitement en §10, pas par omission silencieuse.

**Sources** : README officiel, structure complète du code source (`src/screens`, `src/components`, `src/hooks`, `src/constants`, `src/navigation`), et lecture directe de plusieurs écrans clés (`OrderScreen`, `ProofOfDeliveryScreen`, `ChatHomeScreen`, `DriverDashboardScreen`, `DriverOrderManagementScreen`, `FuelReportForm`, `IssueForm`) — repo public `fleetbase/navigator-app`, consulté le 27/07/2026.

---

## 1. Personas et objectif

**Utilisateur unique de cette app** : le **transporteur/driver** — qu'il fasse partie du pool mutualisé "Echango Delivery" ou d'une Fleet dédiée à un gestionnaire de petite flotte (voir `CLAUDE.md` § Architecture). Un seul type d'utilisateur, contrairement aux deux autres interfaces custom du projet (commerçant, gestionnaire de petite flotte).

**Objectif** : recevoir des commandes (adhoc ou assignées), les exécuter (navigation, étapes, preuve de livraison), suivre son statut/historique, communiquer avec l'opérateur/client, et signaler des événements (carburant, incidents).

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

**Note d'architecture à trancher (§10)** : Navigator s'authentifie directement contre l'API Fleetbase avec une clé API embarquée au build. Pour notre app, reste à décider si l'authentification driver passe par le BFF (cohérent avec le principe déjà acté pour les deux autres interfaces custom, `docs/specs_bff.md` §5) ou reste un appel direct à Fleetbase comme Navigator — **point ouvert, pas tranché dans ce document**.

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

## 6. Chat / Messagerie

Repris intégralement (`ChatHomeScreen`, `ChatChannelScreen`, `ChatParticipantsScreen`, `CreateChatChannelScreen`) :

### 6.1 Liste des conversations (Chat Home)

- Liste des canaux de chat de l'utilisateur courant
- Bouton flottant "+" pour créer un nouveau canal
- **Par canal affiché** : avatar du/des participant(s), titre du canal, aperçu du dernier message (avec nom de l'expéditeur si 3+ participants), horodatage (format type WhatsApp), badge de messages non lus (compteur vert, affiché seulement si > 0)
- Pull-to-refresh
- Écoute WebSocket temps réel : rafraîchissement automatique sur nouveau message, ajout/retrait de participant, création/suppression de canal

### 6.2 Écran de conversation (Chat Channel)

- Fil de messages (`ChatFeed`, `ChatLog`, `ChatMessage`)
- Clavier de saisie dédié (`ChatKeyboard`)
- Pièces jointes (`ChatAttachment`)
- Avatars des participants (`ChatParticipantAvatar`)

### 6.3 Gestion des participants

- Écran dédié listant/gérant les participants d'un canal (`ChatParticipants`, `ChatParticipantsScreen`)

### 6.4 Création de canal

- Écran dédié de création (`CreateChatChannelScreen`)

### 6.5 Commentaires sur commande (distinct du chat)

- `Comment`/`CommentThread`/`OrderCommentThread` — fil de commentaires attaché à une commande spécifique (différent des canaux de chat génériques), déjà mentionné en §4.2 comme partie de l'écran détail commande.

---

## 7. Rapports carburant (Fuel Reports)

Repris de `FuelReportForm`/`CreateFuelReportScreen`/`EditFuelReportScreen`/`FuelReportScreen` :

**Champs du formulaire** (4 champs, tous obligatoires pour activer la soumission) :

1. **Statut** — sélecteur (bottom sheet)
2. **Kilométrage/odomètre** — saisie texte ("Input your current odometer...")
3. **Volume de carburant** — saisie avec unité (`UnitInput`, ex. litres/gallons — voir unités disponibles en §9)
4. **Coût** — saisie monétaire (`MoneyInput`)

**Soumission** : inclut aussi automatiquement l'ID du driver et la position actuelle (géolocalisation au moment du rapport).

**Écrans** : création, édition, et vue détail d'un rapport existant.

**Non présent dans Navigator** (à noter, pas à supposer) : pas de champ véhicule explicite, pas de photo de reçu, pas de champ notes libres — le formulaire est volontairement minimal.

---

## 8. Signalement d'incidents (Issues)

Repris de `IssueForm`/`CreateIssueScreen`/`EditIssueScreen`/`IssueScreen` :

**Champs du formulaire** (5 champs) :

1. **Type d'incident** — sélecteur
2. **Catégorie** — sélecteur, filtré selon le type choisi
3. **Priorité** — sélecteur
4. **Statut** — sélecteur
5. **Rapport détaillé** — zone de texte libre

**9 catégories d'incidents avec sous-types** (`IssueCategory.ts`, repris intégralement) :

| Catégorie | Sous-types |
|---|---|
| **Véhicule** | Problèmes mécaniques, dommages esthétiques, problèmes de pneus, électronique/instruments, alertes de maintenance, problèmes d'efficacité carburant |
| **Driver** | Comportement, documentation, gestion du temps, communication, besoins de formation, violations santé/sécurité |
| **Itinéraire** | Itinéraires inefficaces, préoccupations sécurité, routes bloquées, considérations environnementales, conditions météo défavorables |
| **Cargo/Colis** | Marchandises endommagées, marchandises égarées, problèmes de documentation, marchandises sensibles à la température, chargement incorrect |
| **Logiciel/Technique** | Bugs, préoccupations UI/UX, échecs d'intégration, performance, demandes de fonctionnalité, vulnérabilités de sécurité |
| **Opérationnel** | Conformité, allocation de ressources, dépassements de coûts, communication, problèmes de gestion fournisseur |
| **Client** | Qualité de service, écarts de facturation, rupture de communication, retours/suggestions, erreurs de commande |
| **Sécurité** | Accès non autorisé, préoccupations données, sécurité physique, problèmes d'intégrité des données |
| **Durabilité environnementale** | Consommation carburant, empreinte carbone, gestion des déchets, opportunités d'initiatives vertes |

**Non présent dans Navigator** (à noter) : pas de pièce jointe photo, pas d'association explicite à une commande/véhicule dans le formulaire lui-même, pas de champ sous-type séparé (le sous-type semble géré comme un raffinement de la catégorie plutôt qu'un champ à part).

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
- `DriverReportScreen` — vue consolidée des rapports du driver (probablement carburant + incidents combinés)
- `TestScreen` — écran de développement/diagnostic, non destiné à la prod (à ne pas répliquer)

---

## 11. Capacités techniques transverses (mapping RN → Flutter)

Repris de l'analyse des dépendances `package.json` de Navigator, avec équivalent Flutter proposé :

| Capacité | Lib React Native (Navigator) | Équivalent Flutter proposé |
|---|---|---|
| **Géolocalisation en tâche de fond** | `react-native-background-geolocation` | `flutter_background_geolocation` (même éditeur, Transistor Software — licence commerciale déjà utilisée par Navigator, à vérifier/budgéter) |
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
| **WebSocket temps réel** | `socketcluster-client` | **Point ouvert** — pas de client SocketCluster natif Flutter connu ; déjà noté comme limite pour les deux autres interfaces custom (`docs/specs_echango_delivery.md` §8, recommandation polling REST). Pour l'app driver, le besoin est plus fort (recevoir un dispatch adhoc en temps quasi-réel) — polling seul risque d'être insuffisant ; à investiguer (WebSocket générique `web_socket_channel` en parlant directement le protocole SocketCluster, ou notification push FCM/APN comme déclencheur principal plutôt que WebSocket, cohérent avec ce que fait déjà `OrderPing`, cf. `docs/specs_echango_delivery.md` §3.2) |
| **Scan QR code** | (composant `QrCodeScanner`, lib non identifiée précisément) | `mobile_scanner` |
| **Signature manuscrite** | `SignatureCanvas` (composant) | `signature` (package Flutter) |
| **Animations** | `react-native-reanimated` | Animations Flutter natives (`AnimationController`) |
| **Framework UI** | `tamagui` | Widgets Flutter natifs + `Material`/`Cupertino` |

---

## 12. Modèles de données impliqués

Cohérents avec les modèles Fleetbase déjà validés dans `docs/specs_echango_delivery.md` et `docs/journal_exploration_fleetbase.md` :

- **Order** — commande, avec `facilitator`/`customer` polymorphiques, `driver_assigned_uuid`, `adhoc`, machine à états (`order_config`), waypoints, `required_skills`, `time_window_start/end`
- **Waypoint** — arrêt d'une commande (pickup/dropoff/étape intermédiaire)
- **Entity** — item/colis associé à un waypoint
- **Driver** — le transporteur, avec `location`, `online`/statut, `skills`
- **Vehicle** — véhicule assigné au driver
- **Fleet** — regroupement de drivers (many-to-many), potentiellement rattaché à un `Vendor`
- **Chat channel / message** — pas encore rencontré dans notre exploration précédente de l'API Fleetbase ; à valider si couvert par le même `fleetbase/fleetops` ou une extension séparée
- **FuelReport** — rapport carburant (statut, odomètre, volume, coût, driver, position)
- **Issue** — incident (type, catégorie, priorité, statut, rapport texte)

**Point à vérifier avant dev** (pas encore fait dans nos tests précédents) : le chat, les rapports carburant et les incidents sont-ils bien exposés par l'API Fleetbase "console" standard, ou nécessitent-ils une extension additionnelle (à la manière de `customer-portal` ou `ledger`) ? Non couvert par les tests réels déjà menés (`docs/specs_echango_delivery.md` §3).

---

## 13. Questions ouvertes avant développement

1. **Authentification directe Fleetbase vs via BFF** (§2) — cohérence à trancher avec le principe déjà acté pour les 2 autres interfaces custom.
2. **Temps réel : WebSocket SocketCluster vs push FCM/APN comme déclencheur principal** (§11) — critique pour la réception adhoc, à trancher avant de committer sur l'architecture temps réel de l'app.
3. **Chat, rapports carburant, incidents : quelle API Fleetbase les expose ?** (§12) — jamais vérifié en pratique, contrairement au reste de l'API déjà testé.
4. **`flutter_background_geolocation` a une licence commerciale** (le même éditeur que la lib React Native utilisée par Navigator) — coût à chiffrer avant de s'engager dessus ; alternative gratuite (`geolocator` + service en tâche de fond maison) moins robuste mais à considérer si le budget est un enjeu.
5. **Portée MVP vs V2** — ce document reprend l'intégralité du périmètre Navigator par exhaustivité (consigne explicite : ne rien omettre), mais tout ne doit probablement pas être développé dès la V1. Proposition de découpage à valider avec l'équipe produit :
   - **MVP plausible** : authentification simple (email/password), dashboard, liste + détail commande, actions dispatch (accepter/rejeter adhoc, démarrer, mettre à jour activité, navigation externe), POD (au moins une méthode, ex. signature ou photo), toggle en ligne/hors ligne
   - **V2 plausible** : chat, rapports carburant, incidents, connexions sociales, POD multi-méthodes (QR + photo + signature), gestion de flotte/véhicule détaillée, internationalisation
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
