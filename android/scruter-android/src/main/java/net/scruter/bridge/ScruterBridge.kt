package net.scruter.bridge

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import net.scruter.Scruter
import net.scruter.internal.BridgeState
import net.scruter.internal.Crashes
import net.scruter.internal.Log
import net.scruter.internal.Options
import net.scruter.internal.Text
import org.json.JSONArray
import org.json.JSONObject

/**
 * The entry points of Scruter's own wrapper SDKs (React Native, Flutter), which embed this one: an app calls
 * [Scruter], never this. Stable within a major version of the Android SDK.
 */
public object ScruterBridge {
    /**
     * Starts the SDK for a wrapper: [sdk] names it in batches (`react_native/1.0.0`, `flutter/1.0.0`); without
     * [automaticScreens], activities and fragments are not counted (the wrapper names its routes). [activity] is the
     * activity already running when the wrapper starts late. With [screens], the wrapper's toolkit draws its own
     * widgets (Flutter): the SDK sees one surface, so it measures nothing on screen and tells [screens] when a screen
     * view begins; the wrapper reports with [screenEnd] and [analysedScreen] and uploads its own images ([teamImage]).
     */
    @JvmStatic
    @JvmOverloads
    public fun start(
        context: Context,
        appId: String,
        sdk: String,
        debugKey: String? = null,
        debug: Boolean = false,
        testBuild: Boolean = false,
        endpoint: String = Options.ENDPOINT,
        apiEndpoint: String = Options.API_ENDPOINT,
        automaticScreens: Boolean = false,
        activity: Activity? = null,
        screens: ScreenListener? = null,
    ) {
        Scruter.startWith(context, Options(appId.trim(), debugKey, debug, testBuild, endpoint, apiEndpoint, sdk, automaticScreens, screens), activity)
    }

    /** Told when a screen view begins, on the SDK's worker thread (docs/MOBILE.md §17). */
    public fun interface ScreenListener {
        /**
         * [analysed]: the session is in the Advanced analytics sample. [capture]: this team phone is to take the screen's
         * image, ≤ [maxBytes] and ≤ [maxHeight] points high. The session's first screen view after a return is
         * announced too.
         */
        public fun screenStarted(session: String, name: String, startMs: Long, analysed: Boolean, capture: Boolean, maxBytes: Int, maxHeight: Int)
    }

    /**
     * An error of the wrapper's own runtime (docs/MOBILE.md §3.10): [fatal] a `crash` (written to disk at once and
     * sent at the next launch, the session marked crashed), else a `nonfatal`. [source] `js` or `dart`; [frames]
     * maps of `fn`, `cl`, `fl`, `l`, `co`, `a` (hex), `i` (index in [images]), `ia` (Boolean); [bundleId] the JS
     * bundle's debug id, [buildId] the Dart snapshot's build id; [images] maps of `n`, `u`, `la`, `ar`.
     */
    @JvmStatic
    @JvmOverloads
    public fun reportError(
        fatal: Boolean,
        source: String,
        type: String,
        reason: String?,
        frames: List<Map<String, Any?>>,
        bundleId: String? = null,
        buildId: String? = null,
        images: List<Map<String, Any?>> = emptyList(),
    ) {
        val e = Scruter.engine() ?: return
        if (!e.running) return
        val session = e.clock.sessionId ?: return
        val r = JSONObject()
        r.put("s", session)
        r.put("id", Text.randomHex(8))
        r.put("t", System.currentTimeMillis())
        r.put("k", if (fatal) "crash" else "nonfatal")
        r.put("src", if (source == "dart") "dart" else "js")
        val ex = JSONObject().put("type", Text.clean(type, 200) ?: "Error")
        Text.clean(reason, 200)?.let { ex.put("reason", it) }
        r.put("ex", ex)
        val f = JSONArray()
        for (m in frames) {
            if (f.length() >= 64) break
            val o = JSONObject()
            (m["fn"] as? String)?.let { o.put("fn", Text.cut(it, 200)) }
            (m["cl"] as? String)?.let { o.put("cl", Text.cut(it, 200)) }
            (m["fl"] as? String)?.let { o.put("fl", Text.cut(it, 200)) }
            (m["l"] as? Number)?.let { if (it.toLong() >= 0) o.put("l", it.toLong()) }
            (m["co"] as? Number)?.let { if (it.toLong() >= 0) o.put("co", it.toLong()) }
            (m["a"] as? String)?.takeIf { Regex("^0x[0-9a-fA-F]{1,16}$").matches(it) }?.let { o.put("a", it) }
            (m["i"] as? Number)?.let { if (it.toInt() in 0..99) o.put("i", it.toInt()) }
            if (m["ia"] == true) o.put("ia", 1)
            f.put(o)
        }
        r.put("th", JSONArray().put(Crashes.thread(f, crashed = true, main = true)))
        r.put("map", e.mappingId)
        if (source == "dart") buildId?.let { r.put("bld", Text.cut(it, 100)) } else bundleId?.let { r.put("bun", Text.cut(it, 100)) }
        if (images.isNotEmpty()) {
            val img = JSONArray()
            for (m in images.take(100)) {
                val o = JSONObject().put("n", Text.cut(m["n"] as? String ?: "?", 200))
                (m["u"] as? String)?.let { o.put("u", Text.cut(it, 100)) }
                (m["la"] as? String)?.takeIf { Regex("^0x[0-9a-fA-F]{1,16}$").matches(it) }?.let { o.put("la", it) }
                (m["ar"] as? String)?.let { o.put("ar", Text.cut(it, 20)) }
                img.put(o)
            }
            r.put("img", img)
        }
        Crashes.context(e, session, r)
        if (fatal) {
            Crashes.save(e, session, r)
            // The runtime aborts next: that exception is this crash, not a second one.
            Crashes.mutedUntil = System.currentTimeMillis() + 5000
        } else {
            e.post { e.crash(session, r, anr = false) }
        }
    }

