package net.scruter.internal

import android.os.Handler
import android.os.Looper
import android.os.SystemClock

/**
 * ANR watchdog below Android 11 (docs/MOBILE.md §3.10): while the app is in the foreground, a thread checks that the
 * main thread runs a message within 5 s (the system's threshold); when it does not, the main thread's stack is
 * recorded once per freeze. Android 11 and later read ANRs from `ApplicationExitInfo` instead. No timer in the
 * background: the thread waits while the app is not visible.
 */
internal class Anr(private val engine: Engine) : Thread("Scruter-ANR") {
    private val main = Handler(Looper.getMainLooper())
    private val lock = Object()

    @Volatile
    private var visible = false

    @Volatile
    private var ticked = true

    private val tick = Runnable { ticked = true }

    init {
        isDaemon = true
    }

    fun setVisible(v: Boolean) {
        synchronized(lock) {
            visible = v
            lock.notifyAll()
        }
    }

    override fun run() {
        try {
            while (true) {
                synchronized(lock) { while (!visible) lock.wait() }
                ticked = false
                main.post(tick)
                sleep(TIMEOUT)
                if (!ticked && visible && !android.os.Debug.isDebuggerConnected()) {
                    val id = engine.clock.sessionId
                    if (id != null) {
                        val report = Crashes.report(engine, id, "anr", Looper.getMainLooper().thread, null, System.currentTimeMillis())
                        engine.post { engine.crash(id, report, anr = true) }
                    }
                    // One report per freeze: wait until the main thread runs again.
                    val since = SystemClock.elapsedRealtime()
                    while (!ticked && SystemClock.elapsedRealtime() - since < 60_000) sleep(500)
                }
            }
        } catch (e: InterruptedException) {
            // The SDK stops.
        }
    }

    companion object {
        const val TIMEOUT = 5_000L
    }
}
