package net.scruter.cmp.ui

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.text.TextPaint
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.CompoundButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

internal fun Context.dp(v: Float): Int = Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics))

internal fun Context.dp(v: Int): Int = dp(v.toFloat())

internal fun color(hex: String): Int = Color.parseColor(hex)

internal fun withAlpha(c: Int, alpha: Float): Int = (Math.round(alpha * 255) shl 24) or (c and 0xFFFFFF)

/** Roboto at the platform's weights: `sans-serif` (400) and `sans-serif-medium` (500), bold for « Tout accepter ». */
internal object Type {
    val regular: Typeface = Typeface.create("sans-serif", Typeface.NORMAL)
    val medium: Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    val bold: Typeface = Typeface.create("sans-serif", Typeface.BOLD)
}

internal fun TextView.style(sp: Float, face: Typeface, colour: Int, lineHeight: Float = 0f) {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
    typeface = face
    setTextColor(colour)
    if (lineHeight > 0) setLineSpacing(0f, lineHeight)
    // Each paragraph's direction from its first strong letter; aligned to the start of the sheet's own direction.
    textAlignment = View.TEXT_ALIGNMENT_VIEW_START
}

internal fun rounded(fill: Int, radius: Float, stroke: Int = 0, strokeColour: Int = 0): GradientDrawable = GradientDrawable().apply {
    setColor(fill)
    cornerRadius = radius
    if (stroke > 0) setStroke(stroke, strokeColour)
}

/** A pressed state for a surface (ripple in the text colour, bounded). */
internal fun ripple(base: Drawable?, ink: Int): RippleDrawable =
    RippleDrawable(ColorStateList.valueOf(withAlpha(ink, 0.16f)), base, base ?: ColorDrawable(Color.WHITE))

/**
 * A vertical or horizontal box whose content stays inside its rounded corners: clipped with a path when drawn, so
 * that the corners hold in software rendering too (screenshots), and outlined for the shadow.
 */
internal open class RoundedLayout(context: Context) : LinearLayout(context) {
    /** Radii of the top and bottom corners. */
    var top = 0f
    var bottom = 0f
    private val path = Path()
    private val rect = RectF()

    /** An edge drawn over the content (the joined row's outline stays visible over its parts). */
    var edgeColor = 0
    var edgeWidth = 0f
    private val edgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }

    init {
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                val extra = if (bottom == 0f) top.toInt() else 0
                outline.setRoundRect(0, 0, view.width, view.height + extra, top)
            }
        }
    }

    fun corners(top: Float, bottom: Float) {
        this.top = top
        this.bottom = bottom
        invalidateOutline()
        invalidate()
    }

    override fun draw(canvas: Canvas) {
        if (top == 0f && bottom == 0f) return super.draw(canvas)
        path.reset()
        rect.set(0f, 0f, width.toFloat(), height.toFloat())
        path.addRoundRect(rect, floatArrayOf(top, top, top, top, bottom, bottom, bottom, bottom), Path.Direction.CW)
        val save = canvas.save()
        canvas.clipPath(path)
        super.draw(canvas)
        canvas.restoreToCount(save)
        if (edgeWidth > 0) {
            val h = edgeWidth / 2
            rect.set(h, h, width - h, height - h)
            path.reset()
            path.addRoundRect(rect, floatArrayOf(top - h, top - h, top - h, top - h, bottom - h, bottom - h, bottom - h, bottom - h), Path.Direction.CW)
            edgePaint.color = edgeColor
            edgePaint.strokeWidth = edgeWidth
            canvas.drawPath(path, edgePaint)
        }
    }
}

/** A colour with only its top corners rounded (the bottom sheet), or all of them. */
internal fun roundedTop(fill: Int, top: Float, bottom: Float): GradientDrawable = GradientDrawable().apply {
    setColor(fill)
    cornerRadii = floatArrayOf(top, top, top, top, bottom, bottom, bottom, bottom)
}

/**
 * The Material 3 switch (52 × 32 dp in a 48 dp target): the thumb grows when on, so its state reads by shape, not only
 * by colour. TalkBack announces it as a switch with its state.
 */
