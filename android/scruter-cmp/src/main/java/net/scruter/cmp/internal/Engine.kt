package net.scruter.cmp.internal

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import net.scruter.cmp.ConsentChoice
import net.scruter.cmp.ConsentListener
import net.scruter.cmp.ConsentState
import net.scruter.cmp.Presentation
import net.scruter.cmp.Subscription
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

internal class Options(val appId: String, val presentation: Presentation, val endpoint: String, val sdkVersion: String)

/**
 * What [ConsentState], `isGranted` and the listeners read: replaced as a whole, read from any thread without a lock.
 */
internal class Snap(
    val state: ConsentState,
    val stored: Stored?,
    val granted: Set<String>,
    /** Every purpose of the configuration, in order, and those always on. */
    val purposes: List<String>,
    val required: Set<String>,
    /** Google signal → purpose. */
    val gcm: Map<String, String>,
) {
    fun choice(): ConsentChoice? {
        val s = stored ?: return null
        if (state != ConsentState.READY) return null
        val m = LinkedHashMap<String, Boolean>()
        for (p in purposes) m[p] = p in required || p in granted
        return ConsentChoice(s.id, s.at * 1000, m)
    }

    fun answers(): Map<String, Boolean> {
        val m = LinkedHashMap<String, Boolean>()
        for (p in purposes) m[p] = p in required || p in granted
        return m
    }

    companion object {
        /** The default map of the console (`consent-mode.json`): used when the banner has no Consent Mode. */
        val DEFAULT_GCM = mapOf(
            "ad_storage" to "advertising",
            "ad_user_data" to "advertising",
            "ad_personalization" to "advertising",
            "analytics_storage" to "analytics",
            "personalization_storage" to "personalization",
        )

        fun of(stored: Stored?, rules: Rules?, gcm: Map<String, String>?, nowSeconds: Long): Snap {
            if (rules == null) return Snap(ConsentState.UNAVAILABLE, stored, emptySet(), emptyList(), emptySet(), gcm ?: DEFAULT_GCM)
            val purposes = rules.purposes.map { it.key }
            val required = rules.purposes.filter { it.required }.map { it.key }.toSet()
            val optional = rules.purposes.filter { !it.required }.map { it.key }.toSet()
            val ask = rules.mustAsk(stored, nowSeconds)
            val granted = when {
                stored == null -> emptySet()
                !ask -> stored.granted.filter { it in optional }.toSet()
                else -> rules.keptGrants(stored)
            }
            return Snap(if (ask) ConsentState.NEEDS_DECISION else ConsentState.READY, stored, granted, purposes, required, gcm ?: DEFAULT_GCM)
        }
    }
}

/**
 * The CMP's engine (docs/CMP-MOBILE.md §3): the stored choice and its state on the main thread (one storage read at
 * start), everything else (configuration, texts, media, the queue of beacons, the detected SDKs) on one worker thread.
 */
