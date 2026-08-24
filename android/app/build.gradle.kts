import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing credentials.
//
// These must never be hardcoded here: this file is committed, so a literal
// password is a published password and anyone could then ship an APK signed as
// this app. Credentials come from the environment (used by CI) or from
// android/key.properties, which is git-ignored.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

// An unconfigured GitHub Actions secret expands to an empty string, not to an
// unset variable, so blank must be treated as absent or a release would be
// signed with an empty password and the CI guard below would never fire.
fun signingSecret(envName: String, propertyName: String): String? =
    System.getenv(envName)?.takeIf { it.isNotBlank() }
        ?: keystoreProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() }

val releaseKeystore = rootProject.file("../upload-keystore.jks")
val releaseStorePassword = signingSecret("KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingSecret("KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingSecret("KEY_PASSWORD", "keyPassword")

// `base64 --decode` on an empty secret leaves a zero-byte file behind, which
// exists() happily accepts.
val canSignRelease = releaseKeystore.isFile &&
    releaseKeystore.length() > 0L &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null

// On CI a debug-signed "release" would be published as a GitHub Release and
// break updates for everyone with a signature mismatch, so a missing or
// renamed secret has to fail the build loudly rather than degrade quietly.
// Locally the debug fallback is a convenience and stays allowed.
val isCi = System.getenv("CI") != null

// Checked against the task graph rather than thrown while configuring the
// release build type: configuration runs for every Gradle invocation, so
// throwing there would break debug builds and `gradlew tasks` on CI too.
if (isCi && !canSignRelease) {
    gradle.taskGraph.whenReady {
        val buildingRelease = allTasks.any { it.name.endsWith("Release") }
        if (buildingRelease) {
            throw GradleException(
                "Release signing credentials are missing on CI. " +
                    "usable keystore: ${releaseKeystore.isFile && releaseKeystore.length() > 0L}, " +
                    "KEYSTORE_PASSWORD set: ${releaseStorePassword != null}, " +
                    "KEY_ALIAS set: ${releaseKeyAlias != null}, " +
                    "KEY_PASSWORD set: ${releaseKeyPassword != null}. " +
                    "Refusing to publish a debug-signed release."
            )
        }
    }
}

android {
    namespace = "com.example.pdfviewer.pdf_viewer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.pdfviewer.pdf_viewer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (canSignRelease) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Falling back to the debug key keeps a fresh clone buildable.
            // CI supplies the real credentials via environment variables.
            signingConfig = if (canSignRelease) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "WARNING: no release signing credentials found; " +
                        "signing with the debug key. This APK is not " +
                        "distributable. Provide KEYSTORE_PASSWORD / KEY_ALIAS / " +
                        "KEY_PASSWORD, or create android/key.properties."
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
