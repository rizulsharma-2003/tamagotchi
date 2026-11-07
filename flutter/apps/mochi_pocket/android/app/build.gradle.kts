plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Push (FCM): android/app/google-services.json, downloaded from the Firebase console for com.insideedge.mochi, is kept
// out of git (.gitignore here). With it, the google-services plugin turns it into the app's Firebase configuration;
// without it the app still builds and runs, and Settings says push isn't set up in this build.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.warn("Mochi: no android/app/google-services.json, so this build has no push (FCM).")
}

android {
    namespace = "com.insideedge.mochi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time on older Android versions.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.insideedge.mochi"
        // Android 8.0: notification channels and Keystore-backed AES for the stored pairing.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // No release signing yet: Mochi for Android is installed directly (debug builds) until the Play Store.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// Mochi's ongoing notification while Claude works (plugins/mochi_live_update) shows the iPhone's own Live Activity art:
// the scene for each phase and its ten poses (iOS/Shared/Art.xcassets, scene-<phase>[-<frame>].imageset), copied at
// build time into drawables named mochi_scene_<phase>[_<frame>], so the pictures are never kept twice.
val liveActivityArt = rootProject.file("../../../../iOS/Shared/Art.xcassets")
val liveActivityRes = layout.buildDirectory.dir("generated/mochiLiveActivityArt/res")
val copyLiveActivityArt by tasks.registering(Sync::class) {
    from(liveActivityArt) {
        include("scene-*.imageset/scene-*.png")
        eachFile { path = "drawable-nodpi/mochi_" + name.removeSuffix(".png").replace('-', '_') + ".png" }
    }
    includeEmptyDirs = false
    into(liveActivityRes)
    doFirst {
        require(liveActivityArt.isDirectory) { "Mochi: the Live Activity art isn't at $liveActivityArt" }
    }
}
android.sourceSets.getByName("main").res.srcDir(liveActivityRes)
tasks.named("preBuild") { dependsOn(copyLiveActivityArt) }

flutter {
    source = "../.."
}
