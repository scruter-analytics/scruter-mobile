package net.scruter.internal

import android.app.Activity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/**
 * The cost of a tap's identity on a 2 000-element screen (docs/MOBILE.md §3.18). A JVM number, printed for the README:
 * the guard here is against a quadratic algorithm, not the phone's budget.
 */
@RunWith(RobolectricTestRunner::class)
class PerfTest {
    @Test
    fun identityOfATapOnA2000ElementScreen() {
        val a = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = LinearLayout(a)
        root.orientation = LinearLayout.VERTICAL
        repeat(400) {
            val row = LinearLayout(a)
            repeat(4) { row.addView(TextView(a).apply { text = "x" }) }
            root.addView(row, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 40))
        }
        a.setContentView(FrameLayout(a).apply { addView(root) })
        val decor = a.window.decorView
        decor.measure(1080 or (1 shl 30), 4000 or (1 shl 30))
        decor.layout(0, 0, 1080, 4000)
        var last = 0L
        repeat(200) {
            val t = System.nanoTime()
            val tree = ViewNodes.build(decor)
            val hit = tree.hit(100, 2000)!!
            tree.identity(tree.target(hit)!!)
            last = System.nanoTime() - t
        }
        println("identity of a tap: ${last / 1000} µs, ${ViewNodes.build(decor).nodes.size} elements")
        assertTrue("$last ns", last < 20_000_000)
    }
}
