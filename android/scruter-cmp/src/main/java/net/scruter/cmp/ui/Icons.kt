package net.scruter.cmp.ui

import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.Drawable
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.sqrt

/**
 * The sheet's line icons, drawn from the site script's own SVG paths (`cmp/src/ui/v2/view.ts`, `ui/shared.ts`): one
 * small parser of SVG path data (M L H V C S Q A Z, absolute and relative), so that the module ships no vector asset
 * and no dependency.
 */
internal object Icons {
    const val CHEV = "M9 6l6 6-6 6"
    const val BACK = "M15 6l-6 6 6 6"
    const val CLOSE = "M6 6l12 12M18 6L6 18"
    const val PAUSE = "M9 6v12M15 6v12"
    const val PLAY = "M8 5.5v13l10.5-6.5z"
    const val COPY = "M9 9h11v11H9zM5 15H4V4h11v1"

    /** Icons of the purposes of the catalogue; any other purpose gets the sliders. */
    val PURPOSES: Map<String, String> = mapOf(
        "necessary" to "M6 11h12v9H6zM9 11V8a3 3 0 0 1 6 0v3",
        "analytics" to "M4 4v16h16M8 16v-4M12 16V8M16 16v-6",
        "embedded_content" to "M4 6h16v12H4zM10 9.5v5l4.5-2.5z",
        "advertising" to "M4 10v4h3l6 4V6l-6 4zM17 9a4 4 0 0 1 0 6",
    )
    const val SLIDERS = "M4 8h9M17 8h3M4 16h3M11 16h9M15 6v4M9 14v4"

    /** Scruter's mark: three arcs (in a 64 × 64 box) and their colours. */
    val ARCS = listOf("M47.32 44.86 A20 20 0 0 1 15.42 43.18", "M14.02 40.77 A20 20 0 0 1 23.87 13.73", "M26.49 12.78 A20 20 0 0 1 47.32 19.14")
    val ARC_COLORS = intArrayOf(0xFF6B4EFF.toInt(), 0xFF2BC48A.toInt(), 0xFFFFC233.toInt())

    /** Lower edges of the media header in a 400 × 22 box, filled with the sheet's surface. */
    val EDGES = mapOf(
        "curve" to "M0 22V10C60 20 150 22 232 12S360 0 400 6V22Z",
        "angle" to "M0 22V4L400 18V22Z",
    )

    fun purpose(key: String): String = PURPOSES[key] ?: SLIDERS

    /** Parses SVG path data into a [Path]. */
    fun path(d: String): Path {
        val p = Path()
        val t = Tokens(d)
        var cx = 0f
        var cy = 0f
        var sx = 0f
        var sy = 0f
        var lastCtrlX = 0f
        var lastCtrlY = 0f
        var cmd = 'M'
        var prev = ' '
        while (t.more()) {
            if (t.isCommand()) cmd = t.command()
            val rel = cmd.isLowerCase()
            val ox = if (rel) cx else 0f
            val oy = if (rel) cy else 0f
            when (cmd.uppercaseChar()) {
                'M' -> {
                    cx = ox + t.num(); cy = oy + t.num()
                    p.moveTo(cx, cy)
                    sx = cx; sy = cy
                    // Further pairs are line-tos.
                    cmd = if (rel) 'l' else 'L'
                }
                'L' -> { cx = ox + t.num(); cy = oy + t.num(); p.lineTo(cx, cy) }
                'H' -> { cx = ox + t.num(); p.lineTo(cx, cy) }
                'V' -> { cy = oy + t.num(); p.lineTo(cx, cy) }
                'C' -> {
                    val x1 = ox + t.num(); val y1 = oy + t.num()
                    val x2 = ox + t.num(); val y2 = oy + t.num()
                    cx = ox + t.num(); cy = oy + t.num()
                    p.cubicTo(x1, y1, x2, y2, cx, cy)
                    lastCtrlX = x2; lastCtrlY = y2
                }
                'S' -> {
                    val x1 = if (prev.uppercaseChar() == 'C' || prev.uppercaseChar() == 'S') 2 * cx - lastCtrlX else cx
                    val y1 = if (prev.uppercaseChar() == 'C' || prev.uppercaseChar() == 'S') 2 * cy - lastCtrlY else cy
                    val x2 = ox + t.num(); val y2 = oy + t.num()
                    cx = ox + t.num(); cy = oy + t.num()
                    p.cubicTo(x1, y1, x2, y2, cx, cy)
                    lastCtrlX = x2; lastCtrlY = y2
                }
                'Q' -> {
                    val x1 = ox + t.num(); val y1 = oy + t.num()
                    cx = ox + t.num(); cy = oy + t.num()
                    p.quadTo(x1, y1, cx, cy)
                }
                'A' -> {
                    val rx = t.num(); val ry = t.num(); val rot = t.num()
                    val large = t.num() != 0f; val sweep = t.num() != 0f
                    val x = ox + t.num(); val y = oy + t.num()
                    arc(p, cx, cy, x, y, rx, ry, rot, large, sweep)
                    cx = x; cy = y
                }
                'Z' -> { p.close(); cx = sx; cy = sy }
                else -> return p
            }
            prev = cmd
        }
        return p
    }

