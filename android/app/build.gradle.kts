plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.tallyisle.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.tallyisle.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            val targetPlatforms = (project.findProperty("target-platform") as? String)
                ?.split(",")
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                .orEmpty()
            val mappedAbis = targetPlatforms.mapNotNull { platform ->
                when (platform) {
                    "android-arm64" -> "arm64-v8a"
                    "android-x64" -> "x86_64"
                    "android-arm" -> "armeabi-v7a"
                    else -> null
                }
            }
            // FlutterPlugin.apply() pre-populates defaultConfig.ndk.abiFilters with
            // PLATFORM_ABI_LIST (armeabi-v7a, arm64-v8a, x86_64) before this block runs,
            // so clear it first before applying the target-platform ABI filter.
            abiFilters.clear()
            abiFilters += if (mappedAbis.isNotEmpty()) {
                mappedAbis
            } else {
                listOf("arm64-v8a", "x86_64")
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    signingConfigs.getByName("debug") {
        val androidUser = System.getenv("ANDROID_USER_HOME")
        if (!androidUser.isNullOrBlank()) {
            val keystoreFile = file("$androidUser/debug.keystore")
            if (keystoreFile.exists()) {
                storeFile = keystoreFile
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

dependencies {
    // Bundled offline Chinese OCR model (no Google Play Services required).
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

// Ensure `--release --no-pub` offline builds strip dev-only `integration_test` registration
// left in GeneratedPluginRegistrant.java by `flutter pub get --offline`.
tasks.configureEach {
    if (name == "compileReleaseJavaWithJavac" || name == "compileReleaseKotlin") {
        doFirst {
            val registrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
            if (registrant.exists()) {
                val original = registrant.readText()
                val cleaned = original.replace(
                    Regex(
                        """\s*try\s*\{\s*flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\s*\}\s*catch\s*\(Exception e\)\s*\{[^}]*\}""",
                    ),
                    "",
                )
                if (cleaned != original) {
                    registrant.writeText(cleaned)
                }
            }
        }
    }
}
