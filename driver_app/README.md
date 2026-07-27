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
   - Update `lib/config/app_config.dart` with your BFF base URL

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
├── config/                   # Configuration files
│   ├── app_config.dart
│   └── firebase_options.dart
├── models/                   # Data models
│   └── order.dart
├── services/                 # Business logic
│   ├── bff_client.dart
│   ├── auth_service.dart
│   ├── notification_service.dart
│   └── location_service.dart
├── providers/                # State management (Provider)
│   ├── auth_provider.dart
│   └── order_provider.dart
└── screens/                  # UI screens
    ├── splash_screen.dart
    ├── login_screen.dart
    ├── otp_screen.dart
    ├── dashboard_screen.dart
    ├── orders_list_screen.dart
    ├── order_detail_screen.dart
    ├── delivery_failure_screen.dart
    ├── map_screen.dart
    └── profile_screen.dart
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

### Authentication Flow
- Email/Password → BFF `/auth/login` → access token
- Phone OTP → BFF `/auth/login-phone` → OTP code → `/auth/verify-otp` → access token

### Real-time Updates
- Firebase Cloud Messaging for push notifications
- WebSocket support for future real-time features
- Device registration with driver ID topics

### Location Services
- Geolocator package for background location tracking
- flutter_foreground_task for persistent tracking
- Automatic location updates to BFF every 10 meters or 10 seconds

## Configuration

Update these files before deployment:

1. **Firebase Setup** (`lib/config/firebase_options.dart`)
2. **API Endpoints** (`lib/config/app_config.dart`)
3. **App Info** (pubspec.yaml)

## Testing

Run tests:
```bash
flutter test
```

## Dependencies

- Provider: State management
- Dio: HTTP client
- Firebase Core & Messaging: Push notifications
- Geolocator: Location services
- Google Maps Flutter: Map integration
- Shared Preferences: Local storage
- SQLite: Local database

See `pubspec.yaml` for complete dependency list.

## Notes

- The app requires location permissions to function
- Push notifications require Firebase Cloud Messaging setup
- Background location tracking requires appropriate OS permissions
- The BFF API must be accessible from the device

## License

Echango Delivery - Internal Use Only
