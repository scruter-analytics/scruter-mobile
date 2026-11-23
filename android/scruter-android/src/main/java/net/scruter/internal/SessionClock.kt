package net.scruter.internal

import android.os.SystemClock

/**
 * Foreground time of the running session (docs/MOBILE.md §3.2), written by the main thread and read by the worker:
 * `dur` counts seconds in the foreground only.
 */
internal class SessionClock {
    @Volatile
    var sessionId: String? = null
        private set

    @Volatile
    var foreground = false
        private set

    @Volatile
    private var accumulated = 0L

    @Volatile
    private var since = 0L

    /** The main thread starts a session: the clock restarts. */
    fun start(id: String, now: Long = SystemClock.elapsedRealtime()) {
        sessionId = id
        accumulated = 0
        since = if (foreground) now else 0
    }

    fun toForeground(now: Long = SystemClock.elapsedRealtime()) {
        if (!foreground) {
            foreground = true
            since = now
        }
    }

    fun toBackground(now: Long = SystemClock.elapsedRealtime()) {
        if (foreground) {
            accumulated += now - since
            foreground = false
            since = 0
        }
    }

    /** Seconds in the foreground of session [id]; [known] for a session that is not the running one. */
    fun durationSeconds(id: String, known: Int, now: Long = SystemClock.elapsedRealtime()): Int {
        if (id != sessionId) return known
        val ms = accumulated + if (foreground && since > 0) now - since else 0
        return maxOf(known, (ms / 1000).toInt()).coerceAtMost(86_400)
    }
}
