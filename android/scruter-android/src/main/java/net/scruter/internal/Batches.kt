package net.scruter.internal

import org.json.JSONArray
import org.json.JSONObject

/**
 * Builds the next batch (docs/MOBILE.md §3.15, docs/API.md §5.3): the oldest waiting items within the caps (200
 * events, 20 analysed screen views, 5 crash reports, 20 sessions, 512 KB of JSON), and the state of every session the
 * batch touches or whose state the server has not acknowledged, numbered `q = acknowledged + 1` with `pv`.
 */
internal object Batches {
    const val MAX_EVENTS = 200
    const val MAX_VIEWS = 20
    const val MAX_CRASHES = 5
    const val MAX_SESSIONS = 20
    const val MAX_JSON = 512 * 1024
    private const val RESERVE = 48 * 1024

    fun build(engine: Engine, store: Store, sessions: Map<String, SessionRec>, now: Long): Store.Inflight? {
        val included = LinkedHashMap<String, SessionRec>()
        val events = JSONArray()
        val views = JSONArray()
        val crashes = JSONArray()
        val ids = ArrayList<Long>()
        val orphans = ArrayList<Long>()
        var size = 0
        for (item in store.items(400)) {
            val rec = sessions[item.session]
            if (rec == null) {
                orphans.add(item.id)
                continue
            }
            val target = when (item.kind) {
                Store.EVENT -> events.takeIf { it.length() < MAX_EVENTS }
                Store.SCREEN_VIEW -> views.takeIf { it.length() < MAX_VIEWS }
                else -> crashes.takeIf { it.length() < MAX_CRASHES }
            } ?: continue
            if (!included.containsKey(rec.id) && included.size >= MAX_SESSIONS) continue
            if (size + item.body.length > MAX_JSON - RESERVE) break
            val json = try {
                JSONObject(item.body)
            } catch (e: Exception) {
                orphans.add(item.id)
                continue
            }
            target.put(json)
            ids.add(item.id)
            size += item.body.length + 1
            included[rec.id] = rec
        }
        if (orphans.isNotEmpty()) store.deleteItems(orphans)
        for (rec in sessions.values) {
            if (included.size >= MAX_SESSIONS) break
            if (!included.containsKey(rec.id) && rec.dirty) included[rec.id] = rec
        }
        if (included.isEmpty()) return null
        val wire = JSONArray()
        val states = JSONObject()
        for (rec in included.values) {
            if (!rec.ended) rec.c.dur = engine.clock.durationSeconds(rec.id, rec.c.dur)
            val q = rec.ackedQ + 1
            wire.put(rec.wire(q))
            states.put(rec.id, JSONObject().put("q", q).put("c", rec.c.toJson()).put("ins", rec.ins != null))
        }
        val batch = JSONObject()
        batch.put("v", 1)
        batch.put("a", engine.options.appId)
        batch.put("b", Text.randomHex(16))
        batch.put("t", now)
        batch.put("sdk", engine.options.sdk)
        batch.put("ce", engine.config.etag)
        batch.put("dbg", if (engine.options.debug) 1 else 0)
        batch.put("s", wire)
        if (events.length() > 0) batch.put("e", events)
        if (views.length() > 0) batch.put("x", views)
        if (crashes.length() > 0) batch.put("cr", crashes)
        return Store.Inflight(now, batch.toString(), ids.joinToString(","), states.toString())
    }
}
