package net.scruter.internal

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewTreeObserver
import android.view.Window

/**
 * Taps, dead taps and rage taps (docs/MOBILE.md §3.6), in sessions of the Advanced analytics sample. The target and its
 * identity are computed when the finger lifts, before the app reacts to it (the screen as the user saw it).
 * - Dead: a tap on a non-interactive target after which nothing happens within 1 s (no screen change, scroll, focus
 *   change, window change, layout pass or Compose semantics change).
 * - Rage: the third tap within 1 s inside a 24-dp circle opens a burst; that tap carries the flag.
 */
internal class Taps(private val ui: Ui) {
    private val main = Handler(Looper.getMainLooper())
    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L
    private var moved = true
    private var slop = -1
    private val recent = ArrayList<FloatArray>(4) // x dp, y dp, time
    private var burst = false
    private var watch: DeadWatch? = null

    fun onTouch(window: Window, v: ScreenView, e: MotionEvent) {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.rawX
                downY = e.rawY
                downAt = e.eventTime
                moved = false
                if (slop < 0) slop = ViewConfiguration.get(window.context).scaledTouchSlop
            }
            MotionEvent.ACTION_MOVE -> if (!moved && (Math.abs(e.rawX - downX) > slop || Math.abs(e.rawY - downY) > slop)) moved = true
            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_CANCEL -> moved = true
            MotionEvent.ACTION_UP -> {
                if (!moved && e.eventTime - downAt < ViewConfiguration.getLongPressTimeout() * 2L) {
                    val now = SystemClock.elapsedRealtime()
                    v.interact(now)
                    if (v.aa) tap(window, v, e.x, e.y, now)
                }
                moved = true
            }
        }
    }

    private fun tap(window: Window, v: ScreenView, x: Float, y: Float, now: Long) {
        val began = System.nanoTime()
        val decor = window.decorView
        val loc = IntArray(2)
        decor.getLocationInWindow(loc)
        val wx = (x + loc[0]).toInt()
        val wy = (y + loc[1]).toInt()
        val tree = ViewNodes.build(decor)
        val hit = tree.hit(wx, wy) ?: return
        val target = tree.target(hit) ?: return
        val (selector, index) = tree.identity(target)
        if (Log.on) Log.d("tap $selector: ${(System.nanoTime() - began) / 1000} µs, ${tree.nodes.size} elements")
        val px = if (target.width > 0) ((wx - target.left) * 100 / target.width) else 0
        val py = if (target.height > 0) ((wy - target.top) * 100 / target.height) else 0
        val ms = now - v.startElapsed
        val rage = rage(x / tree.density, y / tree.density, now)
        val flags = if (rage) 2 else 0
        flushPending()
        if (!target.interactive) {
            watch = DeadWatch(v, decor, selector, index, target.kind, px, py, ms, flags)
        } else {
            v.tap(selector, index, target.kind, px, py, ms, flags)
            ui.tapsAdded(v)
        }
        ui.afterTap(target.kind, target.source)
    }

    /** §3.6: the third tap within 1 s inside a 24-dp circle; one flag per burst. */
    private fun rage(xdp: Float, ydp: Float, now: Long): Boolean {
        recent.removeAll { now - it[2] > 1000 }
        recent.add(floatArrayOf(xdp, ydp, now.toFloat()))
        while (recent.size > 3) recent.removeAt(0)
        val close = recent.size >= 3 && recent.all { Math.hypot((it[0] - xdp).toDouble(), (it[1] - ydp).toDouble()) <= 24.0 }
        if (!close) {
            burst = false
            return false
        }
        if (burst) return false
        burst = true
        return true
    }

    /** Something happened on screen: a pending dead tap is not dead. */
    fun somethingHappened() {
        watch?.alive()
    }

    /** Settles a pending dead tap now (the screen view ends, the app goes to the background). */
    fun flushPending() {
        watch?.settle(dead = false)
    }

    private inner class DeadWatch(
        val v: ScreenView,
        val decor: View,
        val selector: String,
        val index: Int,
        val kind: String,
        val x: Int,
        val y: Int,
        val ms: Long,
        val flags: Int,
    ) {
        private var done = false
        private val layout = ViewTreeObserver.OnGlobalLayoutListener { alive() }
        // React Native lays its views out without a layout pass: only the tree shows that something changed.
        private val compare = Optional.compose || BridgeState.active
        private val semantics = if (compare) semanticsSignature() else 0L
        private val timeout = Runnable { settle(dead = semanticsSignature() == semantics) }

        init {
            decor.viewTreeObserver.addOnGlobalLayoutListener(layout)
            main.postDelayed(timeout, 1000)
        }

        private fun semanticsSignature(): Long {
            if (!compare) return 0
            var sig = 0L
            for (n in ViewNodes.build(decor).nodes) sig = UiNode.mix(sig, n.part.hashCode().toLong() * 31 + n.left * 7 + n.top)
            return sig
        }

        fun alive() = settle(dead = false)

        fun settle(dead: Boolean) {
            if (done) return
            done = true
            main.removeCallbacks(timeout)
            if (decor.viewTreeObserver.isAlive) decor.viewTreeObserver.removeOnGlobalLayoutListener(layout)
            if (watch === this) watch = null
            v.tap(selector, index, kind, x, y, ms, flags or if (dead) 1 else 0)
            ui.tapsAdded(v)
        }
    }
}
