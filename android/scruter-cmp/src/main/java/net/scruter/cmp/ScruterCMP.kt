package net.scruter.cmp

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Looper
import net.scruter.cmp.internal.ConsentMode
import net.scruter.cmp.internal.Engine
import net.scruter.cmp.internal.Log
import net.scruter.cmp.internal.Options

/**
 * Scruter CMP for Android apps (docs/CMP-MOBILE.md): the consent sheet, the visitor's choice kept in the app's own
 * storage, its proofs, Google Consent Mode. Start it in `Application.onCreate`, then gate the app's SDKs:
 *
 * ```kotlin
 * ScruterCMP.start(this, "ATMONA02")
 * ScruterCMP.whenReady { choice -> if (choice.isGranted(Purpose.ANALYTICS)) startAnalytics() }
 * ```
 *
 * Until a choice exists, every optional purpose is denied. Every call is safe from any thread and does nothing before
 * [start]; listeners run on the main thread.
 */
public object ScruterCMP {
    /** Where the configuration and the beacons go. */
    public const val ENDPOINT: String = "https://cdn.scruter.net"

    @Volatile
    private var engine: Engine? = null

    /**
     * Starts the CMP (docs/CMP-MOBILE.md §3.1) with the app id shown in Scruter (`ATMONA02`). Reads the stored choice
     * at once (one storage read: [isGranted] answers from the next line), then fetches the configuration in the
     * background. [presentation] [Presentation.MANUAL] waits for [showIfNeeded]. [endpoint] is for tests. A second
     * call is ignored.
     */
    @JvmStatic
    @JvmOverloads
    public fun start(context: Context, appId: String, presentation: Presentation = Presentation.AUTOMATIC, endpoint: String = ENDPOINT) {
        startWith(context, appId, presentation, endpoint, null)
    }

    internal fun startWith(context: Context, appId: String, presentation: Presentation, endpoint: String, first: Activity?) {
        synchronized(this) {
            if (engine != null) {
                Log.d("ScruterCMP.start called twice: ignored")
                return
            }
            val id = appId.trim()
            if (!Regex("^[A-Z0-9]{4,16}$").matches(id)) {
                Log.e("ScruterCMP.start: \"$appId\" is not an app id (ATMONA02): no sheet, every optional purpose denied")
                return
            }
            val app = context.applicationContext as? Application ?: return
            val e = Engine(app, Options(id, presentation, Engine.validEndpoint(endpoint) ?: ENDPOINT, BuildConfig.SDK_VERSION))
            engine = e
            val install = { e.ui.install(first) }
            if (Looper.myLooper() == Looper.getMainLooper()) install() else e.main.post(install)
        }
    }

    /** Logs the state, the configuration's revision and every decision to Logcat, tag `ScruterCMP`. */
    @JvmStatic
    public var debug: Boolean
        get() = Log.on
        set(value) {
            Log.on = value
        }

    /** Where the CMP stands: [ConsentState.READY], [ConsentState.NEEDS_DECISION] or [ConsentState.UNAVAILABLE]. */
    @JvmStatic
    public val state: ConsentState
        get() = engine?.snap?.state ?: ConsentState.UNAVAILABLE

    /**
     * Whether the visitor granted [purpose] (synchronous). `false` until a choice exists; a necessary purpose is
     * always granted. During a re-ask, a purpose that did not change keeps its answer until the new decision.
     */
    @JvmStatic
    public fun isGranted(purpose: String): Boolean {
        val s = engine?.snap ?: return false
        return purpose in s.required || purpose in s.granted
    }

    /** The visitor's current choice, or null when there is no valid one. */
    @JvmStatic
    public val choice: ConsentChoice?
        get() = engine?.snap?.choice()

    /** The consent id of this app on this device (`cns_…`): the visitor's receipt. Null before a first choice. */
    @JvmStatic
    public val consentId: String?
        get() = engine?.snap?.stored?.id

    /** Calls [listener] once a valid choice exists: now, or after the decision. */
    @JvmStatic
    public fun whenReady(listener: ConsentListener): Subscription =
        engine?.whenReady(listener) ?: Subscription { }.also { Log.d("whenReady before start: never called") }

    /**
     * Calls [listener] whenever a valid choice appears or changes: a decision in the sheet (the first one too), in the
     * preferences, a withdrawal, the answer to a re-ask.
     */
    @JvmStatic
    public fun onChange(listener: ConsentListener): Subscription =
        engine?.onChange(listener) ?: Subscription { }.also { Log.d("onChange before start: never called") }

    /**
     * The app's settings entry (« Confidentialité », « Gérer mes cookies »: docs/CMP-MOBILE.md §2.5): every purpose
     * and its state, the receipt, « Tout refuser » to withdraw. An app has no floating button: this entry is how a
     * visitor changes their mind.
     */
    @JvmStatic
    public fun showPreferences(activity: Activity) {
        val e = engine ?: return
        e.onMain { e.ui.showPreferences(activity) }
    }

    /**
     * Shows the sheet over [activity] when a decision is needed ([Presentation.MANUAL]: after an onboarding, never
     * after a paywall or a sign-in wall). Returns whether it shows (or is being prepared).
     */
    @JvmStatic
    public fun showIfNeeded(activity: Activity): Boolean {
        val e = engine ?: return false
        if (Looper.myLooper() != Looper.getMainLooper()) {
            e.main.post { e.ui.present(automatic = false, activity = activity) }
            return state == ConsentState.NEEDS_DECISION
        }
        return e.ui.present(automatic = false, activity = activity)
    }

    /**
     * The Google Consent Mode v2 signals of the visitor's choice (docs/CMP-MOBILE.md §3.7), with the banner's
     * mapping (Consent Mode settings of the banner, else the default one): every signal denied until a choice exists,
     * `security_storage` always granted. Pass them to Firebase's `setConsent`.
     */
    @JvmStatic
    public fun consentModeSignals(): Map<String, ConsentStatus> {
        val s = engine?.snap
        val map = s?.gcm ?: net.scruter.cmp.internal.Snap.DEFAULT_GCM
        val choice = s?.answers()
        return ConsentMode.signals(map, choice).mapValues { if (it.value) ConsentStatus.GRANTED else ConsentStatus.DENIED }
    }

    /** Draws the sheet in [language] (`"de"`) when the banner speaks it, whatever the device's; null gives it back. */
    @JvmStatic
    public fun setLanguage(language: String?) {
        val e = engine ?: return
        e.language = language?.trim()?.takeIf { it.isNotEmpty() }
        e.onMain { e.ui.languageChanged() }
    }

    /** Debug and QA: forgets the visitor's choice (the sheet asks again). */
    @JvmStatic
    public fun debugReset() {
        engine?.debugReset()
    }

    /** Debug and screenshots: shows the sheet over the resumed activity even when a valid choice exists. */
    @JvmStatic
    public var forceShow: Boolean
        get() = engine?.forceShow ?: false
        set(value) {
            val e = engine ?: return
            e.forceShow = value
            if (value) e.onMain { e.ui.present(automatic = false) }
        }

    // ------------------------------------------------------------------------------------------------ tests

    /** The engine, for the tests. */
    @JvmSynthetic
    internal fun engine(): Engine? = engine

    @JvmSynthetic
    internal fun resetForTests() {
        synchronized(this) {
            engine?.let { e ->
                e.app.unregisterActivityLifecycleCallbacks(e.ui)
                e.stop()
            }
            engine = null
        }
    }
}
