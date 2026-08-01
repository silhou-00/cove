# Flutter's own generated plugin registrant and embedding classes are
# invoked via reflection/JNI from native code.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# workmanager's background isolate entry point (calendarExportCallbackDispatcher,
# see lib/features/calendar/offline_export_queue.dart) is looked up by a
# stored callback handle at a later process start — the class it lives in
# must not be stripped or renamed.
-keep class dev.fluttercommunity.workmanager.** { *; }

# googleapis' generated Calendar/Drive model classes are (de)serialized via
# reflection (json_annotation-style field access) — keep fields so R8
# doesn't rename what the JSON mapping depends on.
-keepclassmembers class com.google.api.** { *; }
-keep class com.google.api.client.** { *; }
-dontwarn com.google.api.client.**

# google_sign_in / Play Services auth.
-keep class com.google.android.gms.auth.** { *; }
-dontwarn com.google.android.gms.**

# local_auth's biometric prompt bridge.
-keep class androidx.biometric.** { *; }

# Flutter's engine references Play Core "deferred components" split-install
# classes (FlutterPlayStoreSplitApplication etc.) unconditionally, even
# though this app has no dynamic feature modules and never pulls in the
# com.google.android.play:core dependency that would provide them. R8
# fails on the missing classes unless told they're not actually needed.
-dontwarn com.google.android.play.core.**

# flutter_local_notifications persists its scheduled-notification cache via
# Gson `TypeToken<List<...>>` reflection. Without generic signatures kept,
# R8 strips the type info and every plugin call (schedule/cancel) throws
# "RuntimeException: Missing type parameter" at runtime — reminders never
# actually get registered with AlarmManager, silently, since the Dart side
# only sees a caught PlatformException.
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-dontwarn com.google.gson.**
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type
