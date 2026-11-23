package net.scruter.internal

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import java.util.Locale

/**
 * The facts of the app and the phone a session carries (docs/MOBILE.md §2.2): a model shared by millions, never a
 * device identifier. Read once, off the main thread.
 */
internal class Env(context: Context, testBuild: Boolean) {
    val packageName: String = context.packageName
    val debuggable: Boolean = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    val versionName: String
    val versionCode: String
    val firstInstallTime: Long
    val installer: String?
    val buildKind: String = when {
        debuggable -> "debug"
        testBuild -> "test"
        else -> "release"
    }
    val model: String = model(Build.MANUFACTURER, Build.MODEL)
    val os: String = Text.clean(Build.VERSION.RELEASE, 20) ?: Build.VERSION.SDK_INT.toString()
    val tablet: Boolean = context.resources.configuration.smallestScreenWidthDp >= 600
    val form: String get() = if (tablet) "tablet" else "phone"

    init {
        var name: String? = null
        var code = ""
        var installed = 0L
        try {
            val info = context.packageManager.getPackageInfo(packageName, 0)
            name = info.versionName
            @Suppress("DEPRECATION")
            code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode.toString() else info.versionCode.toString()
            installed = info.firstInstallTime
        } catch (e: PackageManager.NameNotFoundException) {
            Log.w("package info unavailable", e)
        }
        versionName = Text.clean(name, 40) ?: Text.clean(code, 40) ?: "0"
        versionCode = Text.cut(code, 40)
        firstInstallTime = installed
        installer = try {
            if (Build.VERSION.SDK_INT >= 30) {
                context.packageManager.getInstallSourceInfo(packageName).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getInstallerPackageName(packageName)
            }
        } catch (e: Exception) {
            null
        }
    }

    /** The phone's language, 2 letters (absent for a 3-letter code). */
    fun language(): String? {
        val l = when (val raw = Locale.getDefault().language) {
            "iw" -> "he"
            "in" -> "id"
            "ji" -> "yi"
            else -> raw
        }
        return if (l.length == 2 && l.all { it in 'a'..'z' }) l else null
    }

    companion object {
        /** `Build.MANUFACTURER` + `Build.MODEL`, without repeating the maker ("Google Pixel 8"), ≤ 60 characters. */
        fun model(manufacturer: String?, model: String?): String {
            val maker = (manufacturer ?: "").trim().replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.ROOT) else it.toString() }
            val m = (model ?: "").trim()
            val joined = when {
                m.isEmpty() -> maker
                maker.isEmpty() || m.startsWith(maker, ignoreCase = true) -> m
                else -> "$maker $m"
            }
            return Text.clean(joined, 60) ?: "Android"
        }
    }
}
