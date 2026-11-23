// The example app of Scruter CMP (docs/CMP-MOBILE.md §2.5, §3.6): a Views screen and a Compose screen, the start line,
// the settings entry, and the gating of an analytics SDK and an ad SDK (stand-ins: the real SDKs are not linked).
// Its instrumented tests run the release-like flow on an emulator against a local stub of the ingest, with Espresso's
// accessibility checks.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "net.scruter.cmp.sample"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        applicationId = "net.scruter.cmp.sample"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
        // Where the CMP fetches its configuration: Scruter's CDN, or the local stub of the instrumented tests.
        val endpoint = providers.gradleProperty("scruter.cmpEndpoint").orNull ?: "https://cdn.scruter.net"
        buildConfigField("String", "CMP_ENDPOINT", "\"$endpoint\"")
        testInstrumentationRunner = "net.scruter.cmp.sample.StubRunner"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    sourceSets["androidTest"].assets.srcDir(rootProject.file("../protocol/cmp/bodies"))
    // The IAB TCF's vendor subset and IAB's translations (protocol/cmp/tcf), for the run in mode `tcf`.
    sourceSets["androidTest"].assets.srcDir(rootProject.file("../protocol/cmp/tcf"))
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }
    testOptions {
        animationsDisabled = true
    }
    lint {
        checkReleaseBuilds = false
    }
}

dependencies {
    implementation(project(":scruter-cmp"))
    implementation(project(":scruter-cmp-compose"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.coroutines.android)

    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.espresso.core)
    androidTestImplementation(libs.espresso.accessibility)
    androidTestImplementation(libs.uiautomator)
    androidTestImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
}
