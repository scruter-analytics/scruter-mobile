package net.scruter.cmp.internal

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build

/**
 * The app's facts a beacon carries (docs/CMP-MOBILE.md §4.2): its package (`ap`), version (`av`), whether it is a
 * debug build (`dbg`). Never a device identifier. Read off the main thread (the package manager is an IPC).
 */
internal class Env(context: Context, sdkVersion: String) {
    val packageName: String = context.packageName
    val debuggable: Boolean = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    val versionName: String
    val sdk: String = net.scruter.cmp.bridge.ScruterCMPBridge.sdk ?: "android/$sdkVersion"

    init {
        var name: String? = null
        var code = ""
        try {
            val info = context.packageManager.getPackageInfo(packageName, 0)
            name = info.versionName
            @Suppress("DEPRECATION")
            code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode.toString() else info.versionCode.toString()
        } catch (e: PackageManager.NameNotFoundException) {
            Log.w("package info unavailable", e)
        }
        versionName = clean(name) ?: clean(code) ?: "0"
    }

    companion object {
        /** Trimmed, control characters out, ≤ 40 characters (the protocol's `av`). */
        fun clean(v: String?): String? {
            val s = v?.filter { it >= ' ' }?.trim() ?: return null
            return if (s.isEmpty()) null else s.take(40)
        }
    }
}
