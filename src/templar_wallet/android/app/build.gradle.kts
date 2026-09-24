import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Release signing ─────────────────────────────────────────────────────────
// Android installs an update only when it is signed with the same key as the
// app already on the device, so every published APK must carry the one
// upload key, and never the debug key: a CI runner generates a fresh debug
// key per run, and an APK signed with one can never be updated by the next.
//
// The key comes from, in this order:
//   1. the environment: TEMPLAR_KEYSTORE_PATH, TEMPLAR_KEYSTORE_PASSWORD,
//      TEMPLAR_KEY_ALIAS, TEMPLAR_KEY_PASSWORD (CI decodes the keystore from
//      repository secrets into these);
//   2. android/key.properties, gitignored, in Flutter's format: storeFile,
//      storePassword, keyAlias, keyPassword. A relative storeFile resolves
//      against android/app/, so give an absolute path;
//   3. nowhere: release builds are signed with the debug key and say so, which
//      keeps `flutter build apk --release` working for every contributor.
// A source filled in only partly is an error, not a quiet fallback to debug.
// Creating the key, the CI secrets, rotation: docs/build/RELEASE.md.
class ReleaseKey(
    val storeFile: File,
    val storePassword: String,
    val keyAlias: String,
    val keyPassword: String,
)

val releaseKey: ReleaseKey? = run {
    val fromEnv = listOf(
        "TEMPLAR_KEYSTORE_PATH",
        "TEMPLAR_KEYSTORE_PASSWORD",
        "TEMPLAR_KEY_ALIAS",
        "TEMPLAR_KEY_PASSWORD",
    ).associateWith { providers.environmentVariable(it).orNull.orEmpty() }
    val keyProperties = rootProject.file("key.properties")
    val values: Map<String, String> = when {
        fromEnv.values.any { it.isNotEmpty() } -> fromEnv
        keyProperties.isFile -> Properties().run {
            keyProperties.inputStream().use { load(it) }
            listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
                .associateWith { getProperty(it).orEmpty() }
        }
        else -> return@run null
    }
    val missing = values.filterValues { it.isEmpty() }.keys
    if (missing.isNotEmpty()) {
        throw GradleException(
            "Release signing is half configured, ${missing.joinToString()} empty: " +
                "set all four or none (docs/build/RELEASE.md).",
        )
    }
    val (store, storePassword, keyAlias, keyPassword) = values.values.toList()
    val storeFile = file(store)
    if (!storeFile.isFile) {
        throw GradleException("Release signing: no keystore at $storeFile")
    }
    ReleaseKey(storeFile, storePassword, keyAlias, keyPassword)
}

if (releaseKey == null &&
    gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
) {
    // error, not warn: Flutter runs Gradle with -q, which drops warnings, and
    // Flutter's own Gradle plugin reports its warnings the same way.
    logger.error(
        """
        |WARNING: no release signing key configured, so this release build is signed
        |with the DEBUG key. Fine for a test install; never publish it: Android will
        |not update it with a properly signed APK, nor the other way round.
        |To sign: TEMPLAR_KEYSTORE_PATH, TEMPLAR_KEYSTORE_PASSWORD, TEMPLAR_KEY_ALIAS
        |and TEMPLAR_KEY_PASSWORD, or android/key.properties (docs/build/RELEASE.md).
        """.trimMargin(),
    )
}

android {
    namespace = "dev.templarwallet.templar_wallet"
    compileSdk = flutter.compileSdkVersion
    // The plugins (mobile_scanner, app_links, …) declare 28.2; r27+ also gives
    // the 16 KB page alignment Android 15+ devices require. Keep in sync with
    // scripts/build_android.sh.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Brand bundle id, same as macOS (CFBundleIdentifier).
        applicationId = "dev.templarwallet.templarWallet"
        // 24 is the floor imposed by app_links / file_selector / url_launcher.
        minSdk = 24
        // 34 until the shell has SafeArea/edge-to-edge handling (35+ forces
        // edge-to-edge and would draw under the system bars).
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ABIs are chosen by scripts/build_android.sh through
        // `--target-platform android-arm64,android-x64` (physical devices +
        // emulator; no 32-bit — sled 0.34 is fragile there). A fixed
        // ndk.abiFilters here would conflict with --split-per-abi.
    }

    signingConfigs {
        releaseKey?.let { key ->
            create("release") {
                storeFile = key.storeFile
                storePassword = key.storePassword
                keyAlias = key.keyAlias
                keyPassword = key.keyPassword
            }
        }
    }

    buildTypes {
        release {
            // See "Release signing" above.
            signingConfig = signingConfigs.getByName(if (releaseKey != null) "release" else "debug")
            // Appended to what Flutter already puts in front of R8
            // (proguard-android-optimize.txt + flutter_proguard_rules.pro);
            // the file says why ML Kit needs keep rules of its own.
            proguardFiles("proguard-rules.pro")
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
    // androidx.biometric shows its own fingerprint dialog on API 24-28, which
    // needs an AppCompat activity theme (values/styles.xml parents on it).
    implementation("androidx.appcompat:appcompat:1.7.0")
}
