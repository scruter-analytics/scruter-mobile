package net.scruter.cmp.internal

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * The web's colour rules (docs/CMP.md §4.5, `cmp/src/shared/color.ts`, `cmp/src/ui/v2/style.ts`), so that the sheet
 * keeps the banner's contrasts: the label on the brand colour (white or ink, ≥ 4.5:1), the brand colour of the dark
 * theme (lightened until it reaches 3:1 on the dark surface), the kicker and the tinted panel.
 */
internal object Colors {
    const val INK = "#17131F"
    const val WHITE = "#FFFFFF"
    const val DARK_BG = "#1E1A27"

    fun safe(hex: String): String = if (Regex("^#[0-9a-fA-F]{6}$").matches(hex)) hex.uppercase() else "#6B4EFF"

    fun argb(hex: String): Int = (0xFF000000.toInt()) or safe(hex).substring(1).toInt(16)

    private fun channel(v: Int): Double {
        val c = v / 255.0
        return if (c <= 0.03928) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
    }

    fun luminance(hex: String): Double {
        val n = safe(hex).substring(1).toInt(16)
        return 0.2126 * channel((n shr 16) and 255) + 0.7152 * channel((n shr 8) and 255) + 0.0722 * channel(n and 255)
    }

    fun contrast(a: String, b: String): Double {
        val x = luminance(a)
        val y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /** White or ink on [bg], whichever contrasts more. */
    fun onColor(bg: String): String = if (contrast(bg, WHITE) >= contrast(bg, INK)) WHITE else INK

    /** [p] darkened (white text) or lightened (ink text) in small steps until its text contrasts [min]:1, hue kept
     *  (`cmp/src/ui/style.ts` `strengthen`). */
    fun strengthen(p: String, min: Double): String {
        var c = p
        var i = 0
        while (i < 40 && contrast(c, onColor(c)) < min) {
            val n = c.substring(1).toInt(16)
            val to = if (onColor(c) == WHITE) 0 else 255
            fun ch(s: Int) = Math.round(((n shr s) and 255) * 0.92 + to * 0.08).toInt()
            c = String.format("#%02X%02X%02X", ch(16), ch(8), ch(0))
            i++
        }
        return c
    }

    /** The brand colour on the dark theme: itself at 3:1 on the dark surface, else lightened (HSL) until it is. */
    fun darkBrand(p: String): String {
        if (contrast(p, DARK_BG) >= 3) return p
        val n = safe(p).substring(1).toInt(16)
        val r = ((n shr 16) and 255) / 255.0
        val g = ((n shr 8) and 255) / 255.0
        val b = (n and 255) / 255.0
        val mx = max(r, max(g, b))
        val d = mx - min(r, min(g, b))
        if (d < 0.1) return WHITE
        var l = mx - d / 2
        val s = d / (1 - abs(2 * l - 1))
        val h = when (mx) {
            r -> ((g - b) / d + 6) % 6
            g -> (b - r) / d + 2
            else -> (r - g) / d + 4
        }
        while (l < 1) {
            val k = (1 - abs(2 * l - 1)) * s
            val x = k * (1 - abs((h % 2) - 1))
            val rgb = when (h.toInt() % 6) {
                0 -> doubleArrayOf(k, x, 0.0)
                1 -> doubleArrayOf(x, k, 0.0)
                2 -> doubleArrayOf(0.0, k, x)
                3 -> doubleArrayOf(0.0, x, k)
                4 -> doubleArrayOf(x, 0.0, k)
                else -> doubleArrayOf(k, 0.0, x)
            }
            val q = "#" + rgb.joinToString("") { v -> hex2(((v + l - k / 2) * 255).roundToInt()) }
            if (contrast(q, DARK_BG) >= 3 && contrast(q, onColor(q)) >= 4.5) return q
            l += 0.01
        }
        return WHITE
    }

    private fun hex2(v: Int): String {
        val c = v.coerceIn(0, 255)
        return "0123456789ABCDEF"[c shr 4].toString() + "0123456789ABCDEF"[c and 15]
    }

    /** `share` of [a] mixed into [b]. */
    fun mix(a: String, b: String, share: Double): String {
        val x = safe(a).substring(1).toInt(16)
        val y = safe(b).substring(1).toInt(16)
        return "#" + intArrayOf(16, 8, 0).joinToString("") { k ->
            hex2((((x shr k) and 255) * share + ((y shr k) and 255) * (1 - share)).roundToInt())
        }
    }
}

/** The colours of one sheet (light or dark), from the banner's colour. */
/** [min]: the contrast of the primary buttons' text (5 with the IAB TCF, TCF Policies Appendix B C(g)). */
internal class Palette(color: String, val dark: Boolean, min: Double = 0.0) {
    val bg: String = if (dark) Colors.DARK_BG else Colors.WHITE
    val fg: String = if (dark) "#FFFFFF" else Colors.INK
    /** Secondary text: `rgba(255,255,255,.82)` on dark, `#4D4859` on light, as on the web. */
    val sub: String = if (dark) "#D6D5D8" else "#4D4859"
    val line: String = if (dark) "#4B4853" else "#E1E0E4"
    /** The joined row's edge: a control's boundary at 3:1 on the surface (WCAG 1.4.11). */
    val edge: String = if (dark) "#8F899E" else "#8C8799"
    val soft: String = if (dark) "#34303C" else "#F3F3F7"
    /** The brand colour of this theme and its label. */
    val brand: String = Colors.strengthen(if (dark) Colors.darkBrand(Colors.safe(color)) else Colors.safe(color), min)
    val onBrand: String = Colors.onColor(brand)
    /** The kicker and the step icons: the brand colour where it reads at 4.5:1, else the text colour. */
    val kick: String = if (Colors.contrast(brand, bg) >= 4.5) brand else fg
    /** The tinted panel: 14 % of the brand colour. */
    val tint: String = Colors.mix(brand, bg, 0.14)
    /** « Tout accepter » gets an edge where its fill is under 3:1 against the surface. */
    val brandEdge: Boolean = Colors.contrast(brand, bg) < 3
}
