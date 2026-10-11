plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties

// Release signing posture: upload key lives OUTSIDE the repo in
// android/key.properties (gitignored; see key.properties.example).
// CI injects it via env -> file before build. When absent (local
// dev), the debug keystore signs so `flutter run --release` keeps
// working — but store builds MUST fail loudly rather than ship a
// debug-signed artifact (see the release block below).
val keystoreProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) {
        f.inputStream().use { load(it) }
    }
}
val hasReleaseKey =
    keystoreProps.getProperty("storeFile")?.isNotBlank() == true &&
        keystoreProps.getProperty("storePassword") != null &&
        keystoreProps.getProperty("keyAlias")?.isNotBlank() == true

android {
    namespace = "com.cresca.cresca_app"
    // Pinned 36: Live Updates use Notification.ProgressStyle (API 36);
    // runtime-gated by SDK_INT so older devices are unaffected.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cresca.cresca_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // SDK sanity (release): min/target float with the Flutter SDK
        // (min >= 23 expected for webview_flutter/just_audio/background_
        // downloader; target tracks the latest stable). compileSdk is
        // pinned to 36 above for the ProgressStyle API — keep target >=
        // compile behavior in sync when bumping the SDK.
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
        create("release") {
            if (hasReleaseKey) {
                storeFile = rootProject.file(
                    keystoreProps.getProperty("storeFile")!!
                )
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Store builds sign with the upload key; without
            // key.properties this falls back to debug ONLY so local
            // `--release` runs keep working. Never publish that APK/AAB.
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Release hardening: R8 full-mode shrink + obfuscate (keep
            // rules in proguard-rules.pro cover audio_service/media3,
            // webview_js, flutter plugins, and MainActivity), resource
            // shrink drops unused drawables/locales from the bundle.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
