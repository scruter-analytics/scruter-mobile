package net.scruter.internal

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Choreographer
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewTreeObserver
import android.view.Window
import net.scruter.R
import net.scruter.ScruterScreen
import java.lang.ref.WeakReference
import java.util.WeakHashMap

/**
 * The SDK on the main thread (docs/MOBILE.md §3.2–§3.9): foreground and background, sessions, screens, engagement,
 * taps, scroll and forms. Everything here is light; what touches the disk or the network is posted to [Engine].
 */
internal class Ui(val engine: Engine, private val app: Application) : Application.ActivityLifecycleCallbacks {
    private val main = Handler(Looper.getMainLooper())
    private val clock = engine.clock
    private var started = 0
    private var backgroundSince = 0L
    var view: ScreenView? = null
        private set
    private var returning = false
    private var resumed: WeakReference<Activity>? = null
    private val inner = WeakHashMap<Activity, String>()
    private var pending: WeakReference<Activity>? = null
    private var pendingName: String? = null
    private var pendingPriority = -1
    private var pendingSource: String? = null
    private var pendingAt = 0L
    private var commitPosted = false
    private var launchIntent: Intent? = null
    private var launchReferrer: Uri? = null
    private var launchAt = 0L
    private var notified = false
    private var backHint = false
    private var forceNewSession = false
    private val anr: Anr? = if (android.os.Build.VERSION.SDK_INT < 30) Anr(engine) else null
    val taps = Taps(this)
    val teamScheme = "scruter-" + engine.options.appId.lowercase()
    private val scrollSettled = Runnable { scrolled(true) }
    private val scrollListener = ViewTreeObserver.OnScrollChangedListener {
        taps.somethingHappened()
        // Fires every frame of a scroll: measured at most 5 times a second, and once when it stops.
        val now = SystemClock.elapsedRealtime()
        view?.interact(now)
        main.removeCallbacks(scrollSettled)
        if (now - lastScrollMeasure > 200) scrolled(true) else main.postDelayed(scrollSettled, 220)
    }
    private val focusListener = ViewTreeObserver.OnGlobalFocusChangeListener { _, newFocus -> focusChanged(newFocus) }
    private var lastScrollMeasure = 0L
    private var activeWindow: WeakReference<Window>? = null

    fun install(firstActivity: Activity?) {
        app.registerActivityLifecycleCallbacks(this)
        anr?.start()
        // Started after the first activity was created (a late `start`): catch up with its state.
        if (firstActivity != null) {
            onActivityCreated(firstActivity, null)
            onActivityStarted(firstActivity)
            onActivityResumed(firstActivity)
        }
    }

