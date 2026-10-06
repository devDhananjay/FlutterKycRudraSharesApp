# Meon-KYC (Flutter)

Flutter conversion of the React.js Meon KYC app. This app handles KYC workflow forms with dynamic fields, conditional logic, file uploads, and authenticated API calls.

## Package Name

- **App name:** Meon KYC
- **Package:** `meon_kyc` (Dart)
- **Android application ID:** `com.meon.kyc`

## Features

- Dynamic form fields (text, number, textarea, password, select, date, checkbox, radio, file, button)
- Conditional field visibility and editability
- File upload with validation (type, size)
- PDF password check for encrypted PDFs
- Token-based auth with refresh token support
- Workflow fetch with/without authentication

## Setup

1. **Prerequisites**
   - Flutter SDK 3.0+
   - Android Studio / Xcode for mobile builds

2. **Install dependencies**
   ```bash
   cd Meon-KYC
   flutter pub get
   ```

3. **Configure API URL**
   Edit `lib/config/env_config.dart` to set your API base URL.

4. **Run the app**
   ```bash
   flutter run
   ```

5. **iOS device (recommended)**
   - Use a **USB cable** when debugging on a physical iPhone. Wireless debugging on iOS 26 can cause "Connection refused" and the app may be killed (signal 9).
   - After changing plugins, run: `cd ios && pod install && cd ..`

## Troubleshooting

- **iOS: "Class FileUtils is implemented in both ... file_picker"**  
  The project uses `file_picker` 10.3.10+ to avoid the duplicate class conflict with iOS. Run `flutter pub get` and `cd ios && pod install`.

- **iOS: "Connection refused" / "Process exited with status 9"**  
  Prefer a **wired (USB)** connection for debugging. Ensure the device is in Developer Mode and trusted.

- **iOS: "Generated.xcconfig must exist"**  
  Run `flutter pub get` first, then `pod install` inside `ios/`.

## Project Structure

```
lib/
├── main.dart              # App entry
├── app.dart               # Routing (go_router)
├── api/                   # API layer
│   ├── api_client.dart
│   ├── base_api.dart
│   ├── interceptor.dart   # Token refresh
│   └── kyc_api.dart
├── components/
│   ├── form_field_widget.dart
│   ├── loader.dart
│   └── popup_modal.dart
├── config/
│   └── env_config.dart
├── hooks/
│   └── conditional_form.dart  # Form state & validation
├── pages/
│   ├── home_page.dart
│   └── page_not_found.dart
├── services/
│   └── storage_service.dart   # Secure token storage
├── store/
│   └── app_store.dart        # Provider-based state
└── utils/
    ├── conditional_flow.dart  # Conditional logic
    └── field_validators.dart
```

## Routing

- `/:company/:workflowName` – KYC form page
- `/404` – Page not found

Example: `https://yourapp.com/meon/demat` opens the KYC form for company `meon` and workflow `demat`.

## Dependencies

- `provider` – State management
- `go_router` – Navigation
- `http` – API calls
- `flutter_secure_storage` – Token storage
- `file_picker` – File selection
- `fluttertoast` – Toast messages
