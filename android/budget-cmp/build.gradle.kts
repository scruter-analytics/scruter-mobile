// Measures what Scruter CMP costs an app after R8 (docs/CMP-MOBILE.md §3.11: ≤ 350 KB): one small Views app built
// twice, with and without the module; the difference of the two APKs (dex, assets, resources, Kotlin standard library
// included) is the budget, and the dex method ids are reported beside it.
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.ZipFile

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "net.scruter.budget.cmp"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        applicationId = "net.scruter.budget.cmp"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }
    flavorDimensions += "cmp"
    productFlavors {
        create("withCmp") { dimension = "cmp" }
        create("withoutCmp") { dimension = "cmp" }
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
    lint {
        checkReleaseBuilds = false
    }
}

dependencies {
    "withCmpImplementation"(project(":scruter-cmp"))
}

abstract class CheckCmpBudget : DefaultTask() {
    @get:InputFile
    abstract val with: RegularFileProperty

    @get:InputFile
    abstract val without: RegularFileProperty

    @get:OutputFile
    abstract val report: RegularFileProperty

    private fun methods(apk: File): Long {
        var methods = 0L
        ZipFile(apk).use { zip ->
            for (e in zip.entries()) {
                if (!e.name.matches(Regex("classes\\d*\\.dex"))) continue
                val dex = zip.getInputStream(e).readBytes()
                methods += ByteBuffer.wrap(dex).order(ByteOrder.LITTLE_ENDIAN).getInt(88).toLong()
            }
        }
        return methods
    }

    /** The bytes an APK's entries take, uncompressed (what the app's install grows by, before the store's compression). */
    private fun bytes(apk: File): Long = ZipFile(apk).use { z -> z.entries().asSequence().filter { !it.name.startsWith("META-INF/") }.sumOf { it.size } }

    @TaskAction
    fun check() {
        val a = with.get().asFile
        val b = without.get().asFile
        val kb = (bytes(a) - bytes(b)) / 1024.0
        val download = (a.length() - b.length()) / 1024.0
        val methods = methods(a) - methods(b)
        val text = "Scruter CMP after R8: %.1f KB added to the APK (%.1f KB compressed), %d methods (budget: 350 KB)".format(kb, download, methods)
        println(text)
        report.get().asFile.writeText(text + "\n")
        if (kb > 350) throw GradleException("over budget: $text")
    }
}

tasks.register<CheckCmpBudget>("checkBudgets") {
    group = "verification"
    dependsOn("assembleWithCmpRelease", "assembleWithoutCmpRelease")
    with.set(layout.buildDirectory.file("outputs/apk/withCmp/release/budget-cmp-withCmp-release.apk"))
    without.set(layout.buildDirectory.file("outputs/apk/withoutCmp/release/budget-cmp-withoutCmp-release.apk"))
    report.set(layout.buildDirectory.file("reports/budget.txt"))
}
