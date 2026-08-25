# PDF Viewer & Editor

A robust, feature-rich Android application built with Flutter that allows users to view and edit PDF documents seamlessly.

## Features

- **File Picker Integration:** Easily browse and select PDF files from the device.
- **Fast PDF Rendering:** Smooth viewing experience using Syncfusion PDF Viewer.
- **Editing Capabilities:** Modify PDFs by adding text annotations, highlights, and freehand drawing dynamically.
- **Undo/Redo History:** Easily revert or re-apply your changes with full history tracking.
- **Save & Overwrite:** Save your edits directly over the original file seamlessly.
- **Search:** Search text within the PDF document with navigation controls.
- **Navigation:** Custom page indicator that displays the current and total page numbers alongside the native scroll head.
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

### Release Signing

The keystore is **not** in the repository — `.gitignore` excludes `*.jks`, and it never has been committed. A fresh clone therefore cannot produce a distributable APK until you supply the signing material yourself.

To build a signed release locally:

1. Put `upload-keystore.jks` in the repository root (copy it from a machine that already has it, or from your password manager).
2. Create `android/key.properties` (git-ignored):

   ```properties
   storePassword=<your store password>
   keyAlias=upload
   keyPassword=<your key password>
   ```

3. Build:

   ```bash
   flutter build apk --release
   ```

If either the keystore or the credentials are missing, the release build still succeeds but is signed with the **debug** key and Gradle prints a warning. Such an APK cannot be installed as an update over a properly signed one, and cannot be distributed. Check the build log if a release APK behaves unexpectedly.

CI does not use `key.properties`; it decodes the keystore from the `KEYSTORE_BASE64` secret and passes `KEYSTORE_PASSWORD`, `KEY_ALIAS`, and `KEY_PASSWORD` as environment variables, which take precedence.

### Saving on Android

Documents are opened through the Storage Access Framework (`ACTION_OPEN_DOCUMENT`), and the app takes a **persistable** read/write grant on the chosen `content://` URI. Save writes back to that URI, so edits land in the user's actual document, and the grant survives reboots so Recent Files keeps working across sessions.

A cache copy is still made for rendering, because the Syncfusion viewer needs a `File` — but it is only a working copy, never the save target.

If a provider grants read but not write, the document is marked read-only, Recent Files says so, and Save redirects to **Save a copy** (`ACTION_CREATE_DOCUMENT`) rather than silently writing somewhere the user will never look.

Writes are made crash-safe: the previous contents are copied aside before the target is truncated, and restored if the write fails part way through.

## CI/CD Pipeline

This project includes a `.github/workflows/release.yml` file.

Every time you **push to the `main` branch**:

1. The GitHub Action automatically bumps the app version in `pubspec.yaml`.
2. Commits the version bump back to the repository.
3. Builds a signed Release APK using the included keystore.
4. Generates a new GitHub Release with the APK attached.

## License

This project relies on [Syncfusion Flutter PDFViewer](https://pub.dev/packages/syncfusion_flutter_pdfviewer) and [Syncfusion Flutter PDF](https://pub.dev/packages/syncfusion_flutter_pdf), which are governed by the Syncfusion Community License. Ensure you comply with their terms if using this commercially.
