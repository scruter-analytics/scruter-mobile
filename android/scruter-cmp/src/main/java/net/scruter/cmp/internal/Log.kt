package net.scruter.cmp.internal

/** Debug logging (docs/CMP-MOBILE.md §3.13): Logcat tag `ScruterCMP`, when `ScruterCMP.debug` is on. */
internal object Log {
    @Volatile
    @JvmField
    var on: Boolean = false

    /** Lines kept for the tests and the example app's debug screen. */
    @Volatile
    @JvmField
    var sink: ((String) -> Unit)? = null

    fun d(message: String) {
        sink?.invoke(message)
        if (on) android.util.Log.d("ScruterCMP", message)
    }

    fun w(message: String, error: Throwable? = null) {
        sink?.invoke(message)
        if (on) android.util.Log.w("ScruterCMP", message, error)
    }

    /** Always shown: a mistake of the app's integration (an invalid app id, a missing settings entry). */
    fun e(message: String) {
        sink?.invoke(message)
        android.util.Log.e("ScruterCMP", message)
    }
}
