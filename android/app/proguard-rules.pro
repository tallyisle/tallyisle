# Keep TallyIsle native Android bridges, BroadcastReceivers, AppWidgetProviders, and AccessibilityService
-keep class com.tallyisle.app.** { *; }
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**

# Bundled ML Kit offline Chinese OCR: never strip JNI-bound / reflective classes under R8.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.odml.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.odml.**
