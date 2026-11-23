package net.scruter.cmp.internal

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.ViewTreeObserver
import net.scruter.cmp.ConsentState
import net.scruter.cmp.Presentation
import net.scruter.cmp.ui.Confirmation
import net.scruter.cmp.ui.Sheet
import net.scruter.cmp.ui.SheetState
import java.io.File
import java.lang.ref.WeakReference

/**
 * The sheet's side of the engine, on the main thread (docs/CMP-MOBILE.md §3.2): follows the activities, presents the
 * sheet over the resumed one once its first frame is drawn, keeps a display across an activity's recreation, and shows
 * the short confirmation after a decision.
 */
internal class UiHost(private val engine: Engine) : Application.ActivityLifecycleCallbacks {
    private var resumed: WeakReference<Activity>? = null
    private var drawn = false
    private var sheet: Sheet? = null

    /** A display whose activity went away (rotation, theme): shown again over the next resumed activity. */
    private var kept: SheetState? = null
    private var preparing = false
    private var delayed: Runnable? = null
    private var requested: WeakReference<Activity>? = null

    fun install(first: Activity?) {
        engine.app.registerActivityLifecycleCallbacks(this)
        // `start` called after an activity already started (a wrapper SDK, a late start): take it as it is.
        if (first != null) {
            onActivityStarted(first)
            onActivityResumed(first)
        }
    }

    // ------------------------------------------------------------------------------------------------ activities

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

    override fun onActivityStarted(activity: Activity) {
        engine.activityStarted()
    }

