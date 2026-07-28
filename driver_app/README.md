# Echango Delivery Driver App

Flutter mobile application for drivers using the Echango Delivery logistics platform.

## État réel au 28/07/2026 — lire avant de tester

Le reste de ce README décrit le **périmètre visé**. État réel de l'intégration :

| Fonctionnalité | Serveur | Client |
|---|---|---|
| Login email/mot de passe | ✅ validé en réel | ✅ aligné |
| Jeton push (+ purge à la rotation) | ✅ validé en réel | ✅ aligné |
| Profil / position / disponibilité | ✅ validé en réel | ✅ aligné |
| Commandes : liste, détail, accepter | ✅ validé en réel | ✅ aligné |
| Transitions d'état (`activites-suivantes` → `activite`) | ✅ validé en réel | ✅ aligné |
| Preuve photo, échec de livraison | ✅ validé en réel | ✅ aligné |
| Login téléphone/OTP et social | ❌ non implémenté | écrans présents, appels annotés |

Le serveur est validé de bout en bout par `scripts/test-{driver-auth,transporteur-module}.sh`
(détail : `docs/journal_implementation_bff.md` §6.19). Le client compile
(`flutter analyze` propre) et sa couche de données a été revue contre les
formes réelles (§7), mais **les écrans n'ont pas encore rendu de vraies
données** — c'est là que les écarts restants apparaîtront.

Deux limites connues côté écrans :
- l'écran détail propose des boutons figés « accepter / démarrer / terminer »,
  alors que les transitions réelles viennent du serveur et varient selon la
  commande (`activites-suivantes`) ;
- la capture photo n'est pas branchée : la clôture se fait sans preuve.

## Premier lancement — 3 étapes obligatoires

Le projet ne contient que `lib/` : **aucun dossier `android/` ou `ios/`**, donc
`flutter run` échoue tant que le scaffolding de plateforme n'est pas généré.

**1. Générer les plateformes** (à faire une fois, depuis `driver_app/`) :

```bash
flutter create . --platforms=android --org com.echango
flutter pub get
```

**2. Vérifier l'adresse du BFF.** `localhost` désigne l'appareil qui exécute
l'app, pas la machine de développement — sur émulateur il ne pointe sur rien,
d'où un « Network error » au premier lancement. La valeur par défaut vise
l'émulateur Android ; pour un autre support, surcharger au lancement plutôt
que d'éditer `lib/config/api_config.dart` :

| Cible | Valeur |
|---|---|
| Émulateur Android | `http://10.0.2.2:3001` *(défaut)* |
| Appareil physique | `http://<IP-LAN-du-PC>:3001` |
| Windows/desktop | `http://localhost:3001` |

```bash
flutter run --dart-define=BFF_BASE_URL=http://192.168.1.20:3001
```

Sur **appareil physique avec un BFF sous WSL2**, l'IP LAN du PC ne suffit pas :
WSL2 a sa propre pile réseau. Il faut une redirection de port
(`netsh interface portproxy`) et une règle de pare-feu. L'émulateur n'a pas ce
problème — `10.0.2.2` passe par le loopback de Windows.

**Éviter de retaper les identifiants.** Deux mécanismes :

- La **session est conservée** entre deux lancements (jeton en stockage
  sécurisé). Retaper ses identifiants à chaque fois signale une session
  expirée — 24 h par défaut — ou une réinstallation complète de l'app.
- En **debug uniquement**, un sélecteur de comptes de test permet de se
  connecter en un tap et de basculer entre transporteurs, ce qui est utile
  pour vérifier l'isolation des commandes. Les comptes sont fournis au build,
  jamais versionnés :

```bash
flutter run --dart-define=DEV_ACCOUNTS='[{"label":"Transporteur 1","email":"driver-test-10000@echango.local","password":"motdepasse123"},{"label":"Transporteur 2","email":"driver-test-2@echango.local","password":"motdepasse123"}]'
```

Sans cette variable, aucun raccourci n'apparaît. En build release, le
sélecteur est absent quoi qu'il arrive — un raccourci de connexion dans une
app distribuée serait une faille, pas une commodité. Le dernier email utilisé
est par ailleurs pré-rempli au lancement (l'email seul, jamais le mot de
passe).

