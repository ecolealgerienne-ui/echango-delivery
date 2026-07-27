# Echango Delivery Driver App

Flutter mobile application for drivers using the Echango Delivery logistics platform.

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
- **Email/Password Flow**: BFF `/auth/login` → access token → stored securely
- **Phone OTP Flow**: BFF `/auth/login-phone` → OTP → `/auth/verify-otp` → access token
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
   - Set BFF base URL (default: `http://localhost:3000/api/v1`)
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
