package net.scruter.internal

import android.content.res.Resources
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.AbsListView
import android.widget.AdapterView
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.RatingBar
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.TextView
import net.scruter.R
import net.scruter.bridge.BridgeElement

/**
 * One element of a screen, from a View or a Compose semantics node: what element identity (docs/MOBILE.md §3.5),
 * taps, forms and the team phones' capture need. Frames are in window pixels.
 */
internal class UiNode(
    @JvmField val parent: UiNode?,
    @JvmField val part: String,
    @JvmField val explicit: Boolean,
    @JvmField val kind: String,
    @JvmField val interactive: Boolean,
    @JvmField val masked: Boolean,
    @JvmField val ignored: Boolean,
    @JvmField val left: Int,
    @JvmField val top: Int,
    @JvmField val right: Int,
    @JvmField val bottom: Int,
    /** The item position when this node is a cell of a list, else −1. */
    @JvmField val cellIndex: Int,
    @JvmField val source: Any?,
) {
    @JvmField val children = ArrayList<UiNode>(2)
    @JvmField val depth: Int = if (parent == null) 0 else parent.depth + 1

    /** A hash of the parts of every ancestor: "a different parent chain" (§3.5 step 4). */
    @JvmField val chain: Long = if (parent == null) 0L else mix(parent.chain, parent.part.hashCode().toLong())

    /** Index of this node in the tree's depth-first order. */
    @JvmField var order = 0
    @JvmField var form: String? = null
    @JvmField var label: String? = null

    fun contains(x: Int, y: Int) = x >= left && x < right && y >= top && y < bottom
    val width get() = right - left
    val height get() = bottom - top

    /** The nearest list cell, self included. */
    fun cell(): UiNode? {
        var n: UiNode? = this
        while (n != null) {
            if (n.cellIndex >= 0) return n
            n = n.parent
        }
        return null
    }

    companion object {
        fun mix(a: Long, b: Long): Long {
            var h = a * 31 + b
            h = h xor (h ushr 33)
            h *= -0xae502812aa7333L
            return h xor (h ushr 29)
        }
    }
}

/** A screen's tree: built on the main thread, read anywhere. */
internal class UiTree(val root: UiNode, val nodes: List<UiNode>, val density: Float) {
    /** The deepest visible element under (x, y), last drawn first. */
    fun hit(x: Int, y: Int): UiNode? {
        var n = root
        if (!n.contains(x, y)) return null
        while (true) {
            var next: UiNode? = null
            for (i in n.children.indices.reversed()) {
                val c = n.children[i]
                if (c.contains(x, y)) {
                    next = c
                    break
                }
            }
            if (next == null) return n
            n = next
        }
    }

    /**
     * The target of a tap on [hit] (§3.5 step 1): the nearest interactive ancestor, else the hit element (climbing at
     * most 3 levels out of single-child text and image wrappers); a masked ancestor is the target itself; `null` inside
     * an ignored element.
     */
    fun target(hit: UiNode): UiNode? {
        var masked: UiNode? = null
        var n: UiNode? = hit
        while (n != null && n !== root) {
            if (n.ignored) return null
            if (n.masked) masked = n
            n = n.parent
        }
        if (masked != null) return masked
        n = hit
        while (n != null && n !== root) {
            if (n.interactive) return n
            n = n.parent
        }
        var t = hit
        var climbs = 0
        while (climbs < 3 && (t.kind == "text" || t.kind == "image") && t.parent != null &&
            t.parent !== root && t.parent.children.size == 1
        ) {
            t = t.parent
            climbs++
        }
        return t
    }

    /** The parts from [n] up [k] ancestors, joined with `/`. */
    private fun path(n: UiNode, k: Int): String {
        val parts = arrayOfNulls<String>(k + 1)
        var x: UiNode? = n
        for (i in k downTo 0) {
            parts[i] = x?.part
            x = x?.parent
        }
        return parts.joinToString("/")
    }

    /** Whether [a] and [b] have the same last k + 1 parts (no allocation: it runs for every element of a screen). */
    private fun samePath(a: UiNode, b: UiNode, k: Int): Boolean {
        var x: UiNode? = a
        var y: UiNode? = b
        for (i in 0..k) {
            if (x == null || y == null || x === root || y === root || x.part != y.part) return false
            x = x.parent
            y = y.parent
        }
        return true
    }

    private fun ancestor(n: UiNode, k: Int): UiNode? {
        var x: UiNode? = n
        repeat(k) { x = x?.parent }
        return x
    }

