// The Plugin Portal serves the plugins; their own dependencies (maven-model…) come from Maven Central.
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "scruter-symbols-gradle-plugin"
