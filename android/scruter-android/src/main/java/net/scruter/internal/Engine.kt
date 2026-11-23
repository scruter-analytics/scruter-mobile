package net.scruter.internal

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import net.scruter.BuildConfig
import org.json.JSONObject
import java.io.File
import java.util.Currency

/**
 * The SDK's worker (docs/MOBILE.md §3): one background thread owns the queue, the sessions, the configuration and the
 * network. The main thread only posts to it; nothing here ever blocks the app's UI.
 */
internal class Engine(
    val context: Context,
    val options: Options,
    val clock: SessionClock,
    val prefs: Prefs,
) {
    private val thread = HandlerThread("Scruter", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
    val handler = Handler(thread.looper)

    @Volatile
    var config: Config = Config.DEFAULT
        private set

    /** Collecting: started, opted in, not an ignored device, the configuration says `on`. */
    @Volatile
    var running = false
        private set

    /** The running session when it is in the Advanced analytics sample (read by the main thread). */
    @Volatile
    var sampled: String? = null
        private set

    lateinit var env: Env
        private set
    var store: Store? = null
        private set
    val dir: File by lazy { File(context.noBackupFilesDir, "scruter") }
    val crashDir: File by lazy { File(dir, "crashes") }
    private val sessions = LinkedHashMap<String, SessionRec>()
    private var current: SessionRec? = null
    var mappingId: String = ""
        private set
    val team = Team(this)
    private var sending = false
    private var attempts = 0
    private var timerAt = 0L
    private val flushTimer = Runnable {
        timerAt = 0
        flush("timer")
    }
    private val retry = Runnable { flush("retry") }
    private var configFetching = false

    fun post(block: () -> Unit) {
        handler.post {
            try {
                block()
            } catch (e: Throwable) {
                // The SDK never crashes the app: a failure is logged in debug mode and the item is lost.
                Log.w("internal error", e)
            }
        }
    }

    fun postDelayed(delay: Long, block: () -> Unit) {
        handler.postDelayed({
            try {
                block()
            } catch (e: Throwable) {
                Log.w("internal error", e)
            }
        }, delay)
    }

    // ------------------------------------------------------------------------------------------------ start

    fun init() {
        env = Env(context, options.testBuild)
        Net.userAgent = "Scruter-Android/${BuildConfig.SDK_VERSION}"
        if (prefs.optedOut || prefs.ignored) {
            Log.d("opted out: nothing is collected")
            return
        }
        if (!mainProcess()) {
            Log.d("not the app's main process: nothing is collected here")
            return
        }
        open(referrer = true)
    }

    private fun mainProcess(): Boolean {
        val name = if (android.os.Build.VERSION.SDK_INT >= 28) {
            android.app.Application.getProcessName()
        } else {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
            am?.runningAppProcesses?.firstOrNull { it.pid == Process.myPid() }?.processName
        }
        return name == null || name == context.packageName
    }

    private fun open(referrer: Boolean) {
        val s = Store(File(dir, "queue.db"))
        store = s
        crashDir.mkdirs()
        config = s.get(K_CONFIG)?.let(Config::parse) ?: Config.DEFAULT
        running = config.on
        val pid = Process.myPid()
        val now = System.currentTimeMillis()
        for (body in s.sessions()) {
            val rec = try {
                SessionRec.from(JSONObject(body))
            } catch (e: Exception) {
                null
            } ?: continue
            if (rec.pid != pid && !rec.ended) {
                // docs/MOBILE.md §3.2: a session ends when the process dies, decided at the next launch.
                rec.ended = true
                s.putSession(rec.id, rec.toJson().toString())
            }
            sessions[rec.id] = rec
        }
        prune(now)
        mappingId = readMappingId()
        Crashes.importFiles(this)
        if (android.os.Build.VERSION.SDK_INT >= 30) ExitReasons.read(this)
        if (referrer) Referrer.start(this) else Referrer.skip(this)
        team.start()
        fetchConfig(false)
        if (s.count > 0 || sessions.values.any { it.dirty }) flush("launch")
    }

    /** The R8 mapping id the Gradle plugin writes into the app (docs/MOBILE.md §4.3), "" without it. */
    private fun readMappingId(): String = try {
        context.assets.open("net.scruter/mapping-id").use { it.readBytes().toString(Charsets.UTF_8).trim() }
            .takeIf { it.length in 1..100 } ?: ""
    } catch (e: Exception) {
        ""
    }

    /** Drops what is older than 48 hours (docs/MOBILE.md §2.1, §3.15) and sessions with nothing left to send. */
    private fun prune(now: Long) {
        val s = store ?: return
        val limit = now - MAX_AGE
        s.dropBefore(limit)
        val it = sessions.values.iterator()
        while (it.hasNext()) {
            val rec = it.next()
            if (rec !== current && (rec.start < limit || rec.ended && !rec.dirty && !s.hasItemsOf(rec.id))) {
                s.deleteSession(rec.id)
                it.remove()
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ opt-out

    /** Deletes the queue, the sessions, the daily id and the install day (docs/MOBILE.md §2.3). */
    fun wipe() {
        running = false
        handler.removeCallbacks(flushTimer)
        handler.removeCallbacks(retry)
        store?.close()
        store = null
        sessions.clear()
        current = null
        dir.deleteRecursively()
        team.forget()
    }

    /** Opted in again: a new install without install day nor install source (docs/MOBILE.md §2.3). */
    fun optIn() {
        if (store == null && !prefs.optedOut && !prefs.ignored) open(referrer = false)
    }

    // ------------------------------------------------------------------------------------------------ sessions

    /** A session starts (main thread decided it: docs/MOBILE.md §3.2). */
    fun startSession(id: String, start: Long, opening: JSONObject?) {
        val s = store ?: return
        if (!running) return
        val aa = config.samples(id)
        sampled = if (aa) id else null
        current?.let { end(it) }
        val tz = Days.zone(config.tz)
        var daily = s.get(K_DAILY)
        val until = s.get(K_DAILY_UNTIL)?.toLongOrNull() ?: 0L
        if (daily == null || start >= until) {
            daily = Text.randomHex(16)
            s.put(K_DAILY, daily)
            s.put(K_DAILY_UNTIL, Days.nextMidnight(start, tz).toString())
        }
        var install = s.get(K_INSTALL_STATE)
        if (install == null) {
            if (prefs.consumeNoInstallDay()) {
                install = "none"
            } else {
                // The install day only: never a timestamp (docs/MOBILE.md §2.1). An SDK added by an update of an
                // app installed earlier keeps that day and does not count an install.
                val installed = if (env.firstInstallTime > 0) env.firstInstallTime else start
                s.put(K_INSTALL_DAY, Days.date(installed, tz))
                install = if (start - installed < DAY) "new" else "known"
            }
            s.put(K_INSTALL_STATE, install)
        }
        val base = JSONObject()
        base.put("id", id)
        base.put("d", daily)
        base.put("st", start)
        if (install != "none") s.get(K_INSTALL_DAY)?.let { base.put("i", it) }
        base.put("n", if (install == "new") 1 else 0)
        if (install == "new") s.put(K_INSTALL_STATE, "done")
        base.put("p", "android")
        base.put("bid", env.packageName)
        base.put("av", env.versionName)
        if (env.versionCode.isNotEmpty()) base.put("ab", env.versionCode)
        base.put("bk", env.buildKind)
        base.put("tm", if (team.active) 1 else 0)
        base.put("os", env.os)
        base.put("m", env.model)
        base.put("f", env.form)
        env.language()?.let { base.put("l", it) }
        base.put("o", opening ?: JSONObject().put("k", "icon"))
        val rec = SessionRec(base)
        rec.pid = Process.myPid()
        rec.aa = aa
        rec.c.last = start
        Referrer.attach(this, rec)
        sessions[id] = rec
        current = rec
        save(rec)
        Log.d("session $id starts (${opening?.optString("k") ?: "icon"})")
    }

    private fun end(rec: SessionRec) {
        rec.c.dur = clock.durationSeconds(rec.id, rec.c.dur)
        rec.ended = true
        save(rec)
        if (current === rec) current = null
    }

    fun save(rec: SessionRec) {
        store?.putSession(rec.id, rec.toJson().toString())
    }

    fun session(id: String): SessionRec? = sessions[id]

    /** A phone that just joined the team: its running session is not counted either. */
    fun markTeamPhone() {
        current?.let {
            it.base.put("tm", 1)
            save(it)
        }
    }

    /** The last session a previous process (by its pid) was running. */
    fun sessionOfPid(pid: Int): String? = sessions.values.filter { it.pid == pid }.maxByOrNull { it.start }?.id

    /** The opening becomes known after the session started (`Scruter.openedFromNotification()`). */
    fun setOpening(id: String, opening: JSONObject) {
        val rec = sessions[id] ?: return
        if (rec.ackedQ == 0) {
            rec.base.put("o", opening)
            save(rec)
        }
    }

    /** The app goes to the background: the duration so far, the flush (docs/MOBILE.md §3.15). */
    fun background(id: String?, time: Long) {
        handler.removeCallbacks(flushTimer)
        handler.removeCallbacks(retry)
        timerAt = 0
        val rec = id?.let { sessions[it] }
        if (rec != null) {
            rec.c.dur = clock.durationSeconds(rec.id, rec.c.dur)
            rec.c.last = maxOf(rec.c.last, time)
            save(rec)
        }
        flush("background")
        if (store?.count ?: 0 > 0 || sessions.values.any { it.dirty }) FlushJob.schedule(context)
    }

    /** What a wrapper reported after the background flush (its own engagement and analysed states). */
    fun flushAfterWrapper() {
        flush("wrapper")
        if (!clock.foreground && (store?.count ?: 0 > 0 || sessions.values.any { it.dirty })) FlushJob.schedule(context)
    }

    fun foreground() {
        if (store?.count ?: 0 > 0) scheduleTimer()
        fetchConfig(false)
    }

    // ------------------------------------------------------------------------------------------------ items

    fun screen(id: String, name: String, time: Long) {
        val rec = sessions[id] ?: return
        if (!running) return
        rec.c.sv++
        if (rec.c.en == null) rec.c.en = name
        rec.c.ex = name
        rec.c.last = maxOf(rec.c.last, time)
        rec.screen = name
        rec.crumb("screen", name, time)
        val e = JSONObject().put("s", id).put("k", "screen").put("n", name).put("t", time)
        add(Store.EVENT, rec, time, e)
        Log.d("screen \"$name\"")
        if (rec.c.sv == 1 && (env.debuggable || rec.base.optInt("n") == 1)) {
            // The live installation check: 2 s after the first screen of a debug build or of the very first session.
            postDelayed(2000) { flush("first screen") }
        }
    }

    /** A wrapper that measures its own screens learns that a screen view began (docs/MOBILE.md §17). */
    fun announceScreen(id: String, name: String, time: Long) {
        val listener = options.screens ?: return
        if (!running || sessions[id] == null) return
        val limits = team.wanted(name)
        listener.screenStarted(id, name, time, sampled == id, limits != null, limits?.get(0) ?: 0, limits?.get(1) ?: 0)
    }

    fun screenEnd(id: String, name: String, time: Long, engaged: Long, depth: Int) {
        val rec = sessions[id] ?: return
        if (!running) return
        val e = JSONObject().put("s", id).put("k", "screen_end").put("n", name).put("t", time)
            .put("ms", engaged.coerceIn(0, 86_400_000)).put("sc", depth)
        add(Store.EVENT, rec, time, e)
    }

    fun event(id: String?, name: String, props: JSONObject?, revenue: Double?, currency: String?, time: Long) {
        val rec = id?.let { sessions[it] } ?: current
        if (rec == null) {
            Log.d("event \"$name\" outside a session: not sent")
            return
        }
        if (!running) return
        val e = JSONObject().put("s", rec.id).put("k", "event").put("n", name).put("t", time)
        if (props != null && props.length() > 0) e.put("p", props)
        if (revenue != null && currency != null) {
            e.put("$", JSONObject().put("a", revenue).put("c", currency))
            val minor = Math.round(revenue * Math.pow(10.0, fractionDigits(currency).toDouble()))
            if (rec.c.rev.size < 10 || rec.c.rev.containsKey(currency)) rec.c.rev[currency] = (rec.c.rev[currency] ?: 0L) + minor
        }
        rec.c.ev++
        rec.c.last = maxOf(rec.c.last, time)
        rec.crumb("event", name, time)
        add(Store.EVENT, rec, time, e)
        Log.d("event \"$name\"")
    }

    private fun fractionDigits(currency: String): Int = try {
        Currency.getInstance(currency).defaultFractionDigits.let { if (it < 0) 2 else it }
    } catch (e: IllegalArgumentException) {
        2
    }

    /** An analysed screen view's state (Advanced analytics: docs/MOBILE.md §3.6–§3.9). */
    fun analysed(id: String, item: JSONObject) {
        val rec = sessions[id] ?: return
        if (!running || !rec.aa) return
        add(Store.SCREEN_VIEW, rec, item.getLong("t"), item)
    }

    /** A crash or ANR report for [id]'s session (docs/MOBILE.md §3.10). */
    fun crash(id: String, report: JSONObject, anr: Boolean) {
        val rec = sessions[id] ?: return
        if (anr) rec.c.anr++ else if (report.optString("k") == "crash") rec.c.cr = 1
        rec.c.last = maxOf(rec.c.last, report.optLong("t"))
        save(rec)
        if (config.crashes && running) {
            store?.add(Store.CRASH, id, System.currentTimeMillis(), report.toString())
            Log.d("${report.optString("k")} report ${report.optString("id")} queued")
        }
    }

    /** A wrapper's own error (React Native, Flutter): in the current session. */
    fun currentId(): String? = current?.id

    private fun add(kind: Int, rec: SessionRec, time: Long, item: JSONObject) {
        val s = store ?: return
        save(rec)
        s.add(kind, rec.id, System.currentTimeMillis(), item.toString())
        if (s.count >= 50) flush("50 items") else scheduleTimer()
    }

    private fun scheduleTimer() {
        if (!clock.foreground || timerAt != 0L) return
        val s = store ?: return
        val oldest = s.oldestItemTime()
        val delay = if (oldest == 0L) 30_000L else (oldest + 30_000L - System.currentTimeMillis()).coerceIn(0, 30_000)
        timerAt = System.currentTimeMillis() + delay
        handler.postDelayed(flushTimer, delay)
    }

    // ------------------------------------------------------------------------------------------------ batches

    /** Sends what waits, one batch at a time, until the queue is empty or the network fails. */
    fun flush(reason: String) {
        if (sending || store == null || !running && store?.inflight() == null) return
        sending = true
        try {
            var batches = 0
            while (batches < 20) {
                val r = sendOne(reason) ?: break
                batches++
                if (!r) break
            }
        } finally {
            sending = false
        }
    }

    /** `true` sent (go on), `false` failed (retry later), `null` nothing to send. */
    private fun sendOne(reason: String): Boolean? {
        val s = store ?: return null
        val now = System.currentTimeMillis()
        prune(now)
        var f = s.inflight()
        if (f != null && f.created < now - MAX_AGE) {
            s.clearInflight()
            f = null
        }
        if (f == null) {
            if (!running) return null
            f = Batches.build(this, s, sessions, now) ?: return null
            s.putInflight(f)
        }
        val o = JSONObject(f.body)
        o.put("t", now)
        o.put("ce", config.etag)
        val raw = o.toString().toByteArray(Charsets.UTF_8)
        val gz = raw.size > 1024
        val headers = if (gz) mapOf("Content-Encoding" to "gzip") else emptyMap()
        Log.d("batch ${o.optString("b")} ($reason): ${o.optJSONArray("s")?.length() ?: 0} sessions, " +
            "${o.optJSONArray("e")?.length() ?: 0} events, ${o.optJSONArray("x")?.length() ?: 0} analysed views, " +
            "${o.optJSONArray("cr")?.length() ?: 0} crash reports, ${raw.size} bytes")
        val res = Net.send("POST", "${options.endpoint}/m/v1/batch", if (gz) Net.gzip(raw) else raw, "application/json", headers)
        return when {
            res.ok -> {
                commit(s, f)
                attempts = 0
                answer(res.body)
                true
            }
            res.code == -1 || res.code == 408 || res.code == 429 || res.code >= 500 -> {
                backoff(res.retryAfter)
                false
            }
            else -> {
                // docs/MOBILE.md §3.15: any other 4xx drops the batch; the sessions keep their acknowledged state.
                Log.d("batch refused (${res.code}): dropped. ${res.body.take(200)}")
                s.deleteItems(ids(f.items))
                s.clearInflight()
                true
            }
        }
    }

    private fun ids(text: String): List<Long> = if (text.isEmpty()) emptyList() else text.split(',').map { it.toLong() }

    private fun commit(s: Store, f: Store.Inflight) {
        val states = JSONObject(f.states)
        for (id in states.keys()) {
            val st = states.getJSONObject(id)
            val rec = sessions[id] ?: continue
            rec.ackedQ = st.getInt("q")
            rec.acked = State.from(st.getJSONObject("c"))
            if (st.optBoolean("ins")) rec.ins = null
            save(rec)
        }
        s.deleteItems(ids(f.items))
        s.clearInflight()
    }

    private fun answer(body: String) {
        val o = try {
            JSONObject(body.ifEmpty { "{}" })
        } catch (e: Exception) {
            return
        }
        o.optJSONArray("w")?.let { w -> for (i in 0 until w.length()) Log.d("server warning: ${w.optString(i)}") }
        if (o.optInt("r") == 1) fetchConfig(true)
    }

    /** 5 s × 2ⁿ ± 20 %, at most 10 minutes, honouring `Retry-After`; timers only in the foreground. */
    private fun backoff(retryAfter: Long) {
        val delay = delayFor(attempts++, retryAfter)
        Log.d("batch not sent: retry in ${delay / 1000} s")
        handler.removeCallbacks(retry)
        if (clock.foreground) handler.postDelayed(retry, delay)
    }

    // ------------------------------------------------------------------------------------------------ configuration

    fun fetchConfig(force: Boolean) {
        val s = store ?: return
        val at = s.get(K_CONFIG_AT)?.toLongOrNull() ?: 0L
        val now = System.currentTimeMillis()
        if (configFetching || !force && config.json.isNotEmpty() && now - at < config.ttl * 1000L) return
        configFetching = true
        try {
            val url = "${options.endpoint}/m/v1/config?a=${options.appId}&p=android&av=${enc(env.versionName)}" +
                "&sv=${enc(BuildConfig.SDK_VERSION)}"
            val tag = s.get(K_CONFIG_TAG)
            val headers = if (tag != null && config.json.isNotEmpty()) mapOf("If-None-Match" to tag) else emptyMap()
            val res = Net.send("GET", url, headers = headers)
            when {
                res.code == 304 -> s.put(K_CONFIG_AT, now.toString())
                res.ok -> Config.parse(res.body)?.let {
                    s.put(K_CONFIG_TAG, res.etag)
                    apply(it, now)
                }
                else -> Log.d("configuration not fetched (${res.code})")
            }
        } finally {
            configFetching = false
        }
    }

    private fun apply(c: Config, now: Long) {
        val s = store ?: return
        s.put(K_CONFIG, c.json)
        s.put(K_CONFIG_AT, now.toString())
        config = c
        Log.d("configuration ${c.etag}: on=${c.on} aa=${c.aa} cr=${c.crashes} tp=${c.teamImages}")
        if (!c.on) {
            // "Send nothing, keep nothing": the queue and the sessions go; the configuration stays to ask again.
            running = false
            s.clearInflight()
            for (id in ArrayList(sessions.keys)) s.deleteSession(id)
            sessions.clear()
            current = null
        } else {
            running = true
            team.configChanged()
        }
    }

    private fun enc(v: String): String = java.net.URLEncoder.encode(v, "UTF-8")

    fun isMainThread(): Boolean = Looper.myLooper() == Looper.getMainLooper()

    fun elapsed(): Long = SystemClock.elapsedRealtime()

    companion object {
        const val MAX_AGE = 48L * 3600 * 1000
        const val DAY = 24L * 3600 * 1000
        const val K_CONFIG = "config"
        const val K_CONFIG_AT = "config_at"
        const val K_CONFIG_TAG = "config_tag"
        const val K_DAILY = "daily"
        const val K_DAILY_UNTIL = "daily_until"
        const val K_INSTALL_DAY = "install_day"
        const val K_INSTALL_STATE = "install_state"

        /** The retry delay of attempt [n] (0-based): 5 s × 2ⁿ ± 20 % jitter, ≤ 10 minutes, or `Retry-After`. */
        fun delayFor(n: Int, retryAfter: Long): Long {
            val base = minOf(5_000L shl minOf(n, 7), 600_000L)
            val jittered = (base * (0.8 + 0.4 * Text.randomDouble())).toLong().coerceAtMost(600_000L)
            return maxOf(jittered, retryAfter)
        }
    }
}
