package net.scruter.internal

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Choreographer
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.AbsListView
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * A team phone's image of one screen (docs/MOBILE.md §3.11–§3.12), on the main thread, only on team phones. When the
 * screen is idle (1 s after its appearance, layout stable for 500 ms, no indeterminate progress indicator), the full
 * content of its primary scroll container is captured — scrolled step by step (80 % of the viewport, the overlap gives
 * the exact distance scrolled) and stitched, ≤ the server's height, then scrolled back — at the device scale ≤ 2×. Text
 * inputs, web views and `scruterMask` elements are filled with an opaque rectangle before the JPEG is encoded, and
 * appear in the element tree with `m = 1` and no label. Only the app's own window is drawn: never the keyboard, a
 * system dialog or another app. Peak memory: one RGB 565 image ≤ 4 096 × 20 000 px is ≤ 40 MB (a phone's ≈ 25 MB),
 * freed at once.
 */
internal class Capture(
    private val ui: Ui,
    private val name: String,
    private val maxBytes: Int,
    private val maxHeightDp: Int,
    private val done: (jpeg: ByteArray, tree: JSONObject, width: Int, height: Int, scale: Float) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private var lastLayout = SystemClock.elapsedRealtime()
    private val layoutListener = ViewTreeObserver.OnGlobalLayoutListener { lastLayout = SystemClock.elapsedRealtime() }
    private var decor: View? = null
    private var waited = 0L

    // Stitching state
    private lateinit var image: Bitmap
    private lateinit var canvas: Canvas
    private var scale = 1f
    private var container: View? = null
    private var compose = false
    private var cTop = 0
    private var cBottom = 0
    private var contentY = 0
    private var drawnTo = 0
    private var scrolledTotal = 0
    private var maxContent = 0
    private val nodes = LinkedHashMap<String, JSONObject>()
    private val masks = ArrayList<Rect>()
    private var references: Map<Any, Int> = emptyMap()
    private var steps = 0
    private var initialScrollY = 0
    private var lastScrollY = 0

    fun schedule() {
        val d = ui.decor() ?: return
        decor = d
        d.viewTreeObserver.addOnGlobalLayoutListener(layoutListener)
        main.postDelayed({ waitIdle() }, 1000)
    }

    private fun current(): Boolean = ui.view?.name == name && ui.decor() === decor

    private fun waitIdle() {
        val d = decor ?: return
        if (!current()) return stop()
        val now = SystemClock.elapsedRealtime()
        val busy = ViewNodes.busy(d) || Optional.compose && composeBusy(d)
        if (busy || now - lastLayout < 500) {
            waited += 250
            if (waited > 10_000) return stop()
            main.postDelayed({ waitIdle() }, 250)
            return
        }
        try {
            begin(d)
        } catch (e: Throwable) {
            Log.w("capture failed", e)
            stop()
        }
    }

    private fun composeBusy(v: View): Boolean {
        if (ComposeNodes.isRoot(v) && ComposeNodes.busy(v)) return true
        if (v is ViewGroup) for (i in 0 until v.childCount) if (composeBusy(v.getChildAt(i))) return true
        return false
    }

    private fun stop() {
        decor?.viewTreeObserver?.let { if (it.isAlive) it.removeOnGlobalLayoutListener(layoutListener) }
    }

    private fun begin(d: View) {
        val density = d.resources.displayMetrics.density
        scale = minOf(density, 2f) / density
        val width = (d.width * scale).toInt().coerceIn(1, 4096)
        val maxHeightPx = (maxHeightDp * minOf(density, 2f)).toInt().coerceAtMost(20_000)
        val info = Scroll.measure(d)
        val c = info?.container
        val loc = IntArray(2)
        if (c != null && info.content > c.height * 1.05f) {
            container = c
            compose = Optional.compose && ComposeNodes.isRoot(c)
            c.getLocationInWindow(loc)
            cTop = loc[1]
            cBottom = loc[1] + c.height
            if (compose) {
                // The Compose container is a semantics node inside the root: its bounds are given by the measure.
                val r = composeContainerBounds(c)
                if (r != null) {
                    cTop = r.top
                    cBottom = r.bottom
                }
            }
            val header = cTop
            val footer = d.height - cBottom
            maxContent = ((maxHeightPx / scale).toInt() - header - footer).coerceAtLeast(cBottom - cTop)
            val total = ((header + footer + maxContent) * scale).toInt().coerceAtMost(maxHeightPx)
            image = Bitmap.createBitmap(width, total, Bitmap.Config.RGB_565)
            canvas = Canvas(image)
            initialScrollY = c.scrollY
            scrollToTop()
            afterFrames { step() }
        } else {
            image = Bitmap.createBitmap(width, (d.height * scale).toInt().coerceIn(1, 20_000), Bitmap.Config.RGB_565)
            canvas = Canvas(image)
            canvas.save()
            canvas.scale(scale, scale)
            d.draw(canvas)
            canvas.restore()
            collect(ViewNodes.build(d), 0, d.height, 0)
            finish(image.height)
        }
    }

    private fun composeContainerBounds(root: View): Rect? {
        val tree = ViewNodes.build(root)
        var best: UiNode? = null
        for (n in tree.nodes) if (n.source != null && n.source !is View && (best == null || n.width * n.height > best.width * best.height) && n.part == "LazyList") best = n
        if (best == null) {
            val loc = IntArray(2)
            root.getLocationInWindow(loc)
            return Rect(loc[0], loc[1], loc[0] + root.width, loc[1] + root.height)
        }
        return Rect(best.left, best.top, best.right, best.bottom)
    }

    private fun afterFrames(block: () -> Unit) {
        Choreographer.getInstance().postFrameCallback {
            Choreographer.getInstance().postFrameCallback { main.post(block) }
        }
    }

    private fun scrollToTop() {
        val c = container ?: return
        when {
            compose -> ComposeNodes.scrollBy(c, -1e7f)
            c is AbsListView -> c.setSelection(0)
            Optional.recycler && Recycler.isList(c) -> c.scrollBy(0, -1_000_000)
            else -> c.scrollTo(c.scrollX, 0)
        }
    }

    private fun canScroll(): Boolean {
        val c = container ?: return false
        return if (compose) {
            Scroll.measure(decor ?: return false)?.let { it.to < 0.999f } ?: false
        } else {
            c.canScrollVertically(1)
        }
    }

    private fun scrollBy(dy: Int) {
        val c = container ?: return
        when {
            compose -> ComposeNodes.scrollBy(c, dy.toFloat())
            c is AbsListView -> c.scrollListBy(dy)
            else -> c.scrollBy(0, dy)
        }
    }

    /** Positions of the elements inside the container, to measure how far the last scroll went. */
    private fun positions(tree: UiTree): Map<Any, Int> {
        val out = HashMap<Any, Int>()
        for (n in tree.nodes) {
            val src = n.source ?: continue
            if (n.top >= cTop && n.bottom <= cBottom && src !== container) {
                out[if (src is View) src else ComposeNodes.id(src)] = n.top
            }
        }
        return out
    }

    private fun step() {
        val d = decor ?: return stop()
        if (!current()) {
            restore()
            return stop()
        }
        val tree = ViewNodes.build(d)
        if (steps > 0) {
            val now = positions(tree)
            val deltas = ArrayList<Int>()
            for ((k, top) in references) now[k]?.let { deltas.add(top - it) }
            // A plain scroll view says how far it went: its blocks can all be taller than what stays on screen.
            val plain = container?.takeIf { !compose && it !is AbsListView && !(Optional.recycler && Recycler.isList(it)) }
            val delta = if (plain != null) plain.scrollY - lastScrollY else if (deltas.isEmpty()) 0 else deltas.sorted()[deltas.size / 2]
            if (delta <= 0) return complete(tree, lastFrame = true)
            contentY += delta
            scrolledTotal += delta
        }
        steps++
        // Draws the window, then copies the part of the container not drawn yet below the header.
        val frame = Bitmap.createBitmap(image.width, (d.height * scale).toInt().coerceAtLeast(1), Bitmap.Config.RGB_565)
        val fc = Canvas(frame)
        fc.scale(scale, scale)
        d.draw(fc)
        if (steps == 1) {
            // The header: everything above the container.
            canvas.drawBitmap(frame, Rect(0, 0, frame.width, (cTop * scale).toInt()), Rect(0, 0, frame.width, (cTop * scale).toInt()), null)
        }
        val visibleTop = contentY
        val visibleBottom = contentY + (cBottom - cTop)
        val from = maxOf(drawnTo, visibleTop)
        val to = minOf(visibleBottom, maxContent)
        if (to > from) {
            val srcTop = cTop + (from - visibleTop)
            val srcBottom = cTop + (to - visibleTop)
            val dstTop = cTop + from
            canvas.drawBitmap(frame, Rect(0, (srcTop * scale).toInt(), frame.width, (srcBottom * scale).toInt()),
                Rect(0, (dstTop * scale).toInt(), frame.width, ((dstTop + to - from) * scale).toInt()), null)
            collect(tree, srcTop, srcBottom, dstTop - srcTop)
            drawnTo = to
        }
        if (steps == 1) collect(tree, 0, cTop, 0)
        frame.recycle()
        if (drawnTo >= maxContent || !canScroll() || steps >= 60) return complete(tree, lastFrame = false)
        references = positions(tree)
        lastScrollY = container?.scrollY ?: 0
        scrollBy(((cBottom - cTop) * 0.8f).toInt().coerceAtLeast(1))
        afterFrames { step() }
    }

    private fun complete(tree: UiTree, lastFrame: Boolean) {
        val d = decor ?: return stop()
        // The footer: everything below the container, from the last frame.
        val footer = d.height - cBottom
        if (footer > 0) {
            val frame = Bitmap.createBitmap(image.width, (d.height * scale).toInt().coerceAtLeast(1), Bitmap.Config.RGB_565)
            val fc = Canvas(frame)
            fc.scale(scale, scale)
            d.draw(fc)
            val dstTop = cTop + drawnTo
            canvas.drawBitmap(frame, Rect(0, (cBottom * scale).toInt(), frame.width, frame.height),
                Rect(0, (dstTop * scale).toInt(), frame.width, ((dstTop + footer) * scale).toInt().coerceAtMost(image.height)), null)
            collect(tree, cBottom, d.height, dstTop - cBottom)
            frame.recycle()
        }
        if (lastFrame) Log.d("capture: the container stopped scrolling")
        restore()
        finish(((cTop + drawnTo + footer) * scale).toInt().coerceIn(1, image.height))
    }

    /** Back where the team member was: exactly for a scroll view, the top of a lazy list. */
    private fun restore() {
        val c = container ?: return
        scrollToTop()
        if (!compose && c !is AbsListView && !(Optional.recycler && Recycler.isList(c))) c.scrollTo(c.scrollX, initialScrollY)
        scrolledTotal = 0
    }

    /** Adds the tree's elements whose top is in [top, bottom) (window px), moved by [dy] (window px). */
    private fun collect(tree: UiTree, top: Int, bottom: Int, dy: Int) {
        for (n in tree.nodes) {
            if (nodes.size >= 2000) return
            if (n.top < top || n.top >= bottom) continue
            if (n.masked) masks.add(Rect(((n.left) * scale).toInt(), ((n.top + dy) * scale).toInt(), (n.right * scale).toInt(), ((n.bottom + dy) * scale).toInt()))
            if (n.masked && n.parent?.masked == true) continue
            val keep = n.masked || n.explicit || n.interactive || n.kind != "other"
            if (!keep) continue
            val (selector, index) = tree.identity(n)
            val key = "$selector#$index"
            if (nodes.containsKey(key)) continue
            val o = JSONObject()
            o.put("s", selector)
            o.put("i", index)
            o.put("k", ViewNodes.treeKind(n))
            o.put("x", (n.left * scale).toInt().coerceIn(0, 20_000))
            o.put("y", ((n.top + dy) * scale).toInt().coerceIn(0, 20_000))
            o.put("w", (n.width * scale).toInt().coerceIn(0, 20_000))
            o.put("h", (n.height * scale).toInt().coerceIn(0, 20_000))
            if (n.masked) {
                o.put("m", 1)
            } else {
                label(n)?.let { o.put("l", it) }
            }
            nodes[key] = o
        }
    }

    private fun label(n: UiNode): String? {
        val src = n.source
        if (src is View) {
            src.contentDescription?.let { return Text.clean(it.toString(), 80) }
            if (src is TextView) return Text.clean(src.text?.toString(), 80)
            return null
        }
        return if (Optional.compose) ComposeNodes.label(src) else null
    }

    private fun finish(height: Int) {
        stop()
        val d = decor
        try {
            val paint = Paint()
            paint.color = Color.rgb(0x8A, 0x86, 0x94)
            for (r in masks) canvas.drawRect(r, paint)
            if (height < image.height) image.reconfigure(image.width, height, Bitmap.Config.RGB_565)
            var quality = 80
            var jpeg: ByteArray
            while (true) {
                val out = ByteArrayOutputStream(512 * 1024)
                image.compress(Bitmap.CompressFormat.JPEG, quality, out)
                jpeg = out.toByteArray()
                if (jpeg.size <= maxBytes || quality <= 40) break
                quality -= 15
            }
            val width = image.width
            image.recycle()
            if (jpeg.size > maxBytes) {
                Log.d("capture of \"$name\" too large: not sent")
                return
            }
            val tree = JSONObject().put("v", 1).put("nodes", JSONArray(nodes.values))
            done(jpeg, tree, width, height, minOf(d?.resources?.displayMetrics?.density ?: 1f, 2f))
        } catch (e: Throwable) {
            Log.w("capture failed", e)
        }
    }
}