    /** The wrapper's route names (React Navigation, Navigator, GoRouter). */
    @JvmStatic
    public fun screen(name: String) {
        Scruter.screen(name)
    }

    /** A screen view's engagement, for a wrapper started with a screen listener (`screen_end`, §3.3). */
    @JvmStatic
    public fun screenEnd(session: String, name: String, engagedMs: Long, depth: Int) {
        val e = Scruter.engine() ?: return
        val time = System.currentTimeMillis()
        e.post { e.screenEnd(session, name, time, engagedMs, depth) }
    }

    /** One analysed state `x` of a screen view (docs/API.md §5.3), as JSON. Dropped outside the sample. */
    @JvmStatic
    public fun analysedScreen(session: String, json: String) {
        val e = Scruter.engine() ?: return
        e.post { e.analysed(session, JSONObject(json)) }
    }

    /**
     * A route of the wrapper. [forward]: a push or a presentation, not a back or a tab: a form left that way counts
     * as sent (docs/MOBILE.md §3.9).
     */
    @JvmStatic
    public fun screen(name: String, forward: Boolean) {
        val ui = Scruter.ui() ?: return
        android.os.Handler(android.os.Looper.getMainLooper()).post { ui.explicitScreen(name, forward) }
    }

    /** Reads what the toolkit keeps on its views, for taps, forms and team phones' trees. Set before [start]. */
    @JvmStatic
    public fun setElementInspector(inspector: ElementInspector?) {
        BridgeState.inspector = inspector
    }

    /** Receives the debug log's lines as well as Logcat (`debug = true`): React Native's Metro shows them. */
    @JvmStatic
    public fun setLogSink(sink: LogSink?) {
        Log.sink = sink
    }

    /** A URL the wrapper's runtime received after launch (a link, a team phone's QR code). */
    @JvmStatic
    public fun handleUrl(url: String) {
        Scruter.handle(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }

    /** Sends what waits now. */
    @JvmStatic
    public fun flush() {
        val e = Scruter.engine() ?: return
        e.post { e.flushAfterWrapper() }
    }

    /** Whether this phone is one of the team's phones. */
    @JvmStatic
    public fun isTeamPhone(): Boolean = Scruter.engine()?.team?.active ?: false

    /** Removes this phone from the team's phones. */
    @JvmStatic
    public fun leaveTeamMode() {
        val e = Scruter.engine() ?: return
        e.post { e.team.forget() }
    }

    /**
     * Uploads a team phone's screen image (masks already drawn) and its element [tree] (JSON, docs/API.md §5.3).
     * Ignored unless this phone is a team phone.
     */
    @JvmStatic
    public fun teamImage(screen: String, jpeg: ByteArray, tree: String, width: Int, height: Int, scale: Float) {
        val e = Scruter.engine() ?: return
        e.post { if (e.team.active) e.team.upload(screen, jpeg, JSONObject(tree), width, height, scale) }
    }
}

/** What a wrapper knows about a view that Android does not show; null fields leave the SDK's own rule in place. */
public class BridgeElement @JvmOverloads constructor(
    /** Explicit identifier (`scruterId`). */
    @JvmField public val id: String? = null,
    @JvmField public val mask: Boolean = false,
    @JvmField public val ignore: Boolean = false,
    /** `scruterForm`: the fields inside form this form. */
    @JvmField public val form: String? = null,
    /** The item position in a list. */
    @JvmField public val index: Int? = null,
    @JvmField public val interactive: Boolean? = null,
    /** `button`, `link`, `input`, `choice`, `tab`, `cell`, `image`, `media`, `text`, `other`. */
    @JvmField public val kind: String? = null,
)

/** One line of the debug log. */
public fun interface LogSink {
    public fun line(message: String)
}

/** Called on the main thread for each view of a walk: it has to be quick. */
public fun interface ElementInspector {
    public fun inspect(view: View): BridgeElement?
}
