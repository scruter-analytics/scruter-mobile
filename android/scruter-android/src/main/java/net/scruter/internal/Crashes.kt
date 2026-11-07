package net.scruter.internal

import android.os.Looper
import android.os.Process
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

/**
 * Crash capture (docs/MOBILE.md §3.10): the uncaught-exception handler, chained with the one installed before (other
 * crash reporters keep working). At the crash the report is written to a file, synchronously; the next launch queues
 * it and marks the crashed session `cr = 1`. A report holds the exception type, its message cut to 200 characters
 * (masked again by the server), the crashed and main threads' frames, the R8 mapping id, the screen, the last 10
 * screen and event names: never a property value, never a log.
 */
internal object Crashes {
    private val SYSTEM = arrayOf(
        "android.", "androidx.", "java.", "javax.", "kotlin.", "kotlinx.", "com.android.", "dalvik.", "libcore.",
        "sun.", "com.google.android.", "org.json.", "org.xml.", "org.apache.", "net.scruter.",
    )

    fun install(engine: Engine) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is Handler) return
        Thread.setDefaultUncaughtExceptionHandler(Handler(engine, previous))
    }

    private class Handler(val engine: Engine, val previous: Thread.UncaughtExceptionHandler?) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, error: Throwable) {
            try {
                write(engine, thread, error)
            } catch (e: Throwable) {
                // Never stand between the app and the system's crash handling.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    /** A wrapper reported its fatal error: the exception that follows is the same crash, until this time (ms). */
    @Volatile
    @JvmField
    var mutedUntil = 0L

    private fun write(engine: Engine, thread: Thread, error: Throwable) {
        if (!engine.running || System.currentTimeMillis() < mutedUntil) return
        val id = engine.clock.sessionId ?: return
        val report = report(engine, id, "crash", thread, rootCause(error), System.currentTimeMillis())
        save(engine, id, report)
    }

    fun rootCause(error: Throwable): Throwable {
        var e = error
        var depth = 0
        while (e.cause != null && e.cause !== e && depth++ < 20) e = e.cause!!
        return e
    }

    /** A Java/Kotlin report for [kind] `crash` or `anr`. */
    fun report(engine: Engine, sessionId: String, kind: String, thread: Thread, error: Throwable?, time: Long): JSONObject {
        val r = JSONObject()
        r.put("s", sessionId)
        r.put("id", Text.randomHex(8))
        r.put("t", time)
        r.put("k", kind)
        r.put("src", "native")
        val ex = JSONObject()
        if (error != null) {
            ex.put("type", Text.cut(error.javaClass.name, 200))
            Text.clean(error.message, 200)?.let { ex.put("reason", it) }
        } else {
            ex.put("type", "ANR")
            ex.put("reason", "The main thread was blocked for 5 seconds")
        }
        r.put("ex", ex)
        val main = Looper.getMainLooper().thread
        val threads = JSONArray()
        val crashedFrames = javaFrames(error?.stackTrace ?: thread.stackTrace)
        threads.put(thread(crashedFrames, crashed = true, main = thread === main))
        if (thread !== main) threads.put(thread(javaFrames(main.stackTrace), crashed = false, main = true))
        r.put("th", threads)
        r.put("map", engine.mappingId)
        context(engine, sessionId, r)
        return r
    }

    /** Breadcrumbs, screen, foreground and time since launch. */
    fun context(engine: Engine, sessionId: String, r: JSONObject) {
        val rec = try {
            engine.session(sessionId)
        } catch (e: Exception) {
            null
        }
        if (rec != null) {
            val bc = JSONArray()
            synchronized(rec.crumbs) { for (c in rec.crumbs) bc.put(c) }
            if (bc.length() > 0) r.put("bc", bc)
            rec.screen?.let { r.put("scr", it) }
        }
        r.put("fg", if (engine.clock.foreground) 1 else 0)
        r.put("up", (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime()).coerceAtLeast(0))
    }

    fun thread(frames: JSONArray, crashed: Boolean, main: Boolean): JSONObject {
        val t = JSONObject()
        if (crashed) t.put("c", 1)
        if (main) t.put("m", 1)
        if (frames.length() == 0) frames.put(JSONObject().put("fn", "?"))
        t.put("f", frames)
        return t
    }

    fun javaFrames(trace: Array<StackTraceElement>): JSONArray {
        val out = JSONArray()
        for (e in trace) {
            if (out.length() >= 64) break
            out.put(javaFrame(e.className, e.methodName, e.fileName, e.lineNumber))
        }
        return out
    }

    fun javaFrame(cls: String, method: String, file: String?, line: Int): JSONObject {
        val f = JSONObject()
        f.put("cl", Text.cut(cls, 200))
        f.put("fn", Text.cut(method, 200))
        file?.let { f.put("fl", Text.cut(it, 200)) }
        if (line >= 0) f.put("l", line)
        if (SYSTEM.none { cls.startsWith(it) }) f.put("ia", 1)
        return f
    }

    /** Written synchronously by the crashing thread: one file per report, renamed into place. */
    fun save(engine: Engine, sessionId: String, report: JSONObject) {
        val dir = engine.crashDir
        dir.mkdirs()
        val tmp = File(dir, report.getString("id") + ".tmp")
        FileOutputStream(tmp).use { out ->
            out.write(JSONObject().put("s", sessionId).put("report", report).toString().toByteArray())
            out.fd.sync()
        }
        tmp.renameTo(File(dir, report.getString("id") + ".json"))
    }

    /** At launch: queues the reports the previous runs wrote (docs/MOBILE.md §3.10: ≤ 10 waiting). */
    fun importFiles(engine: Engine) {
        val files = engine.crashDir.listFiles() ?: return
        for (f in files.sortedBy { it.lastModified() }) {
            try {
                if (f.name.endsWith(".json")) {
                    val o = JSONObject(f.readText())
                    engine.crash(o.getString("s"), o.getJSONObject("report"), anr = o.getJSONObject("report").optString("k") == "anr")
                }
            } catch (e: Exception) {
                Log.d("unreadable crash file dropped")
            }
            f.delete()
        }
    }
}
