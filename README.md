# PDF Viewer & Editor

A robust, feature-rich Android application built with Flutter that allows users to view and edit PDF documents seamlessly.

## Features

- **File Picker Integration:** Easily browse and select PDF files from the device.
- **Fast PDF Rendering:** Smooth viewing experience using Syncfusion PDF Viewer.
- **Editing Capabilities:** Modify PDFs by adding text annotations and highlights dynamically.
- **Export & Share:** Instantly share the edited document via native sharing options.
- **Automated CI/CD:** Fully integrated GitHub Actions workflow for automatic version bumping and APK releases.

## Getting Started (For Contributors)

If you'd like to contribute, run the app locally, or add new features, follow these steps:

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Version 3.13.0 or higher)
- Android Studio or any compatible IDE (VS Code, IntelliJ)
- Java Development Kit (JDK 17 recommended)

### Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/pdf_viewer.git
   cd pdf_viewer
   ```
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Run the app on a connected device or emulator:
   ```bash
   flutter run
   ```

## Architecture & Codebase

- `lib/main.dart` - Application entry point and theme configurations.
- `lib/screens/home_screen.dart` - The initial screen for picking PDF files.
- `lib/screens/pdf_editor_screen.dart` - Core screen rendering the PDF and providing editing tools.
- `lib/services/pdf_service.dart` - Utility methods for applying edits and saving new PDF copies.

### Using the Keystore on Another Machine

If you clone this repository on another machine, the keystore will automatically be available in the main folder. You can instantly build a signed release APK because the `android/app/build.gradle.kts` is already configured to point to it:

```bash
flutter build apk --release
```

## CI/CD Pipeline

This project includes a `.github/workflows/release.yml` file.

Every time you **push to the `main` branch**:

1. The GitHub Action automatically bumps the app version in `pubspec.yaml`.
2. Commits the version bump back to the repository.
3. Builds a signed Release APK using the included keystore.
4. Generates a new GitHub Release with the APK attached.

## License

This project relies on [Syncfusion Flutter PDFViewer](https://pub.dev/packages/syncfusion_flutter_pdfviewer) and [Syncfusion Flutter PDF](https://pub.dev/packages/syncfusion_flutter_pdf), which are governed by the Syncfusion Community License. Ensure you comply with their terms if using this commercially.
