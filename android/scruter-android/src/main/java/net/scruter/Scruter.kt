package net.scruter

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import net.scruter.internal.Engine
import net.scruter.internal.Log
import net.scruter.internal.Options
import net.scruter.internal.Prefs
import net.scruter.internal.SessionClock
import net.scruter.internal.Text
import net.scruter.internal.Ui
import org.json.JSONObject

/**
 * Scruter Analytics for Android: audience measurement without any identifier that lasts beyond the day, no advertising
 * id, no consent banner (docs/MOBILE.md). Start it once in `Application.onCreate`:
 *
 * ```kotlin
 * Scruter.start(this, appId = "ATMONA02")
 * ```
 *
 * Every call is safe from any thread, returns at once, and is a no-op before [start].
 */
public object Scruter {
    @Volatile
    private var engine: Engine? = null

    @Volatile
    private var ui: Ui? = null

    @Volatile
    private var earlyIntent: Intent? = null
    private val main = Handler(Looper.getMainLooper())

    /**
     * Starts the SDK (docs/MOBILE.md §3.1). [appId] is the "App identifier" shown in Scruter. [debugKey] (from
     * App settings › SDK) makes a debug build a team phone and is never used by a release build; [debug] logs to
     * Logcat (tag `Scruter`); [testBuild] marks a build distributed to testers (Google Play internal testing) that
     * the app's settings can exclude; [endpoint] and [apiEndpoint] are for tests. A second call is ignored.
     */
    @JvmStatic
    @JvmOverloads
    public fun start(
        context: Context,
        appId: String,
        debugKey: String? = null,
        debug: Boolean = false,
        testBuild: Boolean = false,
        endpoint: String = Options.ENDPOINT,
        apiEndpoint: String = Options.API_ENDPOINT,
    ) {
        startWith(context, Options(appId.trim(), debugKey, debug, testBuild, endpoint, apiEndpoint, "android/${BuildConfig.SDK_VERSION}"))
    }

    internal fun startWith(context: Context, options: Options, firstActivity: Activity? = null) {
        if (options.debug) Log.on = true
        synchronized(this) {
            if (engine != null) {
                Log.d("Scruter.start called twice: ignored")
                return
            }
            if (!Options.validAppId(options.appId)) {
                android.util.Log.e("Scruter", "Scruter.start: \"${options.appId}\" is not an app id (ATMONA02): nothing is collected")
                return
            }
            val app = context.applicationContext as? Application ?: return
            val e = Engine(app, options, SessionClock(), Prefs(app))
            val u = Ui(e, app)
            engine = e
            ui = u
            e.post {
                e.init()
                Log.values = Log.on && e.env.debuggable
            }
            net.scruter.internal.Crashes.install(e)
            if (Looper.myLooper() == Looper.getMainLooper()) u.install(firstActivity) else main.post { u.install(firstActivity) }
            earlyIntent?.let { i -> main.post { u.handleIntent(i) } }
            earlyIntent = null
        }
    }

    /** Counts a screen view of [name] (docs/MOBILE.md §3.3): for screens the SDK cannot name by itself. */
    @JvmStatic
    public fun screen(name: String) {
        val u = ui ?: return
        if (Looper.myLooper() == Looper.getMainLooper()) u.explicitScreen(name) else main.post { u.explicitScreen(name) }
    }

    /**
     * Sends the custom event [name] (docs/MOBILE.md §3.4) with up to 30 [props] (strings; numbers and booleans are
     * sent as strings) and a [revenue] in major units with its ISO 4217 [currency] (no currency, no revenue). Never
     * put personal data in a name or a property.
     */
    @JvmStatic
    @JvmOverloads
    public fun track(name: String, props: Map<String, Any?> = emptyMap(), revenue: Double? = null, currency: String? = null) {
        val e = engine ?: return
        val n = Text.clean(name, 120) ?: return Log.d("track: an empty name is not sent")
        val p = JSONObject()
        for ((k, v) in props) {
            if (p.length() >= 30) {
                Log.d("track \"$n\": more than 30 properties, the rest is dropped")
                break
            }
            val key = Text.clean(k, 300) ?: continue
            val value = when (v) {
                is String -> Text.cut(v, 2000)
                is Number, is Boolean -> v.toString()
                null -> continue
                else -> {
                    Log.d("track \"$n\": property \"$key\" is not a string, number or boolean: dropped")
                    continue
                }
            }
            p.put(key, value)
            if (Log.values) Log.d("track \"$n\": $key = $value")
        }
        var cur: String? = currency?.trim()?.uppercase(java.util.Locale.ROOT)
        var rev = revenue
        if (rev != null && (cur == null || cur.length != 3 || cur.any { it !in 'A'..'Z' } || rev.isNaN() || rev.isInfinite())) {
            Log.d("track \"$n\": a revenue needs a finite amount and an ISO 4217 currency: revenue dropped")
            rev = null
            cur = null
        }
        if (rev == null) cur = null
        val session = e.clock.sessionId
        val time = System.currentTimeMillis()
        e.post { e.event(session, n, p, rev, cur, time) }
    }