internal class Engine(val app: Application, val options: Options) {
    val main = Handler(Looper.getMainLooper())
    private val thread = HandlerThread("ScruterCMP", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
    val handler = Handler(thread.looper)

    /** The app's own storage of the choice (M5): `choice` (format 1) and `rules` (what the re-ask rules read). */
    private val prefs: SharedPreferences = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Volatile
    var snap: Snap

    /** Set on the main thread by [ScruterCMP.setLanguage]. */
    @Volatile
    var language: String? = null

    @Volatile
    var forceShow: Boolean = false

    // ---- Worker thread ----
    private lateinit var env: Env
    private lateinit var dir: File
    private lateinit var queue: Queue
    private lateinit var media: Media
    /** The IAB TCF (§6): its keys, strings and layers. */
    lateinit var tcf: TcfState
        private set
    private var state = JSONObject()
    private var stored: Stored?

    @Volatile
    var config: AppConfig? = null
        private set
    private var fetchedAt = 0L
    private var etag: String? = null
    private var fetching = false
    private var attempts = 0
    private var configAttempts = 0
    private var ready = false
    private val retry = Runnable { flush() }
    private val refetch = Runnable { fetchConfig(force = true) }

    // ---- Main thread ----
    val ui = UiHost(this)
    private val readyListeners = ArrayList<ConsentListener>()
    private val changeListeners = ArrayList<ConsentListener>()
    private var started = 0
    private var backgroundAt = 0L
    var foreground = false
        private set
    var opening: Opening? = null
        private set

    /** One opening of the app (M9): a cold start, or a return after 30 minutes in the background. */
    class Opening(val index: Int) {
        var variant: String? = null
        var drawn = false
        var displayed = false
        var hitSent = false
    }

    private var openings = 0

    init {
        stored = Stored.parse(prefs.getString(K_CHOICE, null))
        val rules = Rules.decode(prefs.getString(K_RULES, null))
        snap = Snap.of(stored, rules, null, now() / 1000)
        Log.d("start: ${snap.state}, choice ${stored?.id ?: "none"}")
        handler.post { init() }
    }

    // ------------------------------------------------------------------------------------------------ worker: start

    private fun init() {
        env = Env(app, options.sdkVersion)
        Net.userAgent = "Scruter-CMP-Android/${options.sdkVersion}"
        dir = File(app.noBackupFilesDir, "scruter-cmp").apply { mkdirs() }
        queue = Queue(File(dir, "queue.json"))
        media = Media(File(dir, "media")) { origins() }
        // The IAB keys in the default SharedPreferences, where ad SDKs read them (docs/CMP-MOBILE.md §6).
        tcf = TcfState(app.getSharedPreferences(app.packageName + "_preferences", Context.MODE_PRIVATE), prefs, dir)
        state = try {
            JSONObject(File(dir, "state.json").readText())
        } catch (e: Exception) {
            JSONObject()
        }
        try {
            val text = File(dir, "config.json").takeIf { it.isFile }?.readText()
            val meta = File(dir, "config.meta").takeIf { it.isFile }?.readText()?.split('\n')
            if (text != null) {
                AppConfig.parse(text)?.let { c ->
                    config = c
                    fetchedAt = meta?.getOrNull(0)?.toLongOrNull() ?: 0L
                    etag = meta?.getOrNull(1)?.ifEmpty { null }
                    Log.d("cached configuration: on=${c.on} rev ${c.cmp?.configRev}")
                }
            }
        } catch (e: Exception) {
            Log.w("cached configuration unreadable", e)
        }
        ready = true
        countLaunch()
        if (config != null) tcf.configure(config?.cmp)
        recompute("start")
        watchNetwork()
        fetchConfig(force = false)
        afterConfig()
        flush()
    }

    private fun origins(): List<String> {
        val c = config?.cmp?.endpoint
        return listOfNotNull(validEndpoint(c), validEndpoint(options.endpoint))
    }

    /** Where the beacons and texts go: the configuration's endpoint when valid, else the SDK's. */
    private fun endpoint(): String = validEndpoint(config?.cmp?.endpoint) ?: options.endpoint

    private fun now(): Long = System.currentTimeMillis()

    // ------------------------------------------------------------------------------------------------ worker: configuration

    fun fetchConfig(force: Boolean) {
        if (!ready || fetching) return
        val c = config
        val ttl = (c?.ttl ?: 0L) * 1000
        if (!force && c != null && now() - fetchedAt < ttl) return
        fetching = true
        try {
            val url = "${options.endpoint}/m/v1/cmp?a=${Net.enc(options.appId)}&p=android&av=${Net.enc(env.versionName)}" +
                "&sv=${Net.enc(options.sdkVersion)}"
            val headers = if (etag != null && c != null) mapOf("If-None-Match" to etag!!) else emptyMap()
            val res = Net.send("GET", url, headers = headers)
            when {
                res.code == 304 && c != null -> {
                    fetchedAt = now()
                    saveMeta()
                    configAttempts = 0
                    Log.d("configuration unchanged")
                }
                res.ok -> {
                    val parsed = AppConfig.parse(res.body)
                    if (parsed == null) {
                        Log.w("configuration refused: not a configuration of this protocol")
                    } else {
                        configAttempts = 0
                        File(dir, "config.json").writeText(res.body)
                        fetchedAt = now()
                        etag = res.etag
                        saveMeta()
                        val changed = c == null || c.cmp?.configRev != parsed.cmp?.configRev || c.on != parsed.on ||
                            c.cmp?.banner != parsed.cmp?.banner || c.cmp?.abTest?.banner != parsed.cmp?.abTest?.banner
                        config = parsed
                        Log.d("configuration: on=${parsed.on} rev ${parsed.cmp?.configRev} banner ${parsed.cmp?.banner}")
                        if (changed) {
                            tcf.configure(parsed.cmp)
                            recompute("configuration")
                            afterConfig()
                        }
                    }
                }
                else -> {
                    Log.d("configuration not fetched (${res.code})")
                    if (foreground && (config == null || res.code == 429 || res.code >= 500 || res.code == -1)) {
                        val delay = Queue.delayFor(configAttempts++, res.retryAfter, Math.random())
                        handler.removeCallbacks(refetch)
                        handler.postDelayed(refetch, delay)
                    }
                }
            }
        } finally {
            fetching = false
        }
    }

    private fun saveMeta() {
        File(dir, "config.meta").writeText("$fetchedAt\n${etag ?: ""}")
    }

    /** What follows a new configuration: the rules beside the choice, the pending proof, the media, the SDK report. */
    private fun afterConfig() {
        val c = config ?: return
        val cmp = c.cmp
        val rules = cmp?.rules?.encode()
        if (rules != prefs.getString(K_RULES, null)) {
            val e = prefs.edit()
            if (rules == null) e.remove(K_RULES) else e.putString(K_RULES, rules)
            e.commit()
        }
        if (cmp == null) return
        resendPending(cmp)
        reportSdks(c)
        val urls = ArrayList<String>()
        for (u in listOfNotNull(cmp.ui, cmp.abTest?.ui)) {
            u.hero?.let { h -> h.poster.forEach { urls.add(it.url) }; h.videos.forEach { urls.add(it.url) } }
            u.logoUrl?.let { urls.add(it) }
        }
        c.icon?.let { urls.add(it) }
        media.keepOnly(urls)
        main.post { ui.configChanged() }
    }

    // ------------------------------------------------------------------------------------------------ state

    /** Computes the state from the stored choice and the configuration at hand, and tells the main thread. */
    private fun recompute(reason: String) {
        val c = config
        val rules = if (c == null) Rules.decode(prefs.getString(K_RULES, null)) else c.cmp?.rules
        val gcm = c?.cmp?.gcm
        var next = Snap.of(stored, rules, gcm, now() / 1000)
        if (ready && rules != null) {
            val s = stored
            if (s == null || now() / 1000 - s.at > Rules.renewSeconds(rules.renewMonths)) {
                // No choice, or an expired one: vendors read no decision until the next one.
                tcf.clearDecision()
            } else if (next.state == ConsentState.READY && tcf.mustAsk()) {
                // docs/CMP.md §4.4 rule 5: the previous answers hold until the new decision (§3.8).
                next = Snap(ConsentState.NEEDS_DECISION, next.stored, next.granted, next.purposes, next.required, next.gcm)
            }
        }
        val before = snap
        snap = next
        if (before.state != next.state || before.granted != next.granted || before.stored != next.stored) {
            Log.d("state ($reason): ${next.state}, granted ${next.granted.sorted()}")
        }
        main.post { published(before, next) }
    }

    /**
     * Main thread: the listeners (`whenReady` once a valid choice exists, `onChange` whenever a valid choice appears or
     * changes: a decision, the preferences, a withdrawal, a re-ask answered), then the sheet when a decision is needed.
     */
    private fun published(before: Snap, next: Snap) {
        val choice = next.choice()
        if (choice != null) {
            if (readyListeners.isNotEmpty()) {
                val l = ArrayList(readyListeners)
                readyListeners.clear()
                for (x in l) call(x, choice)
            }
            val changed = before.state != ConsentState.READY || before.stored?.id != next.stored?.id ||
                before.stored?.at != next.stored?.at || before.granted != next.granted
            if (changed) for (x in ArrayList(changeListeners)) call(x, choice)
        }
        net.scruter.cmp.bridge.ScruterCMPBridge.changed(next)
        ui.stateChanged()
        maybeHit()
    }

    private fun call(l: ConsentListener, c: ConsentChoice) {
        try {
            l.onConsent(c)
        } catch (e: RuntimeException) {
            Log.w("a listener of the app threw", e)
        }
    }

    fun whenReady(l: ConsentListener): Subscription {
        onMain {
            val c = snap.choice()
            if (c != null) call(l, c) else readyListeners.add(l)
        }
        return Subscription { onMain { readyListeners.remove(l) } }
    }

    fun onChange(l: ConsentListener): Subscription {
        onMain { changeListeners.add(l) }
        return Subscription { onMain { changeListeners.remove(l) } }
    }

    fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    // ------------------------------------------------------------------------------------------------ decisions

    /**
     * A decision from the sheet (docs/CMP-MOBILE.md §3.3): written to the app's storage on the worker (committed
     * before the sheet closes, [done] runs on the main thread after the write), then its proof is queued.
     */
    fun decide(model: SheetModel, action: String?, source: String, map: Map<String, Boolean>, shownAt: Long, tcfChoice: TcfChoice?, done: () -> Unit) {
        val before = snap
        handler.post {
            val c = model.cmp
            val granted = ArrayList<String>()
            val denied = ArrayList<String>()
            for (p in c.purposes) {
                if (p.required) continue
                if (map[p.key] == true) granted.add(p.key) else denied.add(p.key)
            }
            var a = action ?: when {
                granted.isEmpty() -> "reject_all"
                denied.isEmpty() -> "accept_all"
                else -> "custom"
            }
            // Every optional purpose refused after at least one had been granted: a withdrawal (docs/CMP.md §6.1).
            val had = before.state == ConsentState.READY && before.granted.isNotEmpty()
            if (granted.isEmpty() && had) a = "withdraw"
            val s = Stored(stored?.id ?: Stored.newConsentId(), now() / 1000, c.consentRev, model.banner, granted, Stored.Pending(a, source))
            stored = s
            prefs.edit().putString(K_CHOICE, s.serialize()).commit()
            // The TC string and the IAB keys, before the sheet closes.
            tcf.decide(granted.toSet(), tcfChoice, c, model.lang, now())
            Log.d("decision: $a from $source, granted $granted, refused $denied (consent id ${s.id})")
            recompute("decision")
            main.post(done)
            val ms = if (shownAt > 0 && source != "preferences") SystemClock.elapsedRealtime() - shownAt else 0L
            prove(s, model.ui, model.lang, model.hash, model.variant, c, ms)
            flush()
        }
    }

    private fun proof(s: Stored, lang: String, hash: String, variant: String?, c: CmpConfig, ms: Long): JSONObject? {
        val p = s.pending ?: return null
        val g = s.granted.toSet()
        val body = JSONObject()
            .put("s", c.site)
            .put("i", s.id)
            .put("b", s.banner)
            .put("c", p.action)
            .put("o", if (p.source == "floating_button") "preferences" else p.source)
            .put("l", lang)
            .put("h", hash)
            .put("g", JSONArray(s.granted))
            .put("n", JSONArray(c.purposes.filter { !it.required && it.key !in g }.map { it.key }))
        c.gcm?.let { m -> body.put("m", JSONArray(ConsentMode.granted(m, c.purposes.associate { it.key to (it.required || it.key in g) }))) }
        body.put("r", s.rev)
            .put("w", width())
            .put("ms", ms.coerceIn(0, 86_400_000))
        if (variant != null && c.abTest != null) body.put("t", c.abTest.id).put("a", variant)
        tcf.proofFields()?.let { (tc, gv) -> body.put("tc", tc).put("gv", gv) }
        beaconFields(body)
        return body
    }

    private fun prove(s: Stored, ui: UiConfig, lang: String, hash: String?, variant: String?, c: CmpConfig, ms: Long) {
        val h = hash ?: ui.textHashes[lang] ?: pack(c, s.banner, lang)?.hash
        if (h == null) {
            Log.w("proof waits: the texts' hash of \"$lang\" is not at hand")
            return
        }
        val body = proof(s, lang, h, variant, c, ms) ?: return
        queue.add(Queue.CONSENT, "/cmp/consent", body, now(), ref(s))
    }

    private fun ref(s: Stored) = "consent:${s.id}:${s.at}"

    /** A proof not acknowledged at a previous launch (process death, no network) is sent again (docs/CMP.md §4.12). */
    private fun resendPending(c: CmpConfig) {
        val s = stored ?: return
        if (s.pending == null || queue.has(ref(s))) return
        val isB = c.abTest != null && s.banner == c.abTest.banner
        if (s.banner != c.banner && !isB) {
            // Its banner version is gone: nothing can carry the proof any more.
            acknowledged(s)
            return
        }
        val ui = if (isB) c.abTest!!.ui else c.ui
        val drawn = drawnTexts(c, ui, s.banner) ?: return
        val kept = s.copy(granted = s.granted.filter { k -> c.purposes.any { !it.required && it.key == k } })
        Log.d("resending the proof of ${s.id}")
        prove(kept, ui, drawn.lang, drawn.hash, if (c.abTest != null) (if (isB) "b" else "a") else null, c, 0)
    }

    private fun acknowledged(s: Stored) {
        val cur = stored ?: return
        if (cur.id == s.id && cur.at == s.at && cur.pending != null) {
            val next = cur.copy(pending = null)
            stored = next
            prefs.edit().putString(K_CHOICE, next.serialize()).commit()
            Log.d("proof acknowledged: ${s.id}")
            snap = Snap(snap.state, next, snap.granted, snap.purposes, snap.required, snap.gcm)
        }
    }

    fun debugReset() {
        handler.post {
            stored = null
            prefs.edit().remove(K_CHOICE).commit()
            state.remove(K_LAUNCHES)
            state.remove(K_PREFERENCES_CALLED)
            saveState()
            queue.all().filter { it.kind == Queue.CONSENT }.forEach { queue.remove(it.id) }
            tcf.reset(config?.cmp)
            Log.d("debugReset: the choice is forgotten")
            recompute("debugReset")
        }
    }

    // ------------------------------------------------------------------------------------------------ hits

    /** The fields every beacon from an app carries (docs/CMP-MOBILE.md §4.2). */
    private fun beaconFields(body: JSONObject) {
        body.put("cv", env.sdk).put("p", "android").put("ap", env.packageName).put("av", env.versionName)
        if (env.debuggable) body.put("dbg", 1)
    }

    fun width(): Int = app.resources.configuration.smallestScreenWidthDp.coerceIn(0, 10_000)

    /**
     * Main thread: one `POST /cmp/hit` per opening (M9), once it is known whether the sheet shows (`d = 1` when it
     * did); at the latest when the app leaves the foreground.
     */
    fun maybeHit(leaving: Boolean = false) {
        val o = opening ?: return
        if (o.hitSent) return
        val c = config?.cmp ?: return
        val s = snap
        val settled = o.displayed || leaving || s.state == ConsentState.READY && !forceShow
        if (!settled) return
        o.hitSent = true
        val variant = o.variant ?: drawVariant(c).also { o.variant = it }
        val displayed = o.displayed
        handler.post {
            val ui = if (variant == "b" && c.abTest != null) c.abTest.ui else c.ui
            val body = JSONObject()
                .put("s", c.site)
                .put("b", if (variant == "b" && c.abTest != null) c.abTest.banner else c.banner)
            if (variant != null && c.abTest != null) body.put("t", c.abTest.id).put("a", variant)
            body.put("l", drawnTexts(c, ui, body.getLong("b"))?.lang ?: ui.defaultLanguage).put("d", if (displayed) 1 else 0).put("w", width()).put("e", 0)
            beaconFields(body)
            Log.d("hit: d=${if (displayed) 1 else 0}")
            queue.add(Queue.HIT, "/cmp/hit", body, now())
            flush()
        }
    }

    /** The A/B variant of an opening, drawn as the site script draws it: B when a random 0–99 is under `split_b`. */
    fun drawVariant(c: CmpConfig): String? {
        val ab = c.abTest ?: return null
        return if (java.security.SecureRandom().nextInt(100) < ab.splitB) "b" else "a"
    }

    // ------------------------------------------------------------------------------------------------ lifecycle (main)

    fun activityStarted() {
        started++
        if (started == 1) {
            foreground = true
            val now = SystemClock.elapsedRealtime()
            if (opening == null || backgroundAt > 0 && now - backgroundAt >= OPENING_GAP) {
                opening = Opening(++openings)
                Log.d("opening ${openings}")
            }
            backgroundAt = 0
            handler.post {
                if (!ready) return@post
                recompute("foreground")
                fetchConfig(force = false)
                flush()
            }
        }
    }

    fun activityStopped(a: Activity) {
        if (started > 0) started--
        if (started == 0 && !a.isChangingConfigurations) {
            foreground = false
            backgroundAt = SystemClock.elapsedRealtime()
            maybeHit(leaving = true)
            handler.post { handler.removeCallbacks(retry); handler.removeCallbacks(refetch) }
        }
    }

    fun displayed() {
        val o = opening ?: return
        o.displayed = true
        maybeHit()
    }

    private fun watchNetwork() {
        try {
            val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    handler.post {
                        if (config == null || config?.on == false) fetchConfig(force = true)
                        attempts = 0
                        flush()
                    }
                }
            })
        } catch (e: RuntimeException) {
            // No ACCESS_NETWORK_STATE (removed by the app's manifest): the next foreground tries again.
            Log.d("network changes not watched: ${e.javaClass.simpleName}")
        }
    }

    // ------------------------------------------------------------------------------------------------ queue

    fun flush() {
        if (!ready) return
        handler.removeCallbacks(retry)
        queue.dropBefore(now() - Queue.MAX_AGE)
        val base = endpoint()
        for (item in queue.all()) {
            val res = Net.send("POST", base + item.path, item.body.toByteArray(Charsets.UTF_8))
            when {
                res.ok -> {
                    queue.remove(item.id)
                    attempts = 0
                    sent(item)
                }
                res.code == -1 || res.code == 408 || res.code == 429 || res.code >= 500 -> {
                    val delay = Queue.delayFor(attempts++, res.retryAfter, Math.random())
                    Log.d("${item.kind} not sent (${res.code}): retry in ${delay / 1000} s")
                    if (foreground) handler.postDelayed(retry, delay)
                    return
                }
                else -> {
                    Log.w("${item.kind} refused (${res.code}): dropped. ${res.body.take(200)}")
                    queue.remove(item.id)
                    sent(item)
                }
            }
        }
    }

    private fun sent(item: Queue.Item) {
        val ref = item.ref ?: return
        when {
            ref.startsWith("consent:") -> {
                val s = stored ?: return
                if (ref == ref(s)) acknowledged(s)
            }
            ref.startsWith("sdks:") -> {
                state.put(K_SDKS, ref.removePrefix("sdks:"))
                saveState()
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ texts

    /** The banner's language for this device (an explicit language first, then the device's languages). */
    fun pickLanguage(ui: UiConfig): String {
        val prefs = ArrayList<String?>()
        prefs.add(language)
        val list = app.resources.configuration.locales
        for (i in 0 until list.size()) prefs.add(list[i].toLanguageTag())
        prefs.add(Locale.getDefault().toLanguageTag())
        return Lang.pick(ui.languages, ui.defaultLanguage, prefs, ui.aliases)
    }

    /** A language of a version that is not inlined: `GET /cmp/{code}/texts-{banner}-{lang}.json`, cached (immutable). */
    private fun pack(c: CmpConfig, banner: Long, lang: String): LanguagePack? {
        val f = File(dir, "texts/$banner-$lang.json")
        if (f.isFile) LanguagePack.parse(f.readText())?.let { return it }
        // The site script's budget: the visitor's language within about 1.5 s, else the inlined one.
        val res = Net.send("GET", "${endpoint()}/cmp/${Net.enc(c.site)}/texts-$banner-${Net.enc(lang)}.json", timeout = 1_000)
        if (!res.ok) return null
        val p = LanguagePack.parse(res.body) ?: return null
        if (p.lang != lang) return null
        f.parentFile?.mkdirs()
        f.writeText(res.body)
        return p
    }

    class Drawn(val lang: String, val texts: Texts, val hash: String?, val rtl: Boolean)

    /**
     * The texts a display draws: the device's language when the banner speaks it (inlined, else its frozen pack), else
     * the inlined default language (the site script's rule: the pack could not arrive).
     */
    private fun drawnTexts(c: CmpConfig, ui: UiConfig, banner: Long): Drawn? {
        val lang = pickLanguage(ui)
        ui.texts[lang]?.let { return Drawn(lang, it, ui.textHashes[lang], lang in ui.rtl) }
        pack(c, banner, lang)?.let { return Drawn(lang, it.texts, it.hash, it.rtl || lang in ui.rtl) }
        val d = ui.defaultLanguage
        return ui.texts[d]?.let { Drawn(d, it, ui.textHashes[d], d in ui.rtl) }
    }

    /**
     * Worker: what one display draws (texts of the visitor's language, the words, the poster and the icon decoded at
     * the sheet's size). Null without a configuration.
     */
    fun prepare(kind: SheetModel.Kind, variant: String?, widthDp: Int, density: Float, phone: Boolean): SheetModel? {
        val conf = config ?: return null
        val c = conf.cmp ?: return null
        val b = variant == "b" && c.abTest != null
        val ui = if (b) c.abTest!!.ui else c.ui
        val banner = if (b) c.abTest!!.banner else c.banner
        val drawn = drawnTexts(c, ui, banner) ?: return null
        val lang = drawn.lang
        var texts = drawn.texts
        val hash = drawn.hash
        val rtl = drawn.rtl
        var words = Words.load(app, lang)
        if (lang.substringBefore('-') == "fr") {
            texts = texts.mapped(Lang::frenchSpacing)
            words = words.mapped(Lang::frenchSpacing)
        }
        val widthPx = (widthDp * density).toInt()
        val hero = ui.hero
        var poster: android.graphics.Bitmap? = null
        var videoUrl: String? = null
        var videoFile: File? = null
        if (hero != null && !(phone && hero.hideOnPhone)) {
            Media.poster(hero.poster, widthPx)?.let { src -> media.file(src.url, MAX_IMAGE)?.let { poster = media.decode(it, widthPx) } }
            if (hero.video) Media.video(hero.videos, widthPx)?.let { v ->
                videoUrl = v.url
                videoFile = media.cached(v.url)
            }
        }
        val iconUrl = when (ui.logoMode) {
            "none" -> null
            "custom" -> ui.logoUrl
            else -> conf.icon ?: ui.logoUrl
        }
        val icon = iconUrl?.let { u -> media.file(u, MAX_IMAGE)?.let { media.decode(it, (56 * density).toInt()) } }
        val s = snap
        // The TCF layers: the vendor list and IAB's texts in the drawn language (without them, the standard layers).
        val tcfSheet = if (!tcf.on) null else tcf.sheetList(lang)?.let { l ->
            TcfSheet.build(
                tcf.settings!!, l, c.purposes, c.purposes.associate { it.key to texts.name(it.key) }, words, lang,
                if (s.stored != null) tcf.storedChoice() else null, c.renewMonths,
            )
        }
        return SheetModel(
            kind, c, ui, banner, if (c.abTest != null) (if (b) "b" else "a") else null, lang, rtl, texts, hash, words,
            conf.policyUrl ?: texts.policyUrl, poster, icon, ui.logoMode != "custom", videoUrl, videoFile,
            s.granted, s.stored?.id, (s.stored?.at ?: 0L) * 1000, tcfSheet,
        )
    }

    /** Worker: the video loop's file, requested once the sheet's first frame is drawn. */
    fun video(url: String): File? = media.file(url, MAX_VIDEO)

    // ------------------------------------------------------------------------------------------------ detected SDKs

    /**
     * Once per (app version, catalogue version), the catalogue's classes looked up without initialising them, and the
     * keys found posted (docs/CMP-MOBILE.md §3.14). Nothing else of the app is read.
     */
    private fun reportSdks(c: AppConfig) {
        val version = c.sdkCatalogue
        if (version <= 0 || c.cmp == null) return
        val key = "${env.versionName}|$version"
        if (state.optString(K_SDKS) == key || queue.has("sdks:$key")) return
        val f = File(dir, "sdks-$version.json")
        val text = if (f.isFile) f.readText() else {
            val res = Net.send("GET", "${endpoint()}/m/v1/cmp/sdks/$version.json")
            if (!res.ok) return
            f.writeText(res.body)
            dir.listFiles()?.forEach { if (it.name.startsWith("sdks-") && it.name != f.name) it.delete() }
            res.body
        }
        val found = Sdks.detect(text, app.classLoader) ?: return
        val body = JSONObject().put("a", options.appId).put("p", "android").put("av", env.versionName).put("c", version)
            .put("k", JSONArray(found))
        Log.d("detected SDKs (catalogue $version): ${found.joinToString()}")
        queue.add(Queue.SDKS, "/m/v1/cmp/sdks", body, now(), "sdks:$key")
    }

    // ------------------------------------------------------------------------------------------------ debug warning

    private fun countLaunch() {
        if (!env.debuggable) return
        if (stored == null || state.optBoolean(K_PREFERENCES_CALLED)) return
        val n = state.optInt(K_LAUNCHES) + 1
        state.put(K_LAUNCHES, n)
        saveState()
        if (n >= 10) {
            android.util.Log.w(
                "ScruterCMP",
                "showPreferences() was never called during $n launches since the visitor's decision. Give the app a " +
                    "settings entry (\"Privacy choices\") that calls ScruterCMP.showPreferences(activity): it is how a " +
                    "visitor withdraws consent (docs: CMP.md, \"The settings entry first\").",
            )
        }
    }

    fun preferencesCalled() {
        handler.post {
            if (!ready || state.optBoolean(K_PREFERENCES_CALLED)) return@post
            state.put(K_PREFERENCES_CALLED, true)
            saveState()
        }
    }

    private fun saveState() {
        try {
            File(dir, "state.json").writeText(state.toString())
        } catch (e: java.io.IOException) {
            Log.w("state not saved", e)
        }
    }

    fun post(block: () -> Unit) {
        handler.post(block)
    }

    /** Tests: stops the worker after what it has. */
    fun stop() {
        thread.quitSafely()
    }

    companion object {
        const val PREFS = "net.scruter.cmp"
        const val K_CHOICE = "choice"
        const val K_RULES = "rules"
        const val K_SDKS = "sdks"
        const val K_LAUNCHES = "launches"
        const val K_PREFERENCES_CALLED = "preferences"
        const val OPENING_GAP = 30L * 60 * 1000
        const val MAX_IMAGE = 2L * 1024 * 1024
        const val MAX_VIDEO = 20L * 1024 * 1024

        fun validEndpoint(e: String?): String? {
            if (e.isNullOrEmpty()) return null
            val ok = Regex("^(https://[a-z0-9.-]+|http://(localhost|127\\.0\\.0\\.1|10\\.0\\.2\\.2|[a-z0-9.-]+\\.localhost))(:\\d+)?(/[\\w.~-]+)*$", RegexOption.IGNORE_CASE)
            return if (ok.matches(e)) e.trimEnd('/') else null
        }
    }
}
