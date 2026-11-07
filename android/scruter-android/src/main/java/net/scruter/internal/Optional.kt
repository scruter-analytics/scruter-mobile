package net.scruter.internal

import android.view.View
import android.view.ViewGroup
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView

/**
 * The libraries the SDK supports when the app has them (compileOnly): each is probed once by touching a class
 * through code, so that R8's renaming in the app's release build keeps the probe and the use consistent (a class-name
 * string would miss a renamed class).
 */
internal object Optional {
    val compose: Boolean = probe { ComposeNodes.probe() }
    val fragment: Boolean = probe { Fragments.probe() }
    val recycler: Boolean = probe { Recycler.probe() }
    val material: Boolean = probe { Material.probe() }

    private inline fun probe(block: () -> Any?): Boolean = try {
        block() != null
    } catch (e: Throwable) {
        false
    }
}

/** RecyclerView: a list whose children are cells at their adapter position (§3.5), lazy scroll depth (§3.7). */
internal object Recycler {
    fun probe(): Any = RecyclerView::class.java

    fun isList(v: View): Boolean = v is RecyclerView

    fun position(list: ViewGroup, child: View): Int = (list as RecyclerView).getChildAdapterPosition(child)

    fun vertical(v: View): Boolean {
        val lm = (v as RecyclerView).layoutManager ?: return false
        return lm.canScrollVertically()
    }

    /** (first visible, last visible, item count) for a linear or grid layout, null otherwise. */
    fun visibleRange(v: View): IntArray? {
        val rv = v as RecyclerView
        val lm = rv.layoutManager as? LinearLayoutManager ?: return null
        val count = rv.adapter?.itemCount ?: return null
        if (count <= 0) return null
        val first = lm.findFirstVisibleItemPosition()
        val last = lm.findLastVisibleItemPosition()
        if (first < 0 || last < 0) return null
        return intArrayOf(first, last, count)
    }

    fun scroll(v: View): IntArray {
        val rv = v as RecyclerView
        return intArrayOf(rv.computeVerticalScrollOffset(), rv.computeVerticalScrollExtent(), rv.computeVerticalScrollRange())
    }
}

/** Material's TextInputLayout error (§3.9). */
internal object Material {
    fun probe(): Any = com.google.android.material.textfield.TextInputLayout::class.java

    /** The error shown by the TextInputLayout around [v], if any. */
    fun hasError(v: View): Boolean {
        var p = v.parent
        var depth = 0
        while (p != null && depth++ < 3) {
            if (p is com.google.android.material.textfield.TextInputLayout) return p.error != null
            p = p.parent
        }
        return false
    }
}
