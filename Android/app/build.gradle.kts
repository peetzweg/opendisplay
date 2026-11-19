plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// AirPlay audio receiver sources and native engine now live directly in this
// module. Only real device ABIs are built; x86_64 emulator builds are not
// needed and the extra OpenSSL/FFmpeg cross-build costs significant space.
// A device-only build can pass -PappAbis=arm64-v8a to avoid the second ABI.
val allAbis = (findProperty("appAbis") as String?)
    ?.split(",")
    ?.map { it.trim() }
    ?.filter { it.isNotEmpty() }
    ?: listOf("arm64-v8a", "armeabi-v7a")
// Escape hatch for JVM/Kotlin-only verification when the NDK is unavailable.
// Normal builds always compile the native AirPlay engine.
val skipAirplayNative = (findProperty("skipAirplayNative") as String?)?.toBoolean() ?: false

android {
    namespace = "app.opendisplay.android"
    compileSdk = 36
    if (!skipAirplayNative) {
        ndkVersion = "27.0.12077973"
    }

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

        if (!skipAirplayNative) {
            externalNativeBuild {
                cmake {
                    arguments += "-DANDROID_STL=c++_shared"
                    arguments += "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON"
                }
            }
            ndk {
                abiFilters += allAbis
            }
        }
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

    if (!skipAirplayNative) {
        externalNativeBuild {
            cmake {
                path = file("src/main/cpp/CMakeLists.txt")
            }
        }
        buildFeatures {
            prefab = true
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

// Third-party native sources are licensed separately and are not committed.
// Download the pinned upstream commits before CMake needs them. Existing
// working trees that already contain the sources are detected and preserved.
val prepareAirplayThirdParty = tasks.register("prepareAirplayThirdParty") {
    onlyIf { !skipAirplayNative }
    val bootstrapScript = rootProject.file("tools/bootstrap-airplay-third-party.py")
    val bootstrapMarker = file("src/main/cpp/third_party/.airplay-bootstrap")
    inputs.file(bootstrapScript)
    inputs.dir(file("src/main/cpp/patches/UxPlay"))
    outputs.file(bootstrapMarker)

    doLast {
        fun canRun(command: String): Boolean = try {
            ProcessBuilder(command, "--version")
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()
                .waitFor() == 0
        } catch (_: Exception) {
            false
        }

        val python = listOf("python3", "python").firstOrNull(::canRun)
            ?: error("Python 3 is required to bootstrap the AirPlay third-party sources")

        val arguments = mutableListOf(python, bootstrapScript.absolutePath)
        (findProperty("airplayBootstrapProxy") as String?)
            ?.takeIf { it.isNotBlank() }
            ?.let { arguments += listOf("--proxy", it) }
        if ((findProperty("forceAirplayBootstrap") as String?)?.toBoolean() == true) {
            arguments += "--force"
        }

        val exitCode = ProcessBuilder(*arguments.toTypedArray())
            .directory(rootProject.projectDir)
            .inheritIO()
            .start()
            .waitFor()
        check(exitCode == 0) { "AirPlay third-party bootstrap failed with exit code $exitCode" }
    }
}

// The old in-tree UxPlay checkout can still carry Git metadata. Reapply our
// patches only in that legacy case; fresh bootstrap trees are already patched.
tasks.register("applyUxplayPatches") {
    dependsOn(prepareAirplayThirdParty)
    doLast {
        val uxplayDir = file("src/main/cpp/third_party/UxPlay")
        if (!uxplayDir.resolve(".git").exists()) {
            logger.lifecycle("UxPlay is already patched by the bootstrap task")
            return@doLast
        }
        fun git(vararg args: String): String {
            val proc = ProcessBuilder("git", "-C", uxplayDir.path, *args)
                .redirectErrorStream(true)
                .start()
            val out = proc.inputStream.bufferedReader().readText()
            check(proc.waitFor() == 0) { "git ${args.joinToString(" ")} failed:\n$out" }
            return out
        }
        val patches = file("src/main/cpp/patches/UxPlay")
            .listFiles { f -> f.extension == "patch" }!!
            .sorted()
        val touched = patches
            .flatMap { git("apply", "--numstat", it.path).trim().lines() }
            .map { it.substringAfterLast("\t") }
            .distinct()
        if (touched.isNotEmpty()) git("checkout", "--", *touched.toTypedArray())
        patches.forEach { git("apply", "--unidiff-zero", it.path) }
    }
}

tasks.configureEach {
    if (name.startsWith("configureCMake")) dependsOn("applyUxplayPatches")
}

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
    if (!skipAirplayNative) {
        implementation("com.google.oboe:oboe:1.9.3")
    }
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