    override fun onActivityResumed(activity: Activity) {
        resumed = WeakReference(activity)
        drawn = false
        afterFirstFrame(activity) {
            if (resumed?.get() !== activity) return@afterFirstFrame
            drawn = true
            val k = kept
            if (k != null && sheet == null) {
                kept = null
                show(activity, k)
            } else {
                present(automatic = true)
            }
        }
    }

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) {
        engine.activityStopped(activity)
    }

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    override fun onActivityDestroyed(activity: Activity) {
        val s = sheet ?: return
        if (s.activity === activity) {
            sheet = null
            if (!s.st.decided) kept = s.st
            s.detach()
        }
        if (resumed?.get() === activity) resumed = null
        if (requested?.get() === activity) requested = null
    }

    /**
     * Runs [block] once [activity]'s window has drawn its first frame (at the latest after one second: a window that
     * never draws, such as a test's, still gets its sheet).
     */
    private fun afterFirstFrame(activity: Activity, block: () -> Unit) {
        val decor = activity.window?.decorView ?: return
        var done = false
        val once = {
            if (!done) {
                done = true
                block()
            }
        }
        val listener = object : ViewTreeObserver.OnDrawListener {
            override fun onDraw() {
                // A draw listener cannot remove itself while drawing.
                decor.post {
                    if (decor.viewTreeObserver.isAlive) decor.viewTreeObserver.removeOnDrawListener(this)
                    once()
                }
            }
        }
        decor.viewTreeObserver.addOnDrawListener(listener)
        decor.invalidate()
        decor.postDelayed({
            if (decor.viewTreeObserver.isAlive) decor.viewTreeObserver.removeOnDrawListener(listener)
            once()
        }, 1000)
    }

    // ------------------------------------------------------------------------------------------------ presenting

    fun stateChanged() {
        present(automatic = true)
        requested?.get()?.let { a -> if (a === resumed?.get() && drawn) present(automatic = false, activity = a) }
    }

    fun configChanged() {
        stateChanged()
    }

    /** The automatic presentation, or a manual one (`showIfNeeded`, `forceShow`). */
    fun present(automatic: Boolean, activity: Activity? = null): Boolean {
        val s = engine.snap
        val force = engine.forceShow
        if (automatic && engine.options.presentation != Presentation.AUTOMATIC && !force) return false
        // `showIfNeeded` before the first configuration arrived: kept, and honoured when it arrives.
        if (!automatic && activity != null) requested = if (s.state == ConsentState.UNAVAILABLE) WeakReference(activity) else null
        if (s.state != ConsentState.NEEDS_DECISION && !force) return false
        if (sheet != null || preparing || kept != null) return sheet != null || preparing
        val a = activity ?: resumed?.get()?.takeIf { drawn } ?: return false
        if (a.isFinishing) return false
        val delay = engine.config?.cmp?.ui?.delaySeconds ?: 0
        if (automatic && delay > 0 && delayed == null) {
            val r = Runnable {
                delayed = null
                prepare(a, SheetModelKind.BANNER)
            }
            delayed = r
            engine.main.postDelayed(r, delay * 1000L)
            return true
        }
        prepare(a, SheetModelKind.BANNER)
        return true
    }

    /** `setLanguage`: a sheet drawn or kept in another language is drawn again in the new one. */
    fun languageChanged() {
        val k = kept
        if (k != null) {
            kept = null
            resumed?.get()?.takeIf { drawn }?.let { prepare(it, k.model.kind) }
        }
        val s = sheet ?: return
        val wanted = engine.config?.cmp?.let { c -> engine.pickLanguage(if (s.st.model.variant == "b" && c.abTest != null) c.abTest.ui else c.ui) }
        if (wanted == null || wanted == s.st.model.lang || s.st.decided) return
        sheet = null
        s.detach()
        prepare(s.activity, s.st.model.kind)
    }

    fun showPreferences(activity: Activity) {
        engine.preferencesCalled()
        sheet?.let { if (it.isShowing) return }
        prepare(activity, SheetModelKind.PREFERENCES)
    }

    private fun prepare(activity: Activity, kind: SheetModel.Kind) {
        if (preparing) return
        preparing = true
        val c = activity.resources.configuration
        val tablet = c.smallestScreenWidthDp >= 600
        val widthDp = if (tablet) 480 else c.screenWidthDp
        val density = activity.resources.displayMetrics.density
        val cmp = engine.config?.cmp
        val opening = engine.opening
        val variant = if (cmp == null) null else opening?.variant ?: engine.drawVariant(cmp).also { opening?.variant = it }
        engine.post {
            val model = try {
                engine.prepare(kind, variant, widthDp, density, !tablet)
            } catch (e: RuntimeException) {
                Log.w("the sheet could not be prepared", e)
                null
            }
            engine.main.post {
                preparing = false
                if (model == null) {
                    Log.d("no sheet: no configuration at hand")
                    return@post
                }
                val target = activity.takeIf { !it.isFinishing && !it.isDestroyed } ?: resumed?.get()
                if (target == null) {
                    kept = SheetState(model)
                    return@post
                }
                if (kind == SheetModel.Kind.BANNER && engine.snap.state != ConsentState.NEEDS_DECISION && !engine.forceShow) return@post
                show(target, SheetState(model))
            }
        }
    }

    private fun show(activity: Activity, st: SheetState) {
        val s = try {
            Sheet(this, activity, st)
        } catch (e: RuntimeException) {
            Log.w("the sheet could not be drawn", e)
            return
        }
        sheet = s
        try {
            s.show()
        } catch (e: RuntimeException) {
            // The activity's window is gone (BadTokenException): the next resumed activity shows it.
            Log.d("sheet not shown now: ${e.javaClass.simpleName}")
            sheet = null
            kept = st
            return
        }
        if (st.model.kind == SheetModel.Kind.BANNER) engine.displayed()
        Log.d("sheet shown (${st.model.kind}, ${st.model.lang}${st.model.variant?.let { ", variant $it" } ?: ""})")
    }

    // ------------------------------------------------------------------------------------------------ from the sheet

    fun decide(s: Sheet, action: String?, source: String, map: Map<String, Boolean>, tcf: TcfChoice?) {
        engine.decide(s.st.model, action, source, map, s.st.shownAt, tcf) {
            s.close {
                if (sheet === s) sheet = null
                Confirmation.show(s.activity, s.st.model)
            }
        }
    }

    fun closed(s: Sheet, decided: Boolean) {
        if (sheet === s) sheet = null
        if (!decided) Log.d("preferences closed without a change")
    }

    fun hasValidChoice(): Boolean = engine.snap.state == ConsentState.READY

    /** The video loop's file (fetched after the first frame), then played if the sheet still shows. */
    fun loadVideo(s: Sheet, url: String?, cached: File?) {
        if (url == null) return
        if (cached != null) {
            s.play(cached)
            return
        }
        engine.post {
            val f = engine.video(url)
            if (f != null) engine.main.post { if (sheet === s) s.play(f) }
        }
    }

    /**
     * Whether the header's loop may play by itself (docs/CMP-MOBILE.md §2.4): never with animations removed, under the
     * battery saver or with Data Saver on; the poster stays and the play button starts it.
     */
    fun motionAllowed(context: Context): Boolean {
        val cr = context.contentResolver
        val scale = try {
            Settings.Global.getFloat(cr, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        } catch (e: RuntimeException) {
            1f
        }
        if (scale == 0f) return false
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (pm?.isPowerSaveMode == true) return false
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (cm != null && cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED) return false
        return Build.VERSION.SDK_INT < 26 || android.animation.ValueAnimator.areAnimatorsEnabled()
    }

    /** Tests and screenshots: the sheet on screen. */
    fun current(): Sheet? = sheet
}

private typealias SheetModelKind = SheetModel.Kind
