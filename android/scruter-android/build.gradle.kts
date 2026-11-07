// net.scruter:scruter-android — the Scruter Analytics SDK for Android (docs/MOBILE.md §3).
//
// Runtime dependencies: the platform and the Play Install Referrer client (Apache-2.0, ≈ 10 KB, the only way Google
// documents to read the referrer). AndroidX Compose, Navigation, Fragment, RecyclerView and Material are compileOnly:
// the SDK supports them when the app has them and never adds them to an app (each use is guarded by a class check).
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    `maven-publish`
    signing
}

val sdkVersion = "1.0.2"

android {
    namespace = "net.scruter"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        // The team-link scheme is the app's (`scruter-<app id>`, set by the Gradle plugin): kept as a placeholder in the
        // AAR, and harmless in the library's own test manifest.
        manifestPlaceholders["scruterAppId"] = "\${scruterAppId}"
        buildConfigField("String", "SDK_VERSION", "\"$sdkVersion\"")
    }
    buildFeatures {
        buildConfig = true
        compose = true
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
            isReturnDefaultValues = false
            all {
                it.maxHeapSize = "1g"
                it.testLogging.exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
                it.systemProperty("robolectric.logging.enabled", "false")
                it.systemProperty("scruter.protocolDir", rootProject.file("../protocol").absolutePath)
                it.systemProperty("scruter.conformanceOut", layout.buildDirectory.dir("conformance").get().asFile.absolutePath)
            }
        }
    }
    lint {
        abortOnError = true
        warningsAsErrors = false
        checkReleaseBuilds = false
    }
    publishing {
        singleVariant("release") {
            withSourcesJar()
            withJavadocJar()
        }
    }
}

// The app's Kotlin compiler reads the standard library this one brings: 1.8 keeps Flutter's and React Native's older
// Kotlin versions building (docs/MOBILE.md §17, §20); apps with a newer one get theirs.
kotlin {
    explicitApi()
    coreLibrariesVersion = "1.8.22"
    compilerOptions {
        apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_1_8)
    }
}

dependencies {
    implementation(libs.installreferrer)

    compileOnly(platform(libs.compose.bom))
    compileOnly(libs.compose.ui)
    compileOnly(libs.compose.runtime)
    compileOnly(libs.navigation.runtime)
    compileOnly(libs.fragment)
    compileOnly(libs.recyclerview)
    compileOnly(libs.material)

    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.junit)
    testImplementation(libs.compose.ui)
    testImplementation(libs.compose.foundation)
    testImplementation(libs.compose.material3)
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.compose.ui.test.manifest)
    testImplementation(libs.activity.compose)
    testImplementation(libs.navigation.compose)
    testImplementation(libs.fragment)
    testImplementation(libs.recyclerview)
    testImplementation(libs.material)
    testImplementation(libs.appcompat)
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "net.scruter"
            artifactId = "scruter-android"
            version = sdkVersion
            afterEvaluate { from(components["release"]) }
            pom {
                name = "Scruter Analytics for Android"
                description = "Privacy-first analytics for Android apps: no advertising id, no identifier beyond the day."
                url = "https://github.com/scruter-analytics/scruter-mobile"
                licenses {
                    license {
                        name = "MIT"
                        url = "https://opensource.org/license/mit"
                    }
                }
                developers {
                    developer {
                        name = "Scruter"
                        organization = "Scruter"
                        organizationUrl = "https://scruter.net"
                    }
                }
                scm {
                    url = "https://github.com/scruter-analytics/scruter-mobile"
                    connection = "scm:git:https://github.com/scruter-analytics/scruter-mobile.git"
                }
            }
        }
    }
    repositories {
        // The Central Portal's bundle is made from this directory (../scripts/release.py), shared with the plugin.
        maven {
            name = "staging"
            url = rootProject.layout.buildDirectory.dir("staging").get().asFile.toURI()
        }
    }
}

// In-memory PGP key from the release environment: never on a developer's machine, never in the repository.
signing {
    val key = providers.environmentVariable("SIGNING_KEY").orNull
    if (key != null) {
        useInMemoryPgpKeys(key, providers.environmentVariable("SIGNING_PASSWORD").orNull)
        sign(publishing.publications)
    }
}
