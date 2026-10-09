# OfflinePay Mobile App

Flutter mobile application for OfflinePay - An offline-first digital payment system.

**⚠️ IMPORTANT: This uses SIMULATED money only. Educational project.**

## Current Status

**Phase 1 Complete**: Basic wallet system with backend integration

## Prerequisites

### Required
- Flutter SDK 3.0+
- Dart 3.0+
- Android Studio or VS Code with Flutter extension

### Installation

1. Install Flutter: https://docs.flutter.dev/get-started/install

2. Verify installation:
```bash
flutter doctor
```

## Flutter Project Setup

Since Flutter is not yet installed on your system, here's how to set it up:

### Windows Installation

1. Download Flutter SDK from https://docs.flutter.dev/get-started/install/windows

2. Extract to `C:\src\flutter` (or your preferred location)

3. Add to PATH:
   - Search "Environment Variables"
   - Add `C:\src\flutter\bin` to PATH

4. Run:
```bash
flutter doctor
```

5. Install Android Studio or VS Code with Flutter plugin

## Project Structure (Planned)

```
mobile/
├── lib/
│   ├── models/          # Data models
│   ├── services/        # API, storage, crypto services
│   ├── providers/       # State management
│   ├── screens/         # UI screens
│   ├── widgets/         # Reusable components
│   ├── utils/           # Helper functions
│   └── main.dart        # Entry point
├── assets/              # Images, fonts
└── pubspec.yaml         # Dependencies
```

## Development Roadmap

### Phase 1: Basic Wallet ✅
- User profile display
- Wallet balance
- Transaction history
- Backend integration

### Phase 2: QR Payments (Next)
- QR code generation
- QR code scanning
- Payment confirmation
- Transaction PIN

### Phase 3: Offline Mode
- Local SQLite storage
- Offline transaction queue
- Sync mechanism

### Future Phases
- Cryptographic signing
- Double-spend prevention
- Bluetooth/NFC

## Note

The mobile app will be created once Flutter is installed. For now, you can test the backend APIs directly using the demo script or API testing tools like Postman/curl.

To proceed with mobile development:
1. Install Flutter SDK
2. Run `flutter create .` in the mobile/ directory
3. Add dependencies to pubspec.yaml
4. Implement UI and logic

## Backend Connection

The app will connect to:
```
http://localhost:5000/api
```

For testing on physical devices, update to your computer's local IP address.