internal class M3Switch(context: Context, private val on: Int, private val onThumb: Int, private val off: Int, private val offTrack: Int, private val animate: Boolean) :
    CompoundButton(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var t = 0f
    private var anim: ValueAnimator? = null

    init {
        buttonDrawable = null
        background = null
        minimumWidth = context.dp(60)
        minimumHeight = context.dp(48)
        // A CompoundButton built without a style is neither clickable nor focusable: a touch would not toggle it.
        isClickable = true
        isFocusable = true
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(resolveSize(context.dp(60), widthMeasureSpec), resolveSize(context.dp(48), heightMeasureSpec))
    }

    override fun setChecked(checked: Boolean) {
        val changed = checked != isChecked
        super.setChecked(checked)
        val target = if (checked) 1f else 0f
        anim?.cancel()
        if (changed && animate && isAttachedToWindow) {
            anim = ValueAnimator.ofFloat(t, target).setDuration(180).apply {
                addUpdateListener { t = it.animatedValue as Float; invalidate() }
                start()
            }
        } else {
            t = target
            invalidate()
        }
    }

    override fun onDraw(canvas: Canvas) {
        val d = resources.displayMetrics.density
        val w = 52 * d
        val h = 32 * d
        val left = if (layoutDirection == View.LAYOUT_DIRECTION_RTL) (width - w) / 2 else (width - w) / 2
        val top = (height - h) / 2
        val rect = RectF(left, top, left + w, top + h)
        val r = h / 2
        // Track: outlined when off, filled with the brand colour when on.
        paint.style = Paint.Style.FILL
        paint.color = blend(offTrack, on, t)
        canvas.drawRoundRect(rect, r, r, paint)
        if (t < 1f) {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 2 * d
            paint.color = withAlpha(off, 1f - t)
            val inset = d
            canvas.drawRoundRect(RectF(rect.left + inset, rect.top + inset, rect.right - inset, rect.bottom - inset), r - inset, r - inset, paint)
        }
        // Thumb: 16 dp off, 24 dp on.
        paint.style = Paint.Style.FILL
        val radius = (8 + 4 * t) * d
        val rtl = layoutDirection == View.LAYOUT_DIRECTION_RTL
        val p = if (rtl) 1 - t else t
        val cx = rect.left + (16 + 20 * p) * d
        paint.color = blend(off, onThumb, t)
        canvas.drawCircle(cx, rect.centerY(), radius, paint)
    }

    override fun getAccessibilityClassName(): CharSequence = "android.widget.Switch"

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.isCheckable = true
        info.isChecked = isChecked
    }

    private fun blend(a: Int, b: Int, f: Float): Int {
        val inv = 1 - f
        return Color.argb(
            Math.round(Color.alpha(a) * inv + Color.alpha(b) * f),
            Math.round(Color.red(a) * inv + Color.red(b) * f),
            Math.round(Color.green(a) * inv + Color.green(b) * f),
            Math.round(Color.blue(a) * inv + Color.blue(b) * f),
        )
    }
}

/**
 * The joined row (docs/CMP.md §4.5): equal parts in one pill, one 1 dp divider between them, at 14.5 sp, else 13 sp,
 * else one joined column, same order, each part on the whole width (font scale up to 200 %, docs/CMP-MOBILE.md §3.12).
 */
@SuppressLint("ViewConstructor")
internal class JoinedRow(context: Context, private val edge: Int, private val surface: Int) : RoundedLayout(context) {
    private val buttons = ArrayList<Button>()
    private val dividers = ArrayList<View>()
    var column = false
        private set
    private var laidOut = false
    private var textSp = 0f
    private val radiusRow = context.dp(24).toFloat()
    private val radiusColumn = context.dp(20).toFloat()

    init {
        orientation = HORIZONTAL
        background = rounded(surface, radiusRow)
        edgeColor = edge
        edgeWidth = context.dp(1).toFloat()
        corners(radiusRow, radiusRow)
        setPadding(context.dp(1), context.dp(1), context.dp(1), context.dp(1))
    }

