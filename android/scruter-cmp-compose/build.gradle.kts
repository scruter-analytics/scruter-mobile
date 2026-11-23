// net.scruter:scruter-cmp-compose — what only Jetpack Compose and coroutines offer, on top of net.scruter:scruter-cmp
// (docs/CMP-MOBILE.md §3.2, §3.4): `ScruterConsentHost { … }`, `rememberConsentChoice()`, and the choices as a `Flow`.
// The core module stays without any dependency; this one uses the Compose runtime and UI and kotlinx-coroutines that
// a Compose app already has (compileOnly: never a version pushed onto the app).
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    `maven-publish`
    signing
}

val sdkVersion = "1.2.0"

android {
    namespace = "net.scruter.cmp.compose"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        minSdk = 24
    }
    buildFeatures {
        compose = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }
    lint {
        abortOnError = true
        checkReleaseBuilds = false
    }
    publishing {
        singleVariant("release") {
            withSourcesJar()
            withJavadocJar()
        }
    }
}

kotlin {
    explicitApi()
    coreLibrariesVersion = "1.8.22"
    compilerOptions {
        apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_1_8)
    }
}

dependencies {
    api(project(":scruter-cmp"))
    compileOnly(platform(libs.compose.bom))
    compileOnly(libs.compose.runtime)
    compileOnly(libs.compose.ui)
    compileOnly(libs.coroutines.core)
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "net.scruter"
            artifactId = "scruter-cmp-compose"
            version = sdkVersion
            afterEvaluate { from(components["release"]) }
            pom {
                name = "Scruter CMP for Jetpack Compose"
                description = "ScruterConsentHost and the consent choices as a Flow, on top of net.scruter:scruter-cmp."
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
        maven {
            name = "staging"
            url = rootProject.layout.buildDirectory.dir("staging").get().asFile.toURI()
        }
    }
}

signing {
    val key = providers.environmentVariable("SIGNING_KEY").orNull
    if (key != null) {
        useInMemoryPgpKeys(key, providers.environmentVariable("SIGNING_PASSWORD").orNull)
        sign(publishing.publications)
    }
}