    /** An SVG elliptical arc (circular here: the icons' arcs have rx = ry, no rotation) through Path.arcTo. */
    private fun arc(p: Path, x1: Float, y1: Float, x2: Float, y2: Float, rx0: Float, ry0: Float, rot: Float, large: Boolean, sweep: Boolean) {
        if (rx0 == 0f || ry0 == 0f || (x1 == x2 && y1 == y2)) {
            p.lineTo(x2, y2)
            return
        }
        // Endpoint to centre parameterisation (SVG 1.1, appendix F.6), for rx = ry and no rotation.
        var r = abs(rx0)
        val dx = (x1 - x2) / 2
        val dy = (y1 - y2) / 2
        val d2 = dx * dx + dy * dy
        if (d2 > r * r) r = sqrt(d2)
        val sign = if (large == sweep) -1f else 1f
        val coef = sign * sqrt(((r * r - d2) / d2).coerceAtLeast(0f))
        val cxp = coef * dy
        val cyp = -coef * dx
        val cx = cxp + (x1 + x2) / 2
        val cy = cyp + (y1 + y2) / 2
        fun angle(ux: Float, uy: Float, vx: Float, vy: Float): Float {
            val dot = ux * vx + uy * vy
            val len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos((dot / len).coerceIn(-1f, 1f))
            if (ux * vy - uy * vx < 0) a = -a
            return a
        }
        val start = angle(1f, 0f, (dx - cxp) / r, (dy - cyp) / r)
        var delta = angle((dx - cxp) / r, (dy - cyp) / r, (-dx - cxp) / r, (-dy - cyp) / r)
        if (!sweep && delta > 0) delta -= (2 * PI).toFloat()
        if (sweep && delta < 0) delta += (2 * PI).toFloat()
        p.arcTo(RectF(cx - r, cy - r, cx + r, cy + r), Math.toDegrees(start.toDouble()).toFloat(), Math.toDegrees(delta.toDouble()).toFloat(), false)
        if (rot != 0f) p.lineTo(x2, y2)
    }

    private class Tokens(private val s: String) {
        private var i = 0

        private fun skip() {
            while (i < s.length && (s[i] == ' ' || s[i] == ',' || s[i] == '\n')) i++
        }

        fun more(): Boolean {
            skip()
            return i < s.length
        }

        fun isCommand(): Boolean {
            skip()
            return i < s.length && s[i].isLetter() && s[i] != 'e' && s[i] != 'E'
        }

        fun command(): Char = s[i++]

        fun num(): Float {
            skip()
            val start = i
            if (i < s.length && (s[i] == '-' || s[i] == '+')) i++
            var dot = false
            while (i < s.length) {
                val c = s[i]
                if (c.isDigit()) i++
                else if (c == '.' && !dot) { dot = true; i++ }
                else if ((c == 'e' || c == 'E') && i + 1 < s.length) {
                    i++
                    if (s[i] == '-' || s[i] == '+') i++
                } else break
            }
            return s.substring(start, i).toFloatOrNull() ?: 0f
        }
    }
}

/**
 * A stroked line icon in a [box] × [box] viewbox (24 for the icons, 64 for the mark), scaled to its bounds, in one
 * colour or in Scruter's colours.
 */
internal class IconDrawable(
    paths: List<String>,
    private val box: Float,
    private val sizePx: Int,
    color: Int,
    strokeWidth: Float = 2f,
    private val colors: IntArray? = null,
    fill: Boolean = false,
    private val mirror: Boolean = false,
) : Drawable() {
    private val parsed = paths.map { Icons.path(it) }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = if (fill) Paint.Style.FILL else Paint.Style.STROKE
        this.strokeWidth = strokeWidth
        strokeCap = if (colors != null) Paint.Cap.BUTT else Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        this.color = color
    }

    override fun draw(canvas: Canvas) {
        val b = bounds
        val s = minOf(b.width(), b.height()) / box
        canvas.save()
        canvas.translate(b.left + (b.width() - box * s) / 2, b.top + (b.height() - box * s) / 2)
        canvas.scale(s, s)
        if (mirror) {
            canvas.scale(-1f, 1f, box / 2, box / 2)
        }
        parsed.forEachIndexed { i, p ->
            if (colors != null) paint.color = colors[i % colors.size]
            canvas.drawPath(p, paint)
        }
        canvas.restore()
    }

    override fun getIntrinsicWidth(): Int = sizePx

    override fun getIntrinsicHeight(): Int = sizePx

    override fun setAlpha(alpha: Int) {
        paint.alpha = alpha
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        paint.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}
