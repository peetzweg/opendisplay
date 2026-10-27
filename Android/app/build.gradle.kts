plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.opendisplay.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.peetzweg.opendisplay"
        // Google Play rejects bundles below API 24 (its automatic protection
        // requires it), so Play builds pass -PappMinSdk=24. The GitHub APK
        // keeps 21 for Android 5 and 6 devices.
        minSdk = (findProperty("appMinSdk") as String?)?.toInt() ?: 21
        targetSdk = 36
        // CI passes the shared repo version (release-please) as Gradle
        // properties; local builds fall back to these defaults.
        versionCode = (findProperty("appVersionCode") as String?)?.toInt() ?: 1
        versionName = findProperty("appVersionName") as String? ?: "0.1.0"
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            resValue("string", "app_name", "OpenDisplay Dev")
        }
        release {
            isMinifyEnabled = false
            resValue("string", "app_name", "OpenDisplay")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    // Off-the-shelf Android UI for the receiver's own screens (settings,
    // onboarding, log), the counterpart of SwiftUI's Form/sheet on iOS.
    // All three still support minSdk 21.
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.preference:preference:1.2.1")
    // android.jar only stubs org.json; JVM unit tests need the real thing.
    testImplementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
}
