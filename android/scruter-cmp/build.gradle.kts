// net.scruter:scruter-cmp — Scruter CMP for Android apps (docs/CMP-MOBILE.md): the consent sheet, the stored choice,
// its proofs, Consent Mode and the detected SDKs.
//
// No runtime dependency but the platform and the Kotlin standard library every Kotlin app already has (§3.11): the
// sheet is drawn with the platform's views, so that Jetpack Compose and Views apps take it alike. What only Compose or
// coroutines can offer lives in the companion `net.scruter:scruter-cmp-compose`.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    `maven-publish`
    signing
}

val sdkVersion = "1.2.0"

android {
    namespace = "net.scruter.cmp"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro", "catalogue-rules.pro")
        buildConfigField("String", "SDK_VERSION", "\"$sdkVersion\"")
    }
    buildFeatures {
        buildConfig = true
    }
    // The sheet's own words (« Étape {n} sur {t} », « Certifié par »…) in the 33 languages of a banner, from the
    // protocol kit, embedded as they are (sdk/protocol/cmp/words).
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/cmpWords"))
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
                it.systemProperty("scruter.catalogue", rootProject.file("../protocol/cmp/sdk-catalogue.json").absolutePath)
                it.systemProperty("scruter.conformanceOut", layout.buildDirectory.dir("conformance").get().asFile.absolutePath)
                it.systemProperty("scruter.shotsOut", layout.buildDirectory.dir("screenshots").get().asFile.absolutePath)
                it.systemProperty("scruter.shotsGolden", file("src/test/screenshots").absolutePath)
                it.systemProperty("scruter.recordShots", providers.gradleProperty("scruter.recordShots").orNull ?: "false")
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

val copyWords = tasks.register<Copy>("copyCmpWords") {
    from(rootProject.file("../protocol/cmp/words")) { include("*.json") }
    into(layout.buildDirectory.dir("generated/cmpWords/net.scruter.cmp/words"))
}
tasks.named("preBuild") { dependsOn(copyWords) }

// The same standard library floor as the Analytics module (Flutter's and React Native's older Kotlin keep building).
kotlin {
    explicitApi()
    coreLibrariesVersion = "1.8.22"
    compilerOptions {
        apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_1_8)
    }
}

dependencies {
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.junit)
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "net.scruter"
            artifactId = "scruter-cmp"
            version = sdkVersion
            afterEvaluate { from(components["release"]) }
            pom {
                name = "Scruter CMP for Android"
                description = "The consent sheet of Scruter CMP for Android apps: native views, proofs, Google Consent Mode, no device identifier."
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
