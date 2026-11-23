package net.scruter.cmp.bridge

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import net.scruter.cmp.ConsentState
import net.scruter.cmp.Presentation
import net.scruter.cmp.ScruterCMP
import net.scruter.cmp.internal.Snap

/**
 * The entry points of Scruter's own wrapper SDKs (React Native, Flutter), which embed this module: an app calls
 * [ScruterCMP], never this. The wrappers keep no state of their own: the choice, the proofs and the queue stay here.
 * They read one snapshot and hear its changes, normalised here so that both toolkits behave alike on both platforms
 * (docs/CMP-MOBILE.md §3.16). Stable within a major version.
 */
public object ScruterCMPBridge {
    /** What the running wrapper hears: called on the main thread. */
    public fun interface Listener {
        /** [snapshot] as [snapshot] returns it; [newChoice]: a decision, the preferences, a withdrawal, a re-ask answered. */
        public fun changed(snapshot: Map<String, Any?>, newChoice: Boolean)
    }

    /** `react_native/1.1.0`, `flutter/1.1.0`: the beacons' `cv`, read when the module starts. */
    @Volatile
    @JvmSynthetic
    internal var sdk: String? = null

    @Volatile
    private var active = false

    @Volatile
    private var listener: Listener? = null
    private var choiceKey: String? = null
    private var latest: Map<String, Any?>? = null
    private val main = Handler(Looper.getMainLooper())

    /**
     * Starts the CMP for a wrapper, once per process: [sdk] names it in the beacons (`react_native/1.1.0`). [activity] is
     * the activity already on screen, which the wrapper's late start missed. A second call (a JavaScript reload, a
     * Flutter hot restart) starts nothing and returns false.
     */
    @JvmStatic
    @JvmOverloads
    public fun start(
        context: Context,
        appId: String,
        sdk: String,
        manual: Boolean = false,
        endpoint: String? = null,
        activity: Activity? = null,
        forceShow: Boolean = false,
        debug: Boolean = false,
    ): Boolean {
        synchronized(this) {
            if (ScruterCMP.engine() != null) return false
            this.sdk = sdk
            active = true
            if (debug) ScruterCMP.debug = true
            ScruterCMP.startWith(
                context,
                appId,
                if (manual) Presentation.MANUAL else Presentation.AUTOMATIC,
                endpoint ?: ScruterCMP.ENDPOINT,
                activity,
            )
            if (forceShow) ScruterCMP.forceShow = true
            return ScruterCMP.engine() != null
        }
    }

    /** The running wrapper's listener, replacing the previous one: a reload replaces it, never adds one. */
    @JvmStatic
    public fun listen(listener: Listener?) {
        this.listener = listener
    }

    /**
     * The module as the wrappers read it: `state` (`ready`, `needsDecision`, `unavailable`), `consentId`, `choice`
     * (`consentId`, `decidedAt` in milliseconds, `granted`, `denied`; absent without a valid choice), `granted` (what
     * `isGranted` answers now, the required purposes included) and `signals` (Consent Mode, `granted` or `denied`).
     */
    @JvmStatic
    public fun snapshot(): Map<String, Any?> = of(ScruterCMP.engine()?.snap)

    /** Main thread, after each state the engine publishes. */
    @JvmSynthetic
    internal fun changed(next: Snap) {
        if (!active) return
        val snap = of(next)
        @Suppress("UNCHECKED_CAST")
        val key = (snap["choice"] as Map<String, Any?>?)?.let { "${it["consentId"]}|${it["decidedAt"]}|${it["granted"]}" }
        val fresh = key != null && key != choiceKey
        choiceKey = key
        val same = latest == snap
        latest = snap
        val l = listener ?: return
        if (fresh || !same) {
            if (Looper.myLooper() == Looper.getMainLooper()) l.changed(snap, fresh) else main.post { l.changed(snap, fresh) }
        }
    }

    private fun of(s: Snap?): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val state = s?.state ?: ConsentState.UNAVAILABLE
        out["state"] = when (state) {
            ConsentState.READY -> "ready"
            ConsentState.NEEDS_DECISION -> "needsDecision"
            ConsentState.UNAVAILABLE -> "unavailable"
        }
        out["consentId"] = s?.stored?.id
        out["granted"] = ((s?.granted ?: emptySet()) + (s?.required ?: emptySet()) + "necessary").sorted()
        val c = s?.choice()
        out["choice"] = c?.let { choice ->
            mapOf(
                "consentId" to choice.consentId,
                "decidedAt" to choice.decidedAt,
                "granted" to (choice.purposes.filterValues { it }.keys + "necessary").sorted(),
                "denied" to choice.purposes.filterValues { !it }.keys.sorted(),
            )
        }
        val signals = LinkedHashMap<String, String>()
        val map = s?.gcm ?: Snap.DEFAULT_GCM
        val answers = s?.answers()
        for ((k, v) in net.scruter.cmp.internal.ConsentMode.signals(map, answers)) signals[k] = if (v) "granted" else "denied"
        out["signals"] = signals
        return out
    }

    /** Tests only. */
    @JvmSynthetic
    internal fun reset() {
        active = false
        listener = null
        choiceKey = null
        latest = null
        sdk = null
    }
}
