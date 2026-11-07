package net.scruter.internal

import org.json.JSONArray
import org.json.JSONObject

/**
 * One screen view on the main thread: engaged time and scroll depth for everyone (`screen_end`), and, in sessions of
 * the Advanced analytics sample, the analysed screen view `x` (docs/MOBILE.md §3.6–§3.9, docs/API.md §5.3): visible and
 * engaged ms, the 50 bands, taps, forms, its states numbered 1–10.
 */
internal class ScreenView(
    val name: String,
    val sessionId: String,
    private val sampled: () -> Boolean,
    val startWall: Long,
    val startElapsed: Long,
) {
    val k: Long = Text.randomViewNumber()

    /** In the Advanced analytics sample (decided by the worker when the session starts). */
    val aa: Boolean get() = sampled()
    private var q = 0
    private var dt = 0L
    private var et = 0L
    private var lastTick = startElapsed
    private var lastActive = startElapsed
    private val at = LongArray(BANDS)
    private var from = 0f
    private var to = 1f
    private var hasScroll = false
    var depth = 0
        private set
    private var interacted = 0
    var taps = 0
        private set
    private var dead = 0
    private var rage = 0
    private var newTaps = JSONArray()
    private var reportedEt = 0L
    private var reportedDepth = -1
    var vw = 0
    var vh = 0
    var ch = 0
    val forms = Forms(name)
    private var dirty = true
    var visible = true

    /** Adds the time since the last tick: visible always, engaged while an interaction is under 60 s old (§3.8). */
    fun tick(now: Long) {
        if (visible && now > lastTick) {
            dt += now - lastTick
            val activeUntil = minOf(now, lastActive + IDLE)
            val engaged = maxOf(0L, activeUntil - lastTick)
            if (engaged > 0) {
                et += engaged
                val a = (from * BANDS).toInt().coerceIn(0, BANDS - 1)
                val b = (Math.ceil((to * BANDS).toDouble()).toInt() - 1).coerceIn(a, BANDS - 1)
                for (i in a..b) at[i] += engaged
                dirty = true
            }
        }
        lastTick = now
    }

    fun interact(now: Long) {
        tick(now)
        lastActive = now
    }

    fun suspend(now: Long) {
        tick(now)
        visible = false
    }

    fun resume(now: Long) {
        lastTick = now
        lastActive = now
        visible = true
    }

    /** The scroll container moved or was measured; [s] null: nothing scrolls (one container of 100 %). */
    fun scrolled(now: Long, s: ScrollInfo?, density: Float, userScroll: Boolean) {
        if (userScroll) interact(now) else tick(now)
        if (s == null) {
            if (!hasScroll) {
                from = 0f
                to = 1f
                if (depth < 100) {
                    depth = 100
                    dirty = true
                }
            }
            return
        }
        hasScroll = true
        from = s.from
        to = s.to
        ch = (s.content / density).toInt().coerceIn(0, 1_000_000)
        val p = Scroll.percent(s.depth)
        if (p > depth) {
            depth = p
            dirty = true
        }
        if (userScroll && s.from * s.content >= vh * density / 2f) interacted = 1
    }

    /** A tap's record: [selector, index, kind, x %, y %, ms since the view started, flags (1 dead, 2 rage)]. */
    fun tap(selector: String, index: Int, kind: String, x: Int, y: Int, ms: Long, flags: Int) {
        interacted = 1
        if (taps >= MAX_TAPS) return
        taps++
        if (flags and 1 != 0) dead++
        if (flags and 2 != 0) rage++
        newTaps.put(JSONArray().put(selector).put(index).put(kind).put(x.coerceIn(0, 100)).put(y.coerceIn(0, 100))
            .put(ms.coerceIn(0, 86_400_000)).put(flags))
        dirty = true
    }

    val tapsSinceState: Int get() = newTaps.length()

    /** The engagement since the last report, for `screen_end` (null: nothing worth reporting, the web's rule). */
    fun engagement(final: Boolean): Pair<Long, Int>? {
        val delta = et - reportedEt
        val d = if (hasScroll || depth > 0) depth else 100
        if (delta < 1000 && d <= reportedDepth && !(final && reportedDepth < 0)) return null
        reportedEt = et
        reportedDepth = maxOf(reportedDepth, d)
        return Pair(delta, d)
    }

    /**
     * The next state of the analysed screen view, or null (not in the sample, nothing new, or no state number left:
     * states 1–9 for the intermediate ones, the last kept for the end).
     */
    fun state(final: Boolean): JSONObject? {
        if (!aa) return null
        if (!dirty && !forms.dirty && q > 0) return null
        if (q >= 10 || !final && q >= 9) return null
        q++
        dirty = false
        val o = JSONObject()
        o.put("s", sessionId)
        o.put("k", k)
        o.put("q", q)
        o.put("n", name)
        o.put("t", startWall)
        o.put("vw", vw.coerceIn(0, 10_000))
        o.put("vh", vh.coerceIn(0, 10_000))
        o.put("ch", (if (ch > 0) ch else vh).coerceIn(0, 1_000_000))
        o.put("sd", if (hasScroll) depth else 100)
        o.put("dt", dt.coerceAtMost(86_400_000))
        o.put("et", et.coerceAtMost(86_400_000))
        o.put("ia", interacted)
        var last = BANDS
        while (last > 0 && at[last - 1] == 0L) last--
        val bands = JSONArray()
        for (i in 0 until last) bands.put(at[i].coerceAtMost(86_400_000))
        o.put("at", bands)
        o.put("cn", taps)
        o.put("cd", dead)
        o.put("cr", rage)
        if (newTaps.length() > 0) o.put("c", newTaps)
        newTaps = JSONArray()
        val f = forms.toJson()
        if (f.length() > 0) o.put("f", f)
        return o
    }

    companion object {
        const val BANDS = 50
        const val IDLE = 60_000L
        const val MAX_TAPS = 300
        const val TAPS_PER_STATE = 100
    }
}
