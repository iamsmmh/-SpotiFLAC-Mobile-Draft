import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // Kotlin is compiled with the classic Kotlin Gradle plugin: Flutter < 3.47
    // cannot use AGP 9's built-in Kotlin, so gradle.properties opts out with
    // android.builtInKotlin=false and android.newDsl=false.
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load keystore properties for local builds
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.zarz.spotiflac"
    // compileSdk 37: the current dependency set (androidx.core 1.18,
    // activity 1.13, audioplayers_android, connectivity_plus, file_picker,
    // receive_sharing_intent) requires compiling against API 37+.
    // Do NOT lower this to 35 — that fails checkReleaseAarMetadata
    // ("requires compileSdk of at least 37"). targetSdk stays 35 to avoid
    // opting in to newer runtime behavior until the app is migrated.
    // CI may not be able to install the android-37 platform (it is not always
    // published to sdkmanager's stable channel). .github/scripts/setup-android-sdk.sh
    // exports ANDROID_COMPILE_SDK with whatever level actually got installed,
    // so honour that and only default to 37.
    compileSdk = (System.getenv("ANDROID_COMPILE_SDK") ?: "37").toInt()
    // Pin NDK r29 (16 KB page size, Android 15+). Flutter 3.44.8's
    // flutter.ndkVersion is 28.2.13676358, which CI does not install;
    // assembleRelease then dies in extractReleaseNativeDebugMetadata /
    // stripReleaseDebugSymbols after several minutes of compilation.
    ndkVersion = "29.0.14206865"

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    defaultConfig {
        applicationId = "com.zarz.spotiflac"
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            ndk {
                debugSymbolLevel = "FULL"
            }
        }

        getByName("profile") {
            ndk {
                debugSymbolLevel = "FULL"
            }
        }

        release {
            // For local builds: use release signing if key.properties exists
            // For CI builds: APK is signed by GitHub Action after build
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 fullMode stays off (android.enableR8.fullMode=false) so Flutter
            // channel reflection, gomobile, and both FFmpeg kits survive minify.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            ndk {
                debugSymbolLevel = "FULL"
            }
        }
    }
    
    // ABI filtering is handled entirely by Flutter:
    //   * --split-per-abi     : produces one APK per ABI
    //   * --target-platform   : restricts the ABIs (android-arm, android-arm64)
    // Do NOT add an ndk.abiFilters block here — it conflicts with the
    // splits that --split-per-abi enables and breaks the release build
    // ("conflicting configuration in ndk abiFilters cannot be present when
    //  splits abi filters are set").

    // FFmpeg Kit (full) + gomobile + audio plugins all ship libc++_shared.so.
    // Without pickFirst, mergeReleaseNativeLibs fails at the end of
    // assembleRelease with "2 files found with path 'lib/*/libc++_shared.so'".
    packaging {
        jniLibs {
            pickFirsts += listOf(
                "**/libc++_shared.so",
                "**/libfbjni.so",
            )
        }
        resources {
            pickFirsts += listOf(
                "META-INF/NOTICE.md",
                "META-INF/LICENSE.md",
                "META-INF/INDEX.LIST",
                "META-INF/DEPENDENCIES",
            )
        }
    }

    // Plugin lint findings must not fail assembleRelease. Flutter templates
    // historically disabled this; AGP still runs lintVitalRelease by default
    // for application modules and it is a common late-stage exit-code-1.
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

// Kotlin compiler options for the classic Kotlin Gradle plugin (KGP 2.x DSL).
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

repositories {
    flatDir {
        dirs("libs")
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    
    // Include all AAR and JAR files from libs folder
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.jar", "*.aar"))))
    
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.activity:activity-ktx:1.13.0")
    implementation("com.google.android.gms:play-services-auth-blockstore:16.4.0")

    // NativeDownloadFinalizer imports FFmpegKit APIs directly. The Flutter
    // plugin owns the runtime AAR; compileOnly avoids packaging it twice here.
    compileOnly("com.antonkarpenko:ffmpeg-kit-full:2.2.1")

    // EncryptedSharedPreferences 1.0.0 (MasterKeys.getOrCreate). Do not bump
    // to 1.1.0-alpha MasterKey — that API is still unstable.
    implementation("androidx.security:security-crypto:1.0.0")

    testImplementation("junit:junit:4.13.2")
}
