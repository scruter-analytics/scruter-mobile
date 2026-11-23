package net.scruter.cmp.internal

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The persistent queue of hits, proofs and SDK reports (docs/CMP-MOBILE.md §3.10): one small JSON file in the app's
 * no-backup directory, rewritten atomically on each change, used from the worker thread only. Same rules as the
 * Analytics queue (docs/MOBILE.md §3.15): items older than 48 hours are dropped, failures retry with an exponential
 * backoff honouring `Retry-After`, any other 4xx drops the item.
 *
 * At most [MAX_ITEMS] items, the oldest hits dropped first (the whole file is rewritten on each change: 500 items of
 * ≈ 400 bytes keep that write under a millisecond; a phone offline for 48 hours opens the app far fewer times).
 */
internal class Queue(file: File) {
    class Item(val id: Long, val kind: String, val path: String, val body: String, val created: Long, val ref: String?)

    private val f = AtomicFile(file)
    private val items = ArrayList<Item>()
    private var next = 1L

    init {
        try {
            val a = JSONArray(String(f.readFully(), Charsets.UTF_8))
            for (i in 0 until a.length()) {
                val o = a.getJSONObject(i)
                items.add(Item(o.getLong("id"), o.getString("k"), o.getString("p"), o.getString("b"), o.getLong("t"), o.optStringOrNull("r")))
            }
            next = (items.maxOfOrNull { it.id } ?: 0L) + 1
        } catch (e: Exception) {
            // No file yet, or an unreadable one: an empty queue.
        }
    }

    val size: Int get() = items.size

    fun all(): List<Item> = ArrayList(items)

    fun has(ref: String): Boolean = items.any { it.ref == ref }

    fun add(kind: String, path: String, body: JSONObject, now: Long, ref: String? = null): Item {
        val item = Item(next++, kind, path, body.toString(), now, ref)
        items.add(item)
        while (items.size > MAX_ITEMS) {
            val drop = items.firstOrNull { it.kind == HIT } ?: items.first()
            items.remove(drop)
        }
        save()
        return item
    }

    fun remove(id: Long) {
        if (items.removeAll { it.id == id }) save()
    }

    fun removeRef(ref: String) {
        if (items.removeAll { it.ref == ref }) save()
    }

    fun dropBefore(time: Long): Int {
        val n = items.size
        items.removeAll { it.created < time }
        if (items.size != n) save()
        return n - items.size
    }

    fun clear() {
        items.clear()
        save()
    }

    private fun save() {
        val a = JSONArray()
        for (i in items) {
            val o = JSONObject().put("id", i.id).put("k", i.kind).put("p", i.path).put("b", i.body).put("t", i.created)
            if (i.ref != null) o.put("r", i.ref)
            a.put(o)
        }
        val out = try {
            f.startWrite()
        } catch (e: java.io.IOException) {
            Log.w("queue not saved", e)
            return
        }
        try {
            out.write(a.toString().toByteArray(Charsets.UTF_8))
            f.finishWrite(out)
        } catch (e: java.io.IOException) {
            f.failWrite(out)
        }
    }

    companion object {
        const val HIT = "hit"
        const val CONSENT = "consent"
        const val SDKS = "sdks"
        const val MAX_ITEMS = 500
        const val MAX_AGE = 48L * 3600 * 1000

        /** 5 s × 2ⁿ ± 20 %, at most 10 minutes, or `Retry-After` when longer (the Analytics rule). */
        fun delayFor(n: Int, retryAfter: Long, random: Double): Long {
            val base = minOf(5_000L shl minOf(n, 7), 600_000L)
            val jittered = (base * (0.8 + 0.4 * random)).toLong().coerceAtMost(600_000L)
            return maxOf(jittered, retryAfter)
        }
    }
}
