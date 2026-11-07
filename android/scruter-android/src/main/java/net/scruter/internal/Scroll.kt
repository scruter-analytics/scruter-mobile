package net.scruter.internal

import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView

/**
 * The primary vertical scroll container (docs/MOBILE.md §3.7): the largest vertically scrollable view covering at
 * least half of the screen — ScrollView-like views (a single child taller than the view), RecyclerView, AbsListView,
 * Compose `verticalScroll` and lazy lists. Depth = the bottom of what is visible ÷ the content height; lazy lists use
 * item positions.
 */
internal class ScrollInfo(
    /** 0–1: the bottom of the visible part. */
    val depth: Float,
    /** 0–1: the visible part's top and bottom, for the 50 bands of time per block (§3.8). */
    val from: Float,
    val to: Float,
    /** Content height, px. */
    val content: Float,
    val container: View?,
)

internal object Scroll {
    fun measure(root: View): ScrollInfo? {
        val minArea = root.width.toFloat() * root.height / 2f
        var best: View? = null
        var bestArea = minArea
        var compose: View? = null
        fun walk(v: View) {
            if (v.visibility != View.VISIBLE) return
            val area = v.width.toFloat() * v.height
            if (area >= bestArea && verticallyScrollable(v)) {
                best = v
                bestArea = area
            }
            if (Optional.compose && ComposeNodes.isRoot(v) && area >= minArea) compose = v
            if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
        }
        walk(root)
        best?.let { v -> of(v)?.let { return it } }
        val c = compose ?: return null
        val r = ComposeNodes.scroll(c, minArea) ?: return null
        return ScrollInfo(r[0].coerceIn(0f, 1f), r[1].coerceIn(0f, 1f), r[2].coerceIn(0f, 1f), r[3], c)
    }

    private fun verticallyScrollable(v: View): Boolean = when {
        v is AbsListView -> true
        Optional.recycler && Recycler.isList(v) -> Recycler.vertical(v)
        v is ViewGroup && v.childCount == 1 && v.getChildAt(0).height > v.height - v.paddingTop - v.paddingBottom ->
            v.canScrollVertically(1) || v.canScrollVertically(-1)
        else -> false
    }

    fun of(v: View): ScrollInfo? {
        if (v is AbsListView) {
            val count = v.count
            if (count <= 0) return null
            val first = v.firstVisiblePosition.toFloat()
            val last = v.lastVisiblePosition.toFloat()
            val visible = (last - first + 1).coerceAtLeast(1f)
            return ScrollInfo((last + 1) / count, first / count, (last + 1) / count, v.height * count / visible, v)
        }
        if (Optional.recycler && Recycler.isList(v)) {
            val range = Recycler.visibleRange(v)
            if (range != null) {
                val (first, last, count) = Triple(range[0].toFloat(), range[1].toFloat(), range[2].toFloat())
                val visible = (last - first + 1).coerceAtLeast(1f)
                return ScrollInfo(((last + 1) / count).coerceAtMost(1f), first / count, ((last + 1) / count).coerceAtMost(1f), v.height * count / visible, v)
            }
            val s = Recycler.scroll(v)
            if (s[2] <= 0) return null
            val range2 = s[2].toFloat()
            return ScrollInfo(((s[0] + s[1]) / range2).coerceAtMost(1f), s[0] / range2, ((s[0] + s[1]) / range2).coerceAtMost(1f), range2, v)
        }
        if (v is ViewGroup && v.childCount == 1) {
            val content = (v.getChildAt(0).height + v.paddingTop + v.paddingBottom).toFloat()
            if (content <= 0f) return null
            val top = v.scrollY.toFloat()
            val bottom = top + v.height
            return ScrollInfo((bottom / content).coerceAtMost(1f), (top / content).coerceIn(0f, 1f), (bottom / content).coerceAtMost(1f), content, v)
        }
        return null
    }

    /** A depth in % rounded to 5 (§3.7). */
    fun percent(depth: Float): Int = (Math.round(depth.coerceIn(0f, 1f) * 20f) * 5)
}