    /** How many ancestors the selector of [n] includes (§3.5 step 4, list cells step 4 too). */
    fun levels(n: UiNode): Int {
        var k = 0
        val cell = n.cell()
        if (cell != null) {
            // The list's part + the cell's part (+ the parts between the cell and the element).
            var d = 0
            var x: UiNode? = n
            while (x != null && x !== cell) {
                d++
                x = x.parent
            }
            k = d + 1
        }
        val most = if (cell != null) k + 6 else 6
        while (k < most) {
            val a = ancestor(n, k) ?: break
            if (a === root || k > 0 && a.explicit) break
            var clash = false
            for (o in nodes) {
                if (o !== n && o.chain != n.chain && o.part == n.part && samePath(o, n, k) &&
                    !(cell != null && o.cell()?.parent === cell.parent)
                ) {
                    clash = true
                    break
                }
            }
            if (!clash) break
            val up = ancestor(n, k + 1)
            if (up == null || up === root) break
            k++
        }
        return k
    }

    /** Selector (≤ 200 characters, cut at a `/`) and index of [n] (§3.5). */
    fun identity(n: UiNode): Pair<String, Int> {
        val k = levels(n)
        var s = path(n, k)
        while (s.length > 200 && s.indexOf('/') >= 0) s = s.substring(s.indexOf('/') + 1)
        if (s.length > 200) s = s.substring(0, 200)
        val cell = n.cell()
        val index = if (cell != null) {
            cell.cellIndex
        } else {
            var i = 0
            for (o in nodes) {
                if (o === n) break
                if (samePath(o, n, k)) i++
            }
            i
        }
        return Pair(s, index.coerceIn(0, 9999))
    }
}

/** Builds [UiTree]s from the View hierarchy (and Compose roots through [ComposeNodes]). */
internal object ViewNodes {
    private val entryNames = HashMap<Int, String?>()
    private val typeNames = HashMap<Class<*>, String>()
    private val kindParts = HashMap<String, HashMap<String, String>>()
    private val idParts = HashMap<String, String>()
    private val generic = setOf(
        "View", "ViewGroup", "FrameLayout", "LinearLayout", "RelativeLayout", "GridLayout", "TableLayout", "TableRow",
        "ViewStub", "Space",
    )

    fun build(root: View, maxNodes: Int = 5000): UiTree {
        val density = root.resources.displayMetrics.density
        val loc = IntArray(2)
        root.getLocationInWindow(loc)
        val rootNode = UiNode(null, "", false, "other", false, false, false, loc[0], loc[1], loc[0] + root.width,
            loc[1] + root.height, -1, root)
        val all = ArrayList<UiNode>(256)
        if (root is ViewGroup) children(root, rootNode, loc[0], loc[1], all, maxNodes, false)
        if (Optional.compose && ComposeNodes.isRoot(root)) ComposeNodes.add(root, rootNode, all, maxNodes)
        for (i in all.indices) all[i].order = i
        return UiTree(rootNode, all, density)
    }

    private fun children(group: ViewGroup, parent: UiNode, ox: Int, oy: Int, all: ArrayList<UiNode>, max: Int, inMask: Boolean) {
        val list = group is AdapterView<*> || Optional.recycler && Recycler.isList(group)
        for (i in 0 until group.childCount) {
            if (all.size >= max) return
            val v = group.getChildAt(i)
            if (v.visibility != View.VISIBLE || v.width == 0 || v.height == 0 || v.alpha <= 0f) continue
            val x = ox + v.left - group.scrollX + v.translationX.toInt()
            val y = oy + v.top - group.scrollY + v.translationY.toInt()
            val bridged = BridgeState.inspect(v)
            val cellIndex = bridged?.index?.takeIf { it >= 0 } ?: if (list) cellIndex(group, v, i) else -1
            val node = node(v, parent, x, y, cellIndex, inMask, bridged)
            all.add(node)
            parent.children.add(node)
            if (node.ignored || node.masked) continue
            if (v is ViewGroup) children(v, node, x, y, all, max, inMask || node.masked)
            if (Optional.compose && ComposeNodes.isRoot(v)) ComposeNodes.add(v, node, all, max)
        }
    }

    private fun cellIndex(list: ViewGroup, child: View, i: Int): Int = when {
        list is AdapterView<*> -> list.firstVisiblePosition + i
        Optional.recycler -> Recycler.position(list, child).let { if (it < 0) i else it }
        else -> i
    }

    private fun node(v: View, parent: UiNode, x: Int, y: Int, cellIndex: Int, inMask: Boolean, bridged: BridgeElement?): UiNode {
        val kind = bridged?.kind ?: kind(v, cellIndex >= 0)
        val id = explicitPart(v, bridged)
        val part = when {
            id != null -> id
            Optional.recycler && Recycler.isList(v) -> "RecyclerView"
            Optional.compose && ComposeNodes.isRoot(v) -> "Compose"
            else -> typePart(v, kind)
        }
        val interactive = bridged?.interactive ?: (
            cellIndex >= 0 || kind == "input" || v.isEnabled && (v.isClickable || v.isLongClickable)
            )
        val masked = inMask || flag(v, R.id.scruter_mask) || isTextInput(v) || v is WebView || bridged?.mask == true
        val ignored = flag(v, R.id.scruter_ignore) || bridged?.ignore == true
        val n = UiNode(parent, part, id != null, kind, interactive, masked, ignored, x, y, x + v.width, y + v.height,
            cellIndex, v)
        (bridged?.form ?: v.getTag(R.id.scruter_form)?.toString())?.let { n.form = Text.clean(it, 120) }
        return n
    }