    /** Reports an error shown on the form field [field] (its key: explicit id or autofill hint) (docs/MOBILE.md §3.9). */
    @JvmStatic
    public fun fieldError(field: String, kind: FieldError) {
        val u = ui ?: return
        main.post { u.fieldError(field, kind.bit) }
    }

    /** Marks the form [form] as sent (docs/MOBILE.md §3.9), when the automatic rule does not see it. */
    @JvmStatic
    public fun formSent(form: String) {
        val u = ui ?: return
        main.post { u.formSent(form) }
    }

    /**
     * The user objects to audience measurement (docs/MOBILE.md §2.3): wire it to the app's "Audience measurement"
     * setting. Nothing is sent any more, not even the configuration request; the queue, the daily id and the install
     * day are deleted. Remembered across launches.
     */
    @JvmStatic
    public fun optOut() {
        val e = engine ?: return
        e.prefs.optedOut = true
        e.post { e.wipe() }
    }

    /** Measurement again, as a new install without install day. */
    @JvmStatic
    public fun optIn() {
        val e = engine ?: return
        if (!e.prefs.optedOut) return
        e.prefs.optedOut = false
        resume(e)
    }

    /** Whether the user opted out. */
    @JvmStatic
    public val isOptedOut: Boolean get() = engine?.prefs?.optedOut ?: false

    /**
     * Stops measurement on this phone only, for the team's own test phones ("Test devices"); kept apart from
     * [optOut] so that an app can offer both. Never copied to another phone by a backup.
     */
    @JvmStatic
    @JvmOverloads
    public fun ignoreThisDevice(ignore: Boolean = true) {
        val e = engine ?: return
        if (ignore == e.prefs.ignored) return
        e.prefs.ignored = ignore
        if (ignore) e.post { e.wipe() } else resume(e)
    }

    /** Whether [ignoreThisDevice] is on. */
    @JvmStatic
    public val isDeviceIgnored: Boolean get() = engine?.prefs?.ignored ?: false

    private fun resume(e: Engine) {
        if (e.prefs.optedOut || e.prefs.ignored) return
        e.prefs.markNoInstallDay()
        e.post { e.optIn() }
        main.post { ui?.restartSession() }
    }

    /**
     * Gives the SDK an intent the app received in `onNewIntent` (a `singleTop` activity opened by a link or a
     * notification): it tells how the next session opened, or registers this phone as a team phone when it is the
     * console's QR code link (`scruter-<app id>://team?t=…`, normally handled by the SDK's own activity).
     */
    @JvmStatic
    public fun handle(intent: Intent) {
        val u = ui
        if (u == null) {
            // A wrapper starts from its own runtime, after a QR code opened the app.
            earlyIntent = intent
            return
        }
        main.post { u.handleIntent(intent) }
    }

    /** The app opened from one of its notifications (when it does not use Firebase Cloud Messaging). */
    @JvmStatic
    public fun openedFromNotification() {
        val u = ui ?: return
        main.post { u.openedFromNotification() }
    }

    internal fun engine(): Engine? = engine

    internal fun ui(): Ui? = ui

    internal fun isStarted(): Boolean = engine != null

    /** Tests only: forgets the running SDK. */
    internal fun resetForTests() {
        synchronized(this) {
            engine = null
            ui = null
        }
    }
}

/** The kind of a form field's error (docs/MOBILE.md §3.9). */
public enum class FieldError(internal val bit: Int) {
    REQUIRED(1),
    FORMAT(2),
    REFUSED(4),
    INVALID(8),
}

/**
 * Names the screen of an `Activity` or a `Fragment` (docs/MOBILE.md §3.3), instead of its class name — required when
 * R8 obfuscates the class (a name of 1–3 characters gives no screen).
 */
@Retention(AnnotationRetention.RUNTIME)
@Target(AnnotationTarget.CLASS)
public annotation class ScruterScreen(val value: String)
