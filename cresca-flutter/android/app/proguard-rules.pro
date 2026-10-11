# Cresca release shrink/keep rules (R8 full mode).
# Keep posture: obfuscate app code aggressively; keep only what crosses
# a boundary reflection/JNI cannot see through (Flutter embedding,
# platform channels, media/notification APIs, WebView JS bridge).

# Flutter embedding + plugin registrant (referenced by name at runtime).
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.cresca.cresca_app.MainActivity { *; }

# audio_service foreground service + media-button receiver are
# referenced from AndroidManifest.xml; media3/ExoPlayer (just_audio)
# loads renderers via reflection.
-keep class com.ryanheise.** { *; }
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# WebView JS bridge (login/session flows): JavascriptInterface
# methods must survive shrinking.
-keepattributes JavascriptInterface
-keepattributes Signature, InnerClasses, EnclosingMethod
-keep class io.flutter.plugins.webviewflutter.** { *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# background_downloader workmanager/deserialization + share/open_file
# intents cross process boundaries; keep their entry points.
-keep class com.bbflight.background_downloader.** { *; }
-dontwarn com.bbflight.background_downloader.**
