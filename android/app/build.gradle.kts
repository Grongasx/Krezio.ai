import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: the keystore lives OUTSIDE the repository. Its path and
// passwords come from environment variables (CI) or from android/key.properties
// (local, git-ignored). See RELEASING.md.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) load(FileInputStream(f))
}
fun signingValue(env: String, prop: String): String? = System.getenv(env) ?: keyProps.getProperty(prop)
val releaseStoreFile = signingValue("KREZIO_KEYSTORE_PATH", "storeFile")
val hasReleaseKey = releaseStoreFile != null && file(releaseStoreFile).exists()

android {
    namespace = "com.krezio.ai"
    compileSdk = flutter.compileSdkVersion
    // speech_to_text requires NDK 28; NDKs are backward compatible.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.krezio.ai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = signingValue("KREZIO_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = signingValue("KREZIO_KEY_ALIAS", "keyAlias")
                keyPassword = signingValue("KREZIO_KEY_PASSWORD", "keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Without the release key (a dev machine), the debug key keeps
            // `flutter run --release` working; such a build can't go to the store.
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

flutter {
    source = "../.."
}
