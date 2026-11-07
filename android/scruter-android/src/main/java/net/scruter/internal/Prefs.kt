package net.scruter.internal

import android.content.Context
import android.content.SharedPreferences

/**
 * The flags that must survive [Engine.wipe] (docs/MOBILE.md §2.3): the user's opt-out (a choice, kept by backups like
 * the app's own setting), "ignore this device" (a file in the no-backup directory: it belongs to this phone, never
 * to a restored copy) and the "no install day" mark of an opt-in.
 */
internal class Prefs(context: Context) {
    // Lazy: created from `start`, on the main thread, and only read from the worker (no disk on the main thread).
    private val p: SharedPreferences by lazy { context.getSharedPreferences("net.scruter", Context.MODE_PRIVATE) }
    private val ignoredFile by lazy { java.io.File(context.noBackupFilesDir, "scruter-ignored") }

    var optedOut: Boolean
        get() = p.getBoolean("opted_out", false)
        set(v) = p.edit().putBoolean("opted_out", v).apply()

    var ignored: Boolean
        get() = ignoredFile.exists()
        set(v) {
            if (v) ignoredFile.writeText("1") else ignoredFile.delete()
        }

    fun markNoInstallDay() {
        p.edit().putBoolean("no_install_day", true).apply()
    }

    fun consumeNoInstallDay(): Boolean {
        if (!p.getBoolean("no_install_day", false)) return false
        p.edit().remove("no_install_day").apply()
        return true
    }
}