    // ------------------------------------------------------------------------------------------------ lifecycle

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        if (savedInstanceState == null) {
            launchIntent = activity.intent
            launchReferrer = Openings.referrerOf(activity)
            launchAt = SystemClock.elapsedRealtime()
        }
        if (engine.options.automaticScreens && Optional.fragment) {
            try {
                Fragments.register(activity, this)
            } catch (e: Throwable) {
                Log.w("fragments", e)
            }
        }
    }

    override fun onActivityStarted(activity: Activity) {
        started++
        if (started == 1) toForeground(activity)
    }

    override fun onActivityResumed(activity: Activity) {
        resumed = WeakReference(activity)
        val window = activity.window
        if (window != null && engine.options.screens == null) {
            val cb = window.callback
            if (cb != null && cb !is WindowCallback) window.callback = WindowCallback(this, window, cb)
            activeWindow = WeakReference(window)
            val vto = window.decorView.viewTreeObserver
            vto.removeOnScrollChangedListener(scrollListener)
            vto.addOnScrollChangedListener(scrollListener)
            vto.removeOnGlobalFocusChangeListener(focusListener)
            vto.addOnGlobalFocusChangeListener(focusListener)
        }
        if (engine.options.automaticScreens) {
            val named = activity.javaClass.getAnnotation(ScruterScreen::class.java)?.value
            candidate(activity, named ?: Text.screenNameOf(activity.javaClass), 0, activity.javaClass.name)
        } else {
            inner[activity]?.let { candidate(activity, it, 0, null) }
        }
    }

    override fun onActivityPaused(activity: Activity) {
        if (activity.isFinishing) backHint = true
        if (pending?.get() === activity) clearPending()
    }

    override fun onActivityStopped(activity: Activity) {
        started = maxOf(0, started - 1)
        if (started == 0 && !activity.isChangingConfigurations) toBackground()
    }

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

    override fun onActivityDestroyed(activity: Activity) {
        inner.remove(activity)
        activity.window?.decorView?.viewTreeObserver?.let {
            if (it.isAlive) {
                it.removeOnScrollChangedListener(scrollListener)
                it.removeOnGlobalFocusChangeListener(focusListener)
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ sessions

    private fun toForeground(activity: Activity) {
        val now = SystemClock.elapsedRealtime()
        clock.toForeground(now)
        anr?.setVisible(true)
        val expired = backgroundSince > 0 && now - backgroundSince >= SESSION_GAP
        if (clock.sessionId == null || expired || forceNewSession) {
            forceNewSession = false
            view?.let { end(it, back = true, final = true) }
            view = null
            returning = false
            startSession(activity, now)
        } else {
            returning = view != null
            view?.resume(now)
        }
        backgroundSince = 0
        engine.post { engine.foreground() }
    }

    private fun startSession(activity: Activity?, now: Long) {
        val id = Text.randomHex(8)
        clock.start(id, now)
        val recent = launchIntent != null && now - launchAt < 5_000
        val intent = if (recent) launchIntent else activity?.intent
        val opening = Openings.of(intent, if (recent) launchReferrer else activity?.let { Openings.referrerOf(it) },
            notified, app.packageName, teamScheme)
        notified = false
        launchIntent = null
        val wall = System.currentTimeMillis()
        engine.post { engine.startSession(id, wall, opening) }
    }

    private fun toBackground() {
        val now = SystemClock.elapsedRealtime()
        clock.toBackground(now)
        anr?.setVisible(false)
        backgroundSince = now
        clearPending()
        taps.flushPending()
        val v = view
        if (v != null) {
            v.forms.leave(now)
            v.suspend(now)
            report(v, final = false)
        }
        val id = clock.sessionId
        val wall = System.currentTimeMillis()
        engine.post { engine.background(id, wall) }
    }

    /** After an opt-in: a new session at once when the app is visible, else at the next foreground. */
    fun restartSession() {
        if (!clock.foreground) {
            forceNewSession = true
            return
        }
        forceNewSession = false
        val now = SystemClock.elapsedRealtime()
        view = null
        returning = false
        startSession(resumed?.get(), now)
        val a = resumed?.get() ?: return
        val known = inner[a]
        if (known != null) {
            candidate(a, known, 0, null)
        } else if (engine.options.automaticScreens) {
            candidate(a, Text.screenNameOf(a.javaClass), 0, a.javaClass.name)
        }
    }

    fun openedFromNotification() {
        notified = true
        val id = clock.sessionId ?: return
        val opening = Openings.of(null, null, true, app.packageName, teamScheme)
        engine.post { engine.setOpening(id, opening) }
    }

    /** `Scruter.handle(intent)`: a team link, or the opening of the next session. */
    fun handleIntent(intent: Intent) {
        val data = intent.data
        if (data != null && data.scheme == teamScheme) {
            if (engine.team.codeOf(data) != null) askTeamPhone(data, TEAM_PROMPT_TRIES)
            return
        }
        launchIntent = intent
        launchReferrer = null
        launchAt = SystemClock.elapsedRealtime()
    }

    /**
     * The native question of a team link (docs/MOBILE.md §3.12): a link can come from anyone, only the person holding the
     * phone makes it a team phone. At a cold start the activity may not be resumed yet: a few tries, then no.
     */
    private fun askTeamPhone(data: android.net.Uri, tries: Int) {
        val a = resumed?.get()
        if (a == null || a.isFinishing) {
            if (tries > 0) main.postDelayed({ askTeamPhone(data, tries - 1) }, 250)
            return
        }
        val name = try {
            a.applicationInfo.loadLabel(a.packageManager).toString()
        } catch (e: Exception) {
            ""
        }
        try {
            android.app.AlertDialog.Builder(a)
                .setTitle(a.getString(R.string.scruter_team_confirm_title, name))
                .setMessage(a.getString(R.string.scruter_team_confirm_text, name))
                .setNegativeButton(R.string.scruter_team_confirm_no, null)
                .setPositiveButton(R.string.scruter_team_confirm_yes) { _, _ ->
                    engine.post { engine.team.registerWithLink(data) }
                }
                .show()
        } catch (e: Exception) {
            Log.d("team question: ${e.javaClass.simpleName}")
        }
    }

    // ------------------------------------------------------------------------------------------------ screens

    /**
     * An automatic screen candidate: the activity (priority 0) or a fragment (its depth). Candidates of one
     * appearance are settled after the next frame, the deepest winning, so that an activity hosting fragments or a
     * Navigation Compose host counts its content and not itself; an explicit screen cancels them.
     */
    fun candidate(activity: Activity, name: String?, priority: Int, source: String?) {
        if (pendingPriority > priority && pending?.get() === activity) return
        pending = WeakReference(activity)
        pendingName = name
        pendingPriority = priority
        pendingSource = source
        pendingAt = SystemClock.elapsedRealtime()
        if (!commitPosted) {
            commitPosted = true
            try {
                Choreographer.getInstance().postFrameCallback { main.post { commit() } }
            } catch (e: Exception) {
                main.post { commit() }
            }
        }
    }

    private fun clearPending() {
        pending = null
        pendingName = null
        pendingPriority = -1
        pendingSource = null
    }

    private fun commit() {
        commitPosted = false
        // A destination's content composes a frame or two after the navigation: let its ScruterScreen name it.
        val wait = NAVIGATION_SETTLE - (SystemClock.elapsedRealtime() - pendingAt)
        if (pendingPriority == NAVIGATION && wait > 0) {
            commitPosted = true
            main.postDelayed({ commit() }, wait)
            return
        }
        val activity = pending?.get() ?: return clearPending()
        val priority = pendingPriority
        var name = pendingName
        val source = pendingSource
        clearPending()
        if (activity !== resumed?.get()) return
        if (priority == 0) inner[activity]?.let { name = it }
        if (priority == NAVIGATION && name != null) inner[activity] = name
        if (name == null) {
            Log.d("name this screen: $source has no stable name (Scruter.screen(\"…\") or @ScruterScreen)")
            return
        }
        show(name!!, explicit = false)
    }

    /** `Scruter.screen(name)`, `ScruterScreen(name)`. */
    fun explicitScreen(name: String, forward: Boolean = true) {
        if (!forward) backHint = true
        resumed?.get()?.let { inner[it] = name }
        clearPending()
        show(name, explicit = true)
    }

    /**
     * A Navigation Compose destination: a candidate settled 100 ms later, so that a `ScruterScreen("…")` in
     * the destination's content names it instead (one screen view, not two).
     */
    fun navigation(name: String?, back: Boolean) {
        if (back) backHint = true
        if (name == null) {
            Log.d("name this screen: a navigation destination has neither route nor label")
            return
        }
        val a = resumed?.get() ?: return
        candidate(a, name, NAVIGATION, "navigation")
    }

    private fun show(raw: String, explicit: Boolean) {
        val name = Text.clean(raw, 120) ?: return
        val id = clock.sessionId
        if (id == null || !clock.foreground) {
            Log.d("screen \"$name\" outside the foreground: not counted")
            return
        }
        val now = SystemClock.elapsedRealtime()
        val v = view
        if (v != null && v.name == name && v.sessionId == id && (returning || explicit && now - v.startElapsed < 1000)) {
            // The same appearance: a return from the background, or an explicit call echoing an automatic one.
            returning = false
            return
        }
        returning = false
        val back = backHint
        backHint = false
        if (v != null) end(v, back, final = true)
        if (engine.config.ignores(name)) {
            view = null
            Log.d("screen \"$name\" ignored by the app's settings")
            return
        }
        val wall = System.currentTimeMillis()
        val sv = ScreenView(name, id, { engine.sampled == id }, wall, now)
        view = sv
        engine.post { engine.screen(id, name, wall) }
        if (engine.options.screens != null) {
            engine.post { engine.announceScreen(id, name, wall) }
            return
        }
        // Measures the screen once it is laid out: size, scroll container, fields.
        main.post { measure(sv) }
        engine.team.onScreen(name)
    }

    private fun measure(sv: ScreenView) {
        if (view !== sv) return
        val decor = activeWindow?.get()?.decorView ?: return
        val density = decor.resources.displayMetrics.density
        sv.vw = (decor.width / density).toInt()
        sv.vh = (decor.height / density).toInt()
        sv.scrolled(SystemClock.elapsedRealtime(), Scroll.measure(decor), density, userScroll = false)
        if (sv.aa) scanForms(sv, decor)
    }

    private fun scanForms(sv: ScreenView, decor: View) {
        val tree = ViewNodes.build(decor)
        sv.forms.scan(tree) { field -> Forms.watch(field) { v -> view?.forms?.changed(v) } }
        if (Optional.compose) sv.forms.refreshCompose(tree, SystemClock.elapsedRealtime())
    }

    /** Ends a screen view: its engagement and its last analysed state (§3.6–§3.9). */
    private fun end(v: ScreenView, back: Boolean, final: Boolean) {
        val now = SystemClock.elapsedRealtime()
        taps.flushPending()
        if (v.visible) v.tick(now)
        if (!back) v.forms.leaveForward(now) else v.forms.leave(now)
        report(v, final)
    }

    private fun report(v: ScreenView, final: Boolean) {
        if (engine.options.screens != null) return
        val wall = System.currentTimeMillis()
        val e = v.engagement(final)
        if (e != null) {
            val (ms, depth) = e
            engine.post { engine.screenEnd(v.sessionId, v.name, wall, ms, depth) }
        }
        v.state(final)?.let { s -> engine.post { engine.analysed(v.sessionId, s) } }
    }

    /** A state when 100 taps accumulated (§3.6: ≤ 100 per item). */
    fun tapsAdded(v: ScreenView) {
        if (v.tapsSinceState >= ScreenView.TAPS_PER_STATE) v.state(false)?.let { s -> engine.post { engine.analysed(v.sessionId, s) } }
    }

    // ------------------------------------------------------------------------------------------------ input

    fun touch(window: Window, event: MotionEvent) {
        val v = view ?: return
        taps.onTouch(window, v, event)
        if (event.actionMasked == MotionEvent.ACTION_MOVE) {
            val now = SystemClock.elapsedRealtime()
            v.interact(now)
            if (now - lastScrollMeasure > 200) scrolled(true)
        } else if (event.actionMasked == MotionEvent.ACTION_UP) {
            // A fling goes on after the finger leaves: measure once more when it has settled.
            main.postDelayed({ scrolled(false) }, 800)
        }
    }

    fun key(event: KeyEvent) {
        if (event.action != KeyEvent.ACTION_DOWN) return
        if (event.keyCode == KeyEvent.KEYCODE_BACK) backHint = true
        view?.interact(SystemClock.elapsedRealtime())
    }

    fun windowFocusChanged() {
        taps.somethingHappened()
    }

    /** Measures the scroll container; [interaction]: a scroll happened (not a mere measure). */
    private fun scrolled(interaction: Boolean) {
        val v = view ?: return
        val decor = activeWindow?.get()?.decorView ?: return
        val now = SystemClock.elapsedRealtime()
        lastScrollMeasure = now
        v.scrolled(now, Scroll.measure(decor), decor.resources.displayMetrics.density, interaction)
    }

    private fun focusChanged(newFocus: View?) {
        val v = view ?: return
        taps.somethingHappened()
        if (!v.aa) return
        val now = SystemClock.elapsedRealtime()
        v.interact(now)
        val decor = activeWindow?.get()?.decorView
        if (newFocus != null && decor != null) scanForms(v, decor)
        v.forms.focus(newFocus, now)
    }

    /** After a tap: Compose fields' focus and edits, a submit attempt (§3.9). */
    fun afterTap(kind: String, target: Any?) {
        val v = view ?: return
        if (kind == "choice") v.forms.changed(target)
        main.postDelayed({
            if (view === v) {
                val decor = activeWindow?.get()?.decorView
                if (Optional.compose && decor != null) {
                    val tree = ViewNodes.build(decor)
                    v.forms.scan(tree) { }
                    v.forms.refreshCompose(tree, SystemClock.elapsedRealtime())
                }
                if (kind == "button") v.forms.submitAttempt()
            }
        }, 500)
    }

    fun fieldError(key: String, kind: Int) {
        view?.forms?.explicitError(key, kind)
    }

    fun formSent(name: String) {
        view?.forms?.sent(name, SystemClock.elapsedRealtime())
    }

    fun decor(): View? = activeWindow?.get()?.decorView

    fun currentActivity(): Activity? = resumed?.get()

    companion object {
        const val SESSION_GAP = 30L * 60 * 1000
        const val NAVIGATION = 1000
        const val NAVIGATION_SETTLE = 100L
        const val TEAM_PROMPT_TRIES = 8
    }
}
