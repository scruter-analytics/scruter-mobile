// net.scruter.symbols — the Gradle plugin of the Scruter Android SDK (docs/MOBILE.md §3.12, §4.3): sets the manifest
// placeholder `scruterAppId`, writes R8's mapping id into the app, and uploads R8 / ProGuard mappings and NDK symbols.
// Written in Java so that it runs on any Gradle 8 without depending on the Kotlin standard library Gradle embeds.
plugins {
    `java-gradle-plugin`
    `maven-publish`
    signing
    id("com.gradle.plugin-publish") version "1.3.1"
}

group = "net.scruter"
version = "1.0.0"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

val testAgp: Configuration by configurations.creating

dependencies {
    compileOnly("com.android.tools.build:gradle-api:8.7.3")
    testImplementation("junit:junit:4.13.2")
    testImplementation(gradleTestKit())
    testAgp("com.android.tools.build:gradle:8.7.3")
}

gradlePlugin {
    website = "https://scruter.net"
    vcsUrl = "https://github.com/scruter-analytics/scruter-mobile"
    plugins {
        create("scruterSymbols") {
            id = "net.scruter.symbols"
            implementationClass = "net.scruter.symbols.ScruterSymbolsPlugin"
            displayName = "Scruter Analytics symbols"
            description = "Uploads R8 / ProGuard mappings and NDK symbols to Scruter Analytics and wires the SDK's app id."
            tags = listOf("android", "analytics", "proguard", "r8", "symbols")
        }
    }
}

// Maven Central takes the plugin and its marker from the directory that holds the SDK (../scripts/release.py); the
// Gradle Plugin Portal takes them from `publishPlugins`, with GRADLE_PUBLISH_KEY and GRADLE_PUBLISH_SECRET.
publishing {
    publications.withType<MavenPublication>().configureEach {
        pom {
            name = "Scruter Analytics symbols Gradle plugin"
            description = "Uploads R8 / ProGuard mappings and NDK symbols to Scruter Analytics and wires the SDK's app id."
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
    repositories {
        maven {
            name = "staging"
            url = layout.projectDirectory.dir("../build/staging").asFile.toURI()
        }
    }
}

// In-memory PGP key from the release environment, as for the library.
signing {
    val key = providers.environmentVariable("SIGNING_KEY").orNull
    if (key != null) {
        useInMemoryPgpKeys(key, providers.environmentVariable("SIGNING_PASSWORD").orNull)
        sign(publishing.publications)
    }
}

// The TestKit builds apply this plugin next to the Android Gradle plugin: both must come from one class loader.
tasks.pluginUnderTestMetadata {
    pluginClasspath.from(testAgp)
}

tasks.test {
    maxHeapSize = "512m"
}

// Maven Central needs the jar, not a doc comment on every getter of the plugin's tasks.
tasks.javadoc {
    (options as StandardJavadocDocletOptions).addBooleanOption("Xdoclint:none", true)
}