**3. Autoriser le HTTP en clair** — Android bloque le trafic non-TLS depuis
l'API 28. Sans ça, chaque appel échoue en `CLEARTEXT communication not
permitted`. Pour du développement local uniquement, dans
`android/app/src/main/AndroidManifest.xml`, sur la balise `<application>` :

```xml
<application android:usesCleartextTraffic="true" …>
```

À retirer avant toute distribution : le BFF devra être servi en HTTPS.

**Firebase est optionnel.** `lib/config/firebase_options.dart` est un gabarit ;
l'initialisation est encadrée par un `try/catch` pour que l'app démarre sans.
Conséquence : pas de notification à l'arrivée d'une commande, il faut
rafraîchir manuellement. Tout le reste fonctionne.

## Getting Started

### Prerequisites

- Flutter SDK >= 3.20.0
- Dart SDK >= 3.0.0
- Firebase project set up with Cloud Messaging
- BFF API endpoint accessible

### Installation

1. Install dependencies:
```bash
flutter pub get
```

2. Configure Firebase:
   - Update `lib/config/firebase_options.dart` with your Firebase project details
   - iOS: Add `GoogleService-Info.plist` to `ios/Runner`
   - Android: Add `google-services.json` to `android/app`

3. Configure API endpoint:
   - Update `lib/config/api_config.dart` with your BFF base URL

### Running the App

Development:
```bash
flutter run
```

Release build:
```bash
flutter build apk     # Android
flutter build ipa     # iOS
```

## Project Structure

```
lib/
├── main.dart                 # App entry point
├── config/                   # Configuration
│   ├── api_config.dart       # API endpoints & constants
│   └── firebase_options.dart # Firebase configuration
├── errors/                   # Error handling
│   └── app_error.dart        # Centralized error codes
├── models/                   # Data models
│   └── order.dart            # Order, Place, DeliveryFailure
├── services/                 # Business logic
│   ├── bff_api_client.dart   # HTTP client for BFF
│   ├── notification_service.dart  # Firebase Cloud Messaging
│   └── location_service.dart # Background location tracking
├── state/                    # State management (ChangeNotifier)
│   ├── auth_state.dart       # Authentication state
│   └── order_state.dart      # Order management state
├── navigation/               # Navigation
│   └── app_router.dart       # GoRouter configuration
├── theme/                    # UI theming
│   └── app_theme.dart        # Material Design 3 theme
├── utils/                    # Utilities
│   └── logger.dart           # Simple logging
├── validation/               # Form validation
│   └── validators.dart       # Input validators
└── screens/                  # UI screens
    ├── splash_screen.dart
    ├── auth/
    │   ├── login_screen.dart
    │   └── otp_screen.dart
    └── dashboard/
        ├── dashboard_screen.dart     # Tabbed main screen
        ├── order_detail_screen.dart
        └── delivery_failure_screen.dart
```

## Features

### MVP v1.0

- **Authentication**: Email/password and Phone OTP login
- **Order Management**: View assigned orders with status tracking
- **Delivery Tracking**: Accept, start, and mark orders as delivered
- **Delivery Failure Reporting**: Report failures with reason and notes
- **Real-time Notifications**: Firebase Cloud Messaging for order updates
- **Location Tracking**: Background location tracking with geolocator
- **Profile**: Driver profile and settings

### Future Enhancements

- Photo evidence capture for proofs of delivery
- Advanced map integration with route optimization
- Chat messaging with customers
- Order history and analytics

## Architecture

### Authentication & Session Management
- **Email/Password Flow**: BFF `/auth/transporteur/login` → `{token, user}` → stored securely
- **Phone OTP Flow**: ❌ non implémenté côté BFF (voir tableau d'état ci-dessus)
- **Session Restoration**: Automatic token restoration on app launch
- **Inactivity Timeout**: 24-hour session expiry with automatic re-authentication prompt
- **Secure Storage**: Tokens stored in device secure storage (iOS Keychain, Android Keystore)

### State Management
- **AuthState**: Manages session status and authentication
- **OrderState**: Manages order list and operations
- **Optimistic Updates**: Local state updated immediately for better UX

### Real-time Updates
- **Firebase Cloud Messaging**: Push notifications for new orders
- **Device Registration**: Automatic subscription to driver-specific topics (`echango_driver_{driverId}`)

### Location Services
- **Background Tracking**: Continuous location updates with `geolocator`
- **Foreground Task**: `flutter_foreground_task` maintains tracking when app is backgrounded
- **Update Frequency**: 10 meters distance or 10 second interval (configurable)
- **API Sync**: Automatic updates to BFF location endpoint

## Configuration

### Before Running

1. **Firebase Setup** (`lib/config/firebase_options.dart`)
   - Add Firebase project configuration
   - iOS: Add `GoogleService-Info.plist`
   - Android: Add `google-services.json`

2. **API Endpoints** (`lib/config/api_config.dart`)
   - Set BFF base URL (default: `http://localhost:3001`, sans préfixe)
   - Sur appareil physique : IP de la machine hôte ; sur émulateur Android : `10.0.2.2`
   - Adjust location distance threshold (default: 10.0 meters)
   - Configure API timeout (default: 30 seconds)

3. **App Version** (pubspec.yaml)
   - Update version number for releases

## Testing

Run tests:
```bash
flutter test
```

## Dependencies

### Core
- **provider**: State management (ChangeNotifier)
- **go_router**: Type-safe navigation with redirect-based auth flow
- **http**: HTTP client for REST API calls
- **flutter_secure_storage**: Secure token storage

### Services & Integrations
- **firebase_core** & **firebase_messaging**: Push notifications via FCM
- **geolocator** & **flutter_foreground_task**: Background location tracking
- **permission_handler**: Runtime permissions for location and notifications

### Storage
- **shared_preferences**: Local key-value storage
- **sqflite**: Local SQLite database

### UI
- **google_maps_flutter**: Map integration
- **cupertino_icons**: iOS-style icons
- **equatable**: Value equality for models

See `pubspec.yaml` for complete dependency list.

## Notes

- The app requires location permissions to function
- Push notifications require Firebase Cloud Messaging setup
- Background location tracking requires appropriate OS permissions
- The BFF API must be accessible from the device

## License

Echango Delivery - Internal Use Only
