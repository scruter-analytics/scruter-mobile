package net.scruter.internal

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import java.io.File

/**
 * The persistent queue (docs/MOBILE.md §3.15): one SQLite file in the app's no-backup directory (never copied by Auto
 * Backup to another phone), used from the SDK's worker thread only.
 *
 * - `items`: events, analysed screen views and crash reports waiting to be sent, oldest first;
 * - `sessions`: every session whose last state the server has not acknowledged yet, with its acknowledged state;
 * - `inflight`: the batch being sent, kept as built so that a retry resends exactly it (same `b`, same `q`);
 * - `kv`: the SDK's small state (install day, daily id, configuration, referrer, team phone).
 */
internal class Store(file: File) {
    class Item(val id: Long, val kind: Int, val session: String, val time: Long, val body: String)

    private val db: SQLiteDatabase
    var count: Int = 0
        private set
    var bytes: Long = 0
        private set
    var crashes: Int = 0
        private set

    init {
        file.parentFile?.mkdirs()
        db = SQLiteDatabase.openOrCreateDatabase(file, null)
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY AUTOINCREMENT, kind INTEGER NOT NULL, " +
                "session TEXT NOT NULL, t INTEGER NOT NULL, size INTEGER NOT NULL, body TEXT NOT NULL)",
        )
        db.execSQL("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, body TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS inflight (id INTEGER PRIMARY KEY, created INTEGER NOT NULL, body TEXT NOT NULL, " +
                "items TEXT NOT NULL, states TEXT NOT NULL)",
        )
        recount()
    }

    private fun recount() {
        db.rawQuery("SELECT COUNT(*), COALESCE(SUM(size), 0), COALESCE(SUM(kind = $CRASH), 0) FROM items", null).use {
            if (it.moveToFirst()) {
                count = it.getInt(0)
                bytes = it.getLong(1)
                crashes = it.getInt(2)
            }
        }
    }

    fun get(key: String): String? =
        db.rawQuery("SELECT v FROM kv WHERE k = ?", arrayOf(key)).use { if (it.moveToFirst()) it.getString(0) else null }

    fun put(key: String, value: String?) {
        if (value == null) {
            db.delete("kv", "k = ?", arrayOf(key))
        } else {
            val v = ContentValues(2)
            v.put("k", key)
            v.put("v", value)
            db.insertWithOnConflict("kv", null, v, SQLiteDatabase.CONFLICT_REPLACE)
        }
    }

    /** Queues an item and applies the limits: 5 000 items or 5 MB, ≤ 10 crash reports, the oldest dropped first. */
    fun add(kind: Int, session: String, time: Long, body: String): Long {
        val v = ContentValues(5)
        v.put("kind", kind)
        v.put("session", session)
        v.put("t", time)
        v.put("size", body.length)
        v.put("body", body)
        val id = db.insert("items", null, v)
        count++
        bytes += body.length
        if (kind == CRASH) crashes++
        if (kind == CRASH && crashes > MAX_CRASHES) {
            db.execSQL(
                "DELETE FROM items WHERE id IN (SELECT id FROM items WHERE kind = $CRASH ORDER BY id LIMIT ?)",
                arrayOf<Any>(crashes - MAX_CRASHES),
            )
            recount()
        }
        if (count > MAX_ITEMS || bytes > MAX_BYTES) {
            val excess = maxOf(count - MAX_ITEMS, 0) + if (bytes > MAX_BYTES) maxOf(count / 10, 1) else 0
            db.execSQL("DELETE FROM items WHERE id IN (SELECT id FROM items ORDER BY id LIMIT ?)", arrayOf<Any>(excess))
            recount()
        }
        return id
    }

    /** The oldest waiting items, at most [limit]. */
    fun items(limit: Int): List<Item> {
        val out = ArrayList<Item>()
        db.rawQuery("SELECT id, kind, session, t, body FROM items ORDER BY id LIMIT $limit", null).use {
            while (it.moveToNext()) out.add(Item(it.getLong(0), it.getInt(1), it.getString(2), it.getLong(3), it.getString(4)))
        }
        return out
    }

    fun oldestItemTime(): Long =
        db.rawQuery("SELECT MIN(t) FROM items", null).use { if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else 0L }

    fun hasItemsOf(session: String): Boolean =
        db.rawQuery("SELECT 1 FROM items WHERE session = ? LIMIT 1", arrayOf(session)).use { it.moveToFirst() }

    fun deleteItems(ids: Collection<Long>) {
        if (ids.isEmpty()) return
        db.beginTransaction()
        try {
            for (id in ids) db.delete("items", "id = ?", arrayOf(id.toString()))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        recount()
    }

    /** Drops what the server could not place any more (docs/MOBILE.md §2.1: 48 hours). */
    fun dropBefore(time: Long) {
        val n = db.delete("items", "t < ?", arrayOf(time.toString()))
        if (n > 0) recount()
    }

    fun sessions(): List<String> {
        val out = ArrayList<String>()
        db.rawQuery("SELECT body FROM sessions", null).use { while (it.moveToNext()) out.add(it.getString(0)) }
        return out
    }

    fun putSession(id: String, body: String) {
        val v = ContentValues(2)
        v.put("id", id)
        v.put("body", body)
        db.insertWithOnConflict("sessions", null, v, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun deleteSession(id: String) {
        db.delete("sessions", "id = ?", arrayOf(id))
        db.delete("items", "session = ?", arrayOf(id))
        recount()
    }

    class Inflight(val created: Long, val body: String, val items: String, val states: String)

    fun inflight(): Inflight? =
        db.rawQuery("SELECT created, body, items, states FROM inflight WHERE id = 1", null).use {
            if (it.moveToFirst()) Inflight(it.getLong(0), it.getString(1), it.getString(2), it.getString(3)) else null
        }

    fun putInflight(f: Inflight) {
        val v = ContentValues(5)
        v.put("id", 1)
        v.put("created", f.created)
        v.put("body", f.body)
        v.put("items", f.items)
        v.put("states", f.states)
        db.insertWithOnConflict("inflight", null, v, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun clearInflight() {
        db.delete("inflight", null, null)
    }

    fun close() {
        db.close()
    }

    companion object {
        const val EVENT = 0
        const val SCREEN_VIEW = 1
        const val CRASH = 2
        const val MAX_ITEMS = 5000
        const val MAX_BYTES = 5L * 1024 * 1024
        const val MAX_CRASHES = 10
    }
}
