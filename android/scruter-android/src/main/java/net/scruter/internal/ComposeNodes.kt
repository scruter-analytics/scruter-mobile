package net.scruter.internal

import android.view.View
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsConfiguration
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import net.scruter.compose.ScruterSemantics

/**
 * Jetpack Compose through its semantics tree (the unmerged one: every node with semantics), loaded only when the app
 * has Compose ([Optional.compose]). Identity (§3.5): `Modifier.scruterId`, else a stable `Modifier.testTag`, else the
 * node's role (`Button`, `Checkbox`, `Tab`…), `TextField`, `Text`, or `Node[kind]`.
 */
internal object ComposeNodes {
    fun probe(): Any = ViewRootForTest::class.java

    fun isRoot(v: View): Boolean = v is ViewRootForTest

    fun root(v: View): SemanticsNode? = try {
        (v as ViewRootForTest).semanticsOwner.unmergedRootSemanticsNode
    } catch (e: Exception) {
        null
    }

    fun add(view: View, parent: UiNode, all: ArrayList<UiNode>, max: Int) {
        val root = root(view) ?: return
        visit(root.children, parent, all, max, -1, parent.masked)
    }

    private fun visit(nodes: List<SemanticsNode>, parent: UiNode, all: ArrayList<UiNode>, max: Int, firstIndex: Int, inMask: Boolean) {
        for ((i, n) in nodes.withIndex()) {
            if (all.size >= max) return
            val c = n.config
            if (c.contains(SemanticsProperties.InvisibleToUser)) continue
            val b = n.boundsInWindow
            if (b.width <= 0f || b.height <= 0f) continue
            val node = node(n, c, parent, if (firstIndex >= 0) firstIndex + i else -1, inMask)
            all.add(node)
            parent.children.add(node)
            if (node.ignored || node.masked) continue
            visit(n.children, node, all, max, if (isLazyList(c)) firstVisible(c) else -1, false)
        }
    }

    private fun isLazyList(c: SemanticsConfiguration) = c.contains(SemanticsActions.ScrollToIndex)

    /** A lazy list's first visible item: its scroll axis value is the item index (offset in its fraction). */
    private fun firstVisible(c: SemanticsConfiguration): Int {
        val r = c.getOrNull(SemanticsProperties.VerticalScrollAxisRange) ?: c.getOrNull(SemanticsProperties.HorizontalScrollAxisRange)
        return r?.value?.invoke()?.toInt()?.coerceAtLeast(0) ?: 0
    }

    private fun node(n: SemanticsNode, c: SemanticsConfiguration, parent: UiNode, cellIndex: Int, inMask: Boolean): UiNode {
        val role = c.getOrNull(SemanticsProperties.Role)
        val clickable = c.contains(SemanticsActions.OnClick) || c.contains(SemanticsActions.OnLongClick)
        val disabled = c.contains(SemanticsProperties.Disabled)
        val editable = c.contains(SemanticsProperties.EditableText)
        val toggle = c.contains(SemanticsProperties.ToggleableState)
        val text = c.contains(SemanticsProperties.Text)
        val kind = when {
            editable -> "input"
            role == Role.Checkbox || role == Role.Switch || role == Role.RadioButton || role == Role.DropdownList || toggle -> "choice"
            role == Role.Tab -> "tab"
            cellIndex >= 0 -> "cell"
            role == Role.Image && !clickable -> "image"
            clickable -> "button"
            text -> "text"
            c.contains(SemanticsProperties.ContentDescription) && n.children.isEmpty() -> "image"
            else -> "other"
        }
        val id = c.getOrNull(ScruterSemantics.Id)?.takeIf { Text.isStableId(it) }
            ?: c.getOrNull(SemanticsProperties.TestTag)?.takeIf { Text.isStableId(it) }
        val part = when {
            id != null -> "#$id"
            role != null -> role.toString()
            editable -> "TextField"
            text && !clickable -> "Text"
            isLazyList(c) -> "LazyList"
            else -> "Node[$kind]"
        }
        val masked = inMask || c.contains(ScruterSemantics.Mask) || editable || c.contains(SemanticsProperties.Password)
        val b = n.boundsInWindow
        val node = UiNode(parent, part, id != null, kind, (clickable || toggle) && !disabled || editable, masked,
            c.contains(ScruterSemantics.Ignore), b.left.toInt(), b.top.toInt(), b.right.toInt(), b.bottom.toInt(), cellIndex, n)
        c.getOrNull(ScruterSemantics.Form)?.let { node.form = Text.clean(it, 120) }
        return node
    }

