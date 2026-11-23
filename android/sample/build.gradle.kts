// The sample app: Views and Compose screens, a form, a list, a masked view. Its Robolectric tests walk through it with
// the SDK against a local server; its R8 build proves the consumer rules and the Gradle plugin.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    id("net.scruter.symbols")
}

scruter {
    appId = "ATMONA02"
}

android {
    namespace = "net.scruter.sample"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        applicationId = "net.scruter.sample"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
        // scripts/device-check.mjs: the release build on a real Android, against a local server (never on by default).
        val check = providers.gradleProperty("scruter.selfCheck").orNull
        buildConfigField("boolean", "SELF_CHECK", (check != null).toString())
        buildConfigField("String", "ENDPOINT", "\"${check ?: "https://cdn.scruter.net"}\"")
        buildConfigField("String", "API_ENDPOINT", "\"${check ?: "https://api.scruter.net"}\"")
        manifestPlaceholders["cleartext"] = (check != null).toString()
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
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.maxHeapSize = "1g"
                it.testLogging.exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
                it.systemProperty("scruter.conformanceOut", layout.buildDirectory.dir("conformance").get().asFile.absolutePath)
            }
        }
    }
    lint {
        checkReleaseBuilds = false
    }
}

dependencies {
    implementation(project(":scruter-android"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.navigation.compose)
    implementation(libs.appcompat)
    implementation(libs.fragment.ktx)
    implementation(libs.recyclerview)
    implementation(libs.material)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.compose.ui.test.manifest)
}
