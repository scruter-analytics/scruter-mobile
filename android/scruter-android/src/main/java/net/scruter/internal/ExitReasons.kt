package net.scruter.internal

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Android 11+ (docs/MOBILE.md §3.10): at launch, the reasons the previous processes ended. `REASON_CRASH_NATIVE`
 * (with its tombstone from Android 12) and `REASON_ANR` (with the main thread's trace) become reports of the session
 * that process was running; Java crashes come from the uncaught-exception handler (never twice).
 */
@android.annotation.TargetApi(30)
internal object ExitReasons {
    private const val K_SEEN = "exit_seen"

    fun read(engine: Engine) {
        val store = engine.store ?: return
        val am = engine.context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
        val infos = try {
            am.getHistoricalProcessExitReasons(engine.context.packageName, 0, 16)
        } catch (e: Exception) {
            return
        }
        val seen = store.get(K_SEEN)?.toLongOrNull()
        val newest = infos.maxOfOrNull { it.timestamp } ?: 0L
        if (newest > 0) store.put(K_SEEN, maxOf(newest, seen ?: 0L).toString())
        if (seen == null) return // the SDK's first run: what happened before it is not ours to report
        for (info in infos) {
            if (info.timestamp <= seen) continue
            val kind = when (info.reason) {
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash"
                ApplicationExitInfo.REASON_ANR -> "anr"
                else -> continue
            }
            val sessionId = engine.sessionOfPid(info.pid) ?: continue
            try {
                val report = report(engine, sessionId, kind, info)
                engine.crash(sessionId, report, anr = kind == "anr")
            } catch (e: Exception) {
                Log.d("exit reason unreadable: ${e.javaClass.simpleName}")
            }
        }
    }

    private fun report(engine: Engine, sessionId: String, kind: String, info: ApplicationExitInfo): JSONObject {
        val r = JSONObject()
        r.put("s", sessionId)
        r.put("id", Text.randomHex(8))
        r.put("t", info.timestamp)
        r.put("k", kind)
        r.put("src", "native")
        val trace = try {
            info.traceInputStream?.use { it.readBytes() }
        } catch (e: Exception) {
            null
        }
        if (kind == "crash") {
            if (trace != null && trace.isNotEmpty()) {
                Tombstone.fill(r, Tombstone.parse(trace), engine.env.packageName)
            } else {
                // Android 11 keeps no tombstone for the app: the crash still counts, without a stack.
                r.put("ex", JSONObject().put("type", "SIGNAL").put("reason", Text.clean(info.description, 200) ?: "native crash"))
                r.put("th", JSONArray().put(Crashes.thread(JSONArray(), crashed = true, main = false)))
            }
        } else {
            r.put("ex", JSONObject().put("type", "ANR").put("reason", Text.clean(info.description, 200) ?: "Application Not Responding"))
            val frames = if (trace != null) Tombstone.anrFrames(String(trace, Charsets.UTF_8), engine.env.packageName) else JSONArray()
            r.put("th", JSONArray().put(Crashes.thread(frames, crashed = true, main = true)))
        }
        r.put("map", engine.mappingId)
        val rec = engine.session(sessionId)
        if (rec != null) {
            val bc = JSONArray()
            synchronized(rec.crumbs) { for (c in rec.crumbs) bc.put(c) }
            if (bc.length() > 0) r.put("bc", bc)
            rec.screen?.let { r.put("scr", it) }
        }
        r.put("fg", if (info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE) 1 else 0)
        return r
    }
}
