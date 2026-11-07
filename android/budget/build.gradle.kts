// Measures what the SDK costs an app after R8 (docs/MOBILE.md §3.18): one small Views app built twice, with and without
// the SDK; the difference of their dex files (bytes and method ids) is the budget, Kotlin standard library included.
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.ZipFile

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "net.scruter.budget"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        applicationId = "net.scruter.budget"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        manifestPlaceholders["scruterAppId"] = "budget"
    }
    flavorDimensions += "sdk"
    productFlavors {
        create("withSdk") { dimension = "sdk" }
        create("withoutSdk") { dimension = "sdk" }
    }
    buildTypes {
        release {
            isMinifyEnabled = true
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
    "withSdkImplementation"(project(":scruter-android"))
}

abstract class CheckBudgets : DefaultTask() {
    @get:InputFile
    abstract val with: RegularFileProperty

    @get:InputFile
    abstract val without: RegularFileProperty

    @get:OutputFile
    abstract val report: RegularFileProperty

    private fun measure(apk: File): Pair<Long, Long> {
        var bytes = 0L
        var methods = 0L
        ZipFile(apk).use { zip ->
            for (e in zip.entries()) {
                if (!e.name.matches(Regex("classes\\d*\\.dex"))) continue
                val dex = zip.getInputStream(e).readBytes()
                bytes += dex.size
                // method_ids_size, little endian, at offset 88 of the dex header
                methods += ByteBuffer.wrap(dex).order(ByteOrder.LITTLE_ENDIAN).getInt(88).toLong()
            }
        }
        return bytes to methods
    }

    @TaskAction
    fun check() {
        val (b1, m1) = measure(with.get().asFile)
        val (b0, m0) = measure(without.get().asFile)
        val kb = (b1 - b0) / 1024.0
        val methods = m1 - m0
        val text = "SDK after R8: %.1f KB of dex, %d methods (budget: 150 KB, 2 500 methods)".format(kb, methods)
        println(text)
        report.get().asFile.writeText(text + "\n")
        if (kb > 150 || methods > 2500) throw GradleException("over budget: $text")
    }
}

tasks.register<CheckBudgets>("checkBudgets") {
    group = "verification"
    dependsOn("assembleWithSdkRelease", "assembleWithoutSdkRelease")
    with.set(layout.buildDirectory.file("outputs/apk/withSdk/release/budget-withSdk-release.apk"))
    without.set(layout.buildDirectory.file("outputs/apk/withoutSdk/release/budget-withoutSdk-release.apk"))
    report.set(layout.buildDirectory.file("reports/budget.txt"))
}
