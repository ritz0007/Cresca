plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.cresca.app"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.cresca.app"
        minSdk = 26
        targetSdk = 34
        versionCode = 12
        versionName = "0.9.3"
    }
    // Per-device APKs (arm64 for modern phones, armv7 for old 32-bit,
    // x86_64 for emulators/Chromebooks) + one universal fallback.
    splits {
        abi {
            isEnable = true
            reset()
            include("armeabi-v7a", "arm64-v8a", "x86_64")
            isUniversalApk = true
        }
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation(platform("androidx.compose:compose-bom:2024.06.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    // Media3 for audio playback (YT Music needs this, not VideoView):
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-session:1.4.1")
    implementation("androidx.media3:media3-ui:1.4.1")
    // Real YouTube data: search + audio stream URLs (same engine NewPipe uses)
    implementation("com.github.teamnewpipe:NewPipeExtractor:v0.26.5")
    // Thumbnails:
    implementation("io.coil-kt:coil-compose:2.6.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.retrofit2:retrofit:2.11.0")
    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    // Boot splash screen:
    implementation("androidx.core:core-splashscreen:1.0.1")
    // Apple liquid-glass blur:
    implementation("dev.chrisbanes.haze:haze:1.7.2")
    implementation("dev.chrisbanes.haze:haze-materials:1.7.2")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    // Real org.json for JVM unit tests (Android stub throws "not mocked").
    testImplementation("org.json:json:20240303")
}

// Pin activity to SDK-35-compatible line (a transitive wants SDK 36)
configurations.all {
    resolutionStrategy.eachDependency {
        if (requested.group == "androidx.activity") useVersion("1.9.3")
    }
}
