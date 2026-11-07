package net.scruter.internal

import org.json.JSONArray
import org.json.JSONObject

/** A session's cumulative state (docs/MOBILE.md §3.2): what `c` and `pv` carry. */
internal class State {
    var sv = 0
    var ev = 0
    var dur = 0
    var en: String? = null
    var ex: String? = null
    val rev = LinkedHashMap<String, Long>()
    var cr = 0
    var anr = 0
    var last = 0L

    fun toJson(): JSONObject {
        val o = JSONObject()
        o.put("sv", sv.coerceAtMost(100_000))
        o.put("ev", ev.coerceAtMost(100_000))
        o.put("dur", dur.coerceIn(0, 86_400))
        en?.let { o.put("en", it) }
        ex?.let { o.put("ex", it) }
        if (rev.isNotEmpty()) {
            val r = JSONObject()
            for ((k, v) in rev) r.put(k, v.coerceIn(-100_000_000_000L, 100_000_000_000L))
            o.put("rev", r)
        }
        o.put("cr", cr)
        o.put("anr", anr.coerceAtMost(1000))
        o.put("last", last)
        return o
    }

    fun copy(): State = from(toJson())

    companion object {
        fun from(o: JSONObject): State {
            val s = State()
            s.sv = o.optInt("sv")
            s.ev = o.optInt("ev")
            s.dur = o.optInt("dur")
            s.en = if (o.has("en")) o.getString("en") else null
            s.ex = if (o.has("ex")) o.getString("ex") else null
            o.optJSONObject("rev")?.let { r -> for (k in r.keys()) s.rev[k] = r.getLong(k) }
            s.cr = o.optInt("cr")
            s.anr = o.optInt("anr")
            s.last = o.optLong("last")
            return s
        }
    }
}

/**
 * A session as the SDK keeps it until the server has acknowledged its last state: the fixed fields sent with every
 * state ([base]: id, d, st, i, n, p, bid, av, ab, bk, tm, os, m, f, l, o), the live state [c], the state last
 * acknowledged ([acked], [ackedQ]), and what a crash report read at the next launch needs (breadcrumbs, screen).
 */
internal class SessionRec(val base: JSONObject) {
    val id: String = base.getString("id")
    val start: Long = base.getLong("st")
    var c = State()
    var acked: State? = null
    var ackedQ = 0
    var ended = false
    var pid = 0
    var aa = false
    var ins: JSONObject? = null
    var screen: String? = null
    val crumbs = ArrayList<JSONObject>()

    /** Something the server has not acknowledged: a new state, or a session never sent. */
    val dirty: Boolean get() = ackedQ == 0 || acked?.toJson()?.toString() != c.toJson().toString() || ins != null

    fun crumb(kind: String, name: String, time: Long) {
        val o = JSONObject()
        o.put("k", kind)
        o.put("n", name)
        o.put("t", time)
        synchronized(crumbs) {
            crumbs.add(o)
            while (crumbs.size > 10) crumbs.removeAt(0)
        }
    }

    /** The session object of a batch: state number [q], the live state, the acknowledged one as `pv`. */
    fun wire(q: Int): JSONObject {
        val o = JSONObject(base.toString())
        o.put("q", q)
        o.put("c", c.toJson())
        if (q > 1) acked?.let { o.put("pv", it.toJson()) }
        ins?.let { o.put("ins", it) }
        return o
    }

    fun toJson(): JSONObject {
        val o = JSONObject()
        o.put("base", base)
        o.put("c", c.toJson())
        acked?.let { o.put("acked", it.toJson()) }
        o.put("ackedQ", ackedQ)
        o.put("ended", ended)
        o.put("pid", pid)
        o.put("aa", aa)
        ins?.let { o.put("ins", it) }
        screen?.let { o.put("scr", it) }
        synchronized(crumbs) { o.put("bc", JSONArray(crumbs)) }
        return o
    }

    companion object {
        fun from(o: JSONObject): SessionRec {
            val s = SessionRec(o.getJSONObject("base"))
            s.c = State.from(o.getJSONObject("c"))
            o.optJSONObject("acked")?.let { s.acked = State.from(it) }
            s.ackedQ = o.optInt("ackedQ")
            s.ended = o.optBoolean("ended")
            s.pid = o.optInt("pid")
            s.aa = o.optBoolean("aa")
            s.ins = o.optJSONObject("ins")
            s.screen = if (o.has("scr")) o.getString("scr") else null
            o.optJSONArray("bc")?.let { a -> for (i in 0 until a.length()) s.crumbs.add(a.getJSONObject(i)) }
            return s
        }
    }
}
