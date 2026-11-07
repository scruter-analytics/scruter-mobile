// The Scruter Android SDK (docs/MOBILE.md §3): the library, the sample app, the budget app that measures the
// library after R8, and the Gradle plugin `net.scruter.symbols` (an included build, so the sample applies it from
// source exactly as an app applies it from the Gradle Plugin Portal).
pluginManagement {
    includeBuild("scruter-symbols-gradle-plugin")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "scruter-android-sdk"
include(":scruter-android", ":sample", ":budget")