    /** The kind of a team phone's tree: `web` (the server always masks that kind, §3.11) and `container` exist only there. */
    fun treeKind(n: UiNode): String = when {
        n.source is WebView -> "web"
        n.kind == "other" && n.explicit -> "container"
        else -> n.kind
    }

    /** A keyed tag set from code (`true`) or from a layout's `<tag android:value="true"/>` (a string). */
    private fun flag(v: View, id: Int): Boolean = v.getTag(id).let { it == true || it?.toString() == "true" }

    fun isTextInput(v: View): Boolean = v is EditText || v is TextView && v.onCheckIsTextEditor() && v.isEnabled

    /** The explicit identifier of a View (§3.5 step 3): `scruterId`, else the id's resource entry name when stable. */
    fun explicitId(v: View, bridged: BridgeElement? = BridgeState.inspect(v)): String? {
        bridged?.id?.let { if (Text.isStableId(it)) return it }
        v.getTag(R.id.scruter_id)?.toString()?.let { if (Text.isStableId(it)) return it }
        val id = v.id
        if (id == View.NO_ID || id ushr 24 == 0) return null
        val name = synchronized(entryNames) {
            if (entryNames.containsKey(id)) {
                entryNames[id]
            } else {
                val n = try {
                    v.resources.getResourceEntryName(id)
                } catch (e: Resources.NotFoundException) {
                    null
                }
                val stable = n?.takeIf { Text.isStableId(it) && !it.contains("resource_name_obfuscated") }
                entryNames[id] = stable
                stable
            }
        }
        return name
    }

    /**
     * The type part (§3.5 step 3) of a View: the class it declares to accessibility services (`Button` for a
     * MaterialButton, `CheckBox`, `ImageView`…). Unlike the class's own name, that string survives R8, which renames
     * app and library classes in release builds: a team phone's debug build names an element like a user's release
     * build. `[kind]` is added when the type says nothing (`View[button]`, `FrameLayout[cell]`).
     */
    private fun typePart(v: View, kind: String): String {
        val name = accessibilityName(v)
        if (name !in generic && !name.endsWith("Layout")) return name
        return kindParts.getOrPut(name) { HashMap() }.getOrPut(kind) { "$name[$kind]" }
    }

    /** `#id`, built once per id: a screen's tree is rebuilt at each tap. */
    private fun explicitPart(v: View, bridged: BridgeElement?): String? {
        val id = explicitId(v, bridged) ?: return null
        return idParts.getOrPut(id) { "#$id" }
    }

    private fun accessibilityName(v: View): String {
        val type = v.javaClass
        typeNames[type]?.let { return it }
        var full = v.accessibilityClassName?.toString().orEmpty()
        if (full.isEmpty() || full == type.name && !full.startsWith("android.")) {
            // A class that reports its own name (ComposeView does): R8 renames it, so its platform parent.
            var t: Class<*>? = type
            while (t != null && !t.name.startsWith("android.")) t = t.superclass
            full = t?.name ?: "View"
        }
        val simple = full.substring(full.lastIndexOf('.') + 1)
        val name = Text.cut(simple.substring(simple.lastIndexOf('$') + 1).trimStart('_').ifEmpty { "View" }, 40)
        typeNames[type] = name
        return name
    }

    fun kind(v: View, cell: Boolean): String {
        val name = accessibilityName(v)
        return when {
            isTextInput(v) -> "input"
            v is CompoundButton || v is SeekBar || v is RatingBar || v is Spinner -> "choice"
            name == "Tab" || name.endsWith("TabView") -> "tab"
            cell -> "cell"
            v is WebView || v is android.widget.VideoView || v is android.view.SurfaceView || v is android.view.TextureView -> "media"
            v is ImageButton || v is android.widget.Button -> "button"
            v is TextView -> when {
                v.isClickable && v.text is android.text.Spanned &&
                    (v.text as android.text.Spanned).getSpans(0, v.text.length, android.text.style.URLSpan::class.java).isNotEmpty() -> "link"
                v.isClickable -> "button"
                else -> "text"
            }
            v is ImageView -> if (v.isClickable) "button" else "image"
            v.isClickable -> "button"
            else -> "other"
        }
    }

    /** A visible indeterminate progress indicator: the screen is not idle (§3.12). */
    fun busy(root: View): Boolean {
        if (root is ProgressBar && root.isIndeterminate && root.isShown) return true
        if (root is ViewGroup) for (i in 0 until root.childCount) if (busy(root.getChildAt(i))) return true
        return false
    }

    /** A list's direct children are cells (§3.5 step 4). */
    fun isListContainer(v: View): Boolean = v is AbsListView || Optional.recycler && Recycler.isList(v)
}