    fun add(b: Button) {
        if (buttons.isNotEmpty()) {
            val d = View(context).apply { setBackgroundColor(edge); importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
            dividers.add(d)
            addView(d)
        }
        buttons.add(b)
        addView(b)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec) - paddingLeft - paddingRight
        val n = buttons.size.coerceAtLeast(1)
        val part = (width - dividers.size * context.dp(1)) / n
        var fits = false
        var size = 13f
        for (sp in floatArrayOf(14.5f, 13f)) {
            val paint = TextPaint().apply { textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, resources.displayMetrics) }
            fits = buttons.all { b ->
                paint.typeface = b.typeface
                paint.measureText(b.text.toString()) <= part - b.paddingLeft - b.paddingRight
            }
            size = sp
            if (fits) break
        }
        if (size != textSp) {
            textSp = size
            buttons.forEach { it.setTextSize(TypedValue.COMPLEX_UNIT_SP, size) }
        }
        if (!laidOut || column != !fits) {
            laidOut = true
            column = !fits
            orientation = if (column) VERTICAL else HORIZONTAL
            background = rounded(surface, if (column) radiusColumn else radiusRow)
            corners(if (column) radiusColumn else radiusRow, if (column) radiusColumn else radiusRow)
            for (b in buttons) {
                b.layoutParams = if (column) LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT) else LayoutParams(0, LayoutParams.MATCH_PARENT, 1f)
                b.maxLines = if (column) 3 else 1
            }
            for (d in dividers) d.layoutParams = if (column) LayoutParams(LayoutParams.MATCH_PARENT, context.dp(1)) else LayoutParams(context.dp(1), LayoutParams.MATCH_PARENT)
        }
        super.onMeasure(widthMeasureSpec, if (column) heightMeasureSpec else MeasureSpec.makeMeasureSpec(maxButtonHeight(widthMeasureSpec), MeasureSpec.EXACTLY))
    }

    private fun maxButtonHeight(widthMeasureSpec: Int): Int {
        var h = context.dp(48)
        val part = MeasureSpec.getSize(widthMeasureSpec) / buttons.size.coerceAtLeast(1)
        for (b in buttons) {
            b.measure(MeasureSpec.makeMeasureSpec(part, MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
            h = maxOf(h, b.measuredHeight)
        }
        return h + paddingTop + paddingBottom
    }
}

/**
 * A one-line label that gives up its first words when its box is too narrow (« Certifié par Scruter » → « Scruter »
 * beside the mark, as the site script's band does at a large font size); TalkBack reads the whole label.
 */
@SuppressLint("ViewConstructor", "AppCompatCustomView")
internal class FitText(context: Context, private val full: CharSequence, private val short: CharSequence) : TextView(context) {
    init {
        text = full
        setSingleLine(true)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val mode = MeasureSpec.getMode(widthMeasureSpec)
        if (mode != MeasureSpec.UNSPECIFIED) {
            val room = MeasureSpec.getSize(widthMeasureSpec) - totalPaddingLeft - totalPaddingRight
            val want = if (paint.measureText(full.toString()) <= room) full else short
            if (text.toString() != want.toString()) text = want
        }
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }
}

/** A part of the joined row: a real button (TalkBack, keyboard), 48 dp high at least. */
internal fun Context.joinedButton(label: String, fill: Int, ink: Int, bold: Boolean): Button = Button(this).apply {
    text = label
    isAllCaps = false
    stateListAnimator = null
    gravity = Gravity.CENTER
    minHeight = dp(48)
    minimumHeight = dp(48)
    minWidth = 0
    minimumWidth = 0
    setPadding(dp(6), dp(10), dp(6), dp(10))
    style(14.5f, if (bold) Type.bold else Type.medium, ink)
    textAlignment = View.TEXT_ALIGNMENT_CENTER
    background = ripple(ColorDrawable(fill), ink)
}

/** The app's icon astride the media header: the store icon on a 56 dp disc, an uploaded logo on a plate. */
internal class IconBadge(context: Context, bitmap: Bitmap, disc: Boolean, surface: Int, line: Int) : LinearLayout(context) {
    init {
        gravity = Gravity.CENTER
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        val img = ImageView(context)
        img.setImageBitmap(bitmap)
        if (disc) {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(surface); setStroke(context.dp(1), line) }
            elevation = context.dp(3).toFloat()
            outlineProvider = ViewOutlineProvider.BACKGROUND
            img.setImageDrawable(CircleBitmap(bitmap))
            addView(img, LayoutParams(context.dp(38), context.dp(38)))
            layoutParams = ViewGroup.LayoutParams(context.dp(56), context.dp(56))
        } else {
            background = rounded(surface, context.dp(12).toFloat(), context.dp(1), line)
            elevation = context.dp(3).toFloat()
            img.scaleType = ImageView.ScaleType.FIT_CENTER
            img.adjustViewBounds = true
            img.maxWidth = context.dp(220)
            setPadding(context.dp(12), 0, context.dp(12), 0)
            addView(img, LayoutParams(LayoutParams.WRAP_CONTENT, context.dp(24)))
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, context.dp(44))
        }
    }
}