    /** The label of the team phones' capture (§3.12): content description, else visible text, ≤ 80 characters. */
    fun label(n: Any?): String? {
        val c = (n as? SemanticsNode)?.config ?: return null
        val d = c.getOrNull(SemanticsProperties.ContentDescription)?.joinToString(" ")
        val t = c.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }
        return Text.clean(d ?: t, 80)
    }

    fun id(n: Any?): Int = (n as? SemanticsNode)?.id ?: 0

    /** Field facts for forms (§3.9): focused, has an error, a password, a fingerprint of its text (never kept). */
    fun focused(n: Any?): Boolean = (n as? SemanticsNode)?.config?.getOrNull(SemanticsProperties.Focused) == true

    fun hasError(n: Any?): Boolean = (n as? SemanticsNode)?.config?.contains(SemanticsProperties.Error) == true

    fun isPassword(n: Any?): Boolean = (n as? SemanticsNode)?.config?.contains(SemanticsProperties.Password) == true

    fun textHash(n: Any?): Int = (n as? SemanticsNode)?.config?.getOrNull(SemanticsProperties.EditableText)?.hashCode() ?: 0

    fun isField(n: Any?): Boolean {
        val c = (n as? SemanticsNode)?.config ?: return false
        return c.contains(SemanticsProperties.EditableText) || c.contains(SemanticsProperties.ToggleableState)
    }

    fun fieldType(n: Any?): String {
        val c = (n as? SemanticsNode)?.config ?: return "text"
        return when (c.getOrNull(SemanticsProperties.Role)) {
            Role.Switch -> "switch"
            Role.Checkbox -> "checkbox"
            Role.RadioButton -> "radio"
            Role.DropdownList -> "select"
            else -> if (c.contains(SemanticsProperties.EditableText)) "text" else "choice"
        }
    }

    /**
     * The primary vertical scroll container (§3.7) among the semantics nodes of [v] covering at least [minArea] px²:
     * (depth 0–1, band start, band end, content height px), or null.
     */
    fun scroll(v: View, minArea: Float): FloatArray? {
        val root = root(v) ?: return null
        var best: FloatArray? = null
        var bestArea = minArea
        fun walk(n: SemanticsNode) {
            val c = n.config
            val r = c.getOrNull(SemanticsProperties.VerticalScrollAxisRange)
            if (r != null) {
                val b = n.boundsInWindow
                val area = b.width * b.height
                val max = r.maxValue()
                if (area >= bestArea && max > 0f) {
                    val value = r.value().coerceIn(0f, max)
                    val viewport = b.height
                    best = if (isLazyList(c)) {
                        val count = c.getOrNull(SemanticsProperties.CollectionInfo)?.rowCount ?: -1
                        val visible = n.children.size.toFloat()
                        val first = value.toInt().toFloat()
                        if (count > 0) {
                            floatArrayOf(((first + visible) / count).coerceAtMost(1f), first / count, ((first + visible) / count).coerceAtMost(1f), viewport * count / visible.coerceAtLeast(1f))
                        } else {
                            val total = max + visible
                            floatArrayOf(if (value >= max) 1f else (value + visible) / total, value / total, (value + visible) / total, viewport * total / visible.coerceAtLeast(1f))
                        }
                    } else {
                        val content = viewport + max
                        floatArrayOf((value + viewport) / content, value / content, (value + viewport) / content, content)
                    }
                    bestArea = area
                }
            }
            for (ch in n.children) walk(ch)
        }
        walk(root)
        return best
    }

    /** Scrolls the container by [dy] px for the capture (§3.12): `false` when it cannot. */
    fun scrollBy(v: View, dy: Float): Boolean {
        val root = root(v) ?: return false
        var target: SemanticsNode? = null
        var area = 0f
        fun walk(n: SemanticsNode) {
            if (n.config.contains(SemanticsActions.ScrollBy) && n.config.getOrNull(SemanticsProperties.VerticalScrollAxisRange) != null) {
                val a = n.boundsInWindow.width * n.boundsInWindow.height
                if (a > area) {
                    area = a
                    target = n
                }
            }
            for (ch in n.children) walk(ch)
        }
        walk(root)
        val t = target ?: return false
        return t.config.getOrNull(SemanticsActions.ScrollBy)?.action?.invoke(0f, dy) ?: false
    }

    fun busy(v: View): Boolean {
        val root = root(v) ?: return false
        fun walk(n: SemanticsNode): Boolean {
            val p = n.config.getOrNull(SemanticsProperties.ProgressBarRangeInfo)
            if (p != null && p.range.start == 0f && p.range.endInclusive == 0f && p.current == 0f) return true
            return n.children.any { walk(it) }
        }
        return walk(root)
    }
}
