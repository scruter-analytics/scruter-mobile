package net.scruter.internal

import net.scruter.bridge.LogSink

/**
 * Debug logging (docs/MOBILE.md §3.17): Logcat tag `Scruter`, only when the app starts the SDK with `debug = true`.
 * Property values are logged only by a debuggable build ([values]).
 */
internal object Log {
    @Volatile
    @JvmField
    var on: Boolean = false

    @Volatile
    @JvmField
    var values: Boolean = false

    /** Also receives the lines, for a wrapper SDK (React Native's Metro). */
    @Volatile
    @JvmField
    var sink: LogSink? = null

    fun d(message: String) {
        if (!on) return
        android.util.Log.d("Scruter", message)
        sink?.line(message)
    }

    fun w(message: String, error: Throwable? = null) {
        if (on) android.util.Log.w("Scruter", message, error)
    }
}