/** A bitmap drawn in a circle, cropped to its centre (the store icon on its disc). */
internal class CircleBitmap(private val bitmap: Bitmap) : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
        shader = android.graphics.BitmapShader(bitmap, android.graphics.Shader.TileMode.CLAMP, android.graphics.Shader.TileMode.CLAMP)
    }
    private val m = Matrix()

    override fun draw(canvas: Canvas) {
        val b = bounds
        val side = minOf(b.width(), b.height()).toFloat()
        val s = side / minOf(bitmap.width, bitmap.height)
        m.setScale(s, s)
        m.postTranslate(b.exactCenterX() - bitmap.width * s / 2, b.exactCenterY() - bitmap.height * s / 2)
        paint.shader.setLocalMatrix(m)
        canvas.drawCircle(b.exactCenterX(), b.exactCenterY(), side / 2, paint)
    }

    override fun getIntrinsicWidth(): Int = bitmap.width

    override fun getIntrinsicHeight(): Int = bitmap.height

    override fun setAlpha(alpha: Int) {
        paint.alpha = alpha
    }

    override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) {
        paint.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = android.graphics.PixelFormat.TRANSLUCENT
}

/** The lower edge of the media header (curve, angle), filled with the sheet's surface. */
internal class EdgeView(context: Context, shape: String, private val fill: Int) : View(context) {
    private val path = Icons.EDGES[shape]?.let { Icons.path(it) }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = fill; style = Paint.Style.FILL }
    private val m = Matrix()
    private val scaled = Path()

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onDraw(canvas: Canvas) {
        val p = path ?: return
        m.setScale(width / 400f, height / 22f)
        if (layoutDirection == LAYOUT_DIRECTION_RTL) m.postScale(-1f, 1f, width / 2f, 0f)
        p.transform(m, scaled)
        canvas.drawPath(scaled, paint)
    }
}

/** An image cropped like CSS `object-fit: cover` with `object-position` at the focal point. */
internal fun cover(view: View, contentW: Int, contentH: Int, focalX: Int, focalY: Int): Matrix {
    val m = Matrix()
    if (contentW <= 0 || contentH <= 0 || view.width == 0) return m
    val s = maxOf(view.width / contentW.toFloat(), view.height / contentH.toFloat())
    val dx = (view.width - contentW * s) * focalX / 100f
    val dy = (view.height - contentH * s) * focalY / 100f
    m.setScale(s, s)
    m.postTranslate(dx, dy)
    return m
}

/** A pill drawn inside a larger target (« Continuer sans accepter »: 32 dp of pill in a 48 dp target). */
internal fun pillBackground(context: Context, fill: Int, ink: Int): Drawable =
    InsetDrawable(ripple(rounded(fill, context.dp(16).toFloat()), ink), 0, context.dp(8), 0, context.dp(8))
