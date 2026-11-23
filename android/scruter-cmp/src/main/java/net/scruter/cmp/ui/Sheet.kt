package net.scruter.cmp.ui

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.media.MediaPlayer
import android.os.Build
import android.os.SystemClock
import android.text.SpannableString
import android.text.style.UnderlineSpan
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.animation.DecelerateInterpolator
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Space
import android.widget.TextView
import net.scruter.cmp.internal.Palette
import net.scruter.cmp.internal.UiHost
import net.scruter.cmp.internal.SheetModel
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/** What a display keeps across an activity's recreation (rotation, dark mode): the step and the switches. */
internal class SheetState(val model: SheetModel) {
    /** −1: the first layer; 0…n−1: the steps of « Personnaliser ». */
    var step = -1
    val on = HashMap<String, Boolean>().apply { for (k in model.granted) put(k, true) }
    var shownAt = 0L
    var userPaused = false
    var playing = false
    var decided = false
    /** The TCF layers' switches (§6), and a page over the steps or the preferences (`purposes`, `partners`, `vendor:<id>`,
     *  `ac:<id>`). */
    val tcf: TcfEdit? = model.tcf?.let { TcfEdit(it) }
    var page: String? = null
    val pages = ArrayList<String?>()
}

/**
 * The sheet (docs/CMP-MOBILE.md §2.2–§2.5, canvas boards M2, M3, M4): a bottom sheet on phones, a centred 480 dp card on
 * tablets, drawn with the platform's views in a dialog window of its own (modal for TalkBack). It cannot be swiped or
 * touched away; Android's back is « close » on the first layer (a refusal), the previous step in « Personnaliser ».
 */
@SuppressLint("ViewConstructor")
internal class Sheet(private val host: UiHost, val activity: Activity, val st: SheetState) {
    private val model = st.model
    private val ctx: Context = activity
    private val conf: Configuration = activity.resources.configuration
    private val dark = when (model.ui.theme) {
        "dark" -> true
        "auto" -> (conf.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        else -> false
    }
    // With the IAB TCF, the primary buttons' text at 5:1 (TCF Policies, Appendix B C(g)), as on the web.
    private val pal = Palette(model.ui.color, dark, if (model.tcf != null) 5.0 else 0.0)
    private val bg = color(pal.bg)
    private val fg = color(pal.fg)
    private val sub = color(pal.sub)
    private val line = color(pal.line)
    private val brand = color(pal.brand)
    private val onBrand = color(pal.onBrand)
    private val kick = color(pal.kick)
    val tablet = conf.smallestScreenWidthDp >= 600
    private val large = conf.fontScale >= 1.5f
    private val rtl = model.rtl
    private val w = model.words
    private val t = model.texts
    private val source = if (model.kind == SheetModel.Kind.PREFERENCES) "preferences" else "banner"
    private val steps: List<String> = model.optional.ifEmpty { model.required }
    /** The steps, then the partners with the TCF (board M15). */
    private val stepCount = steps.size + (if (model.tcf != null) 1 else 0)
    private val refreshers = ArrayList<() -> Unit>()

    private val dialog: Dialog
    private val root = FrameLayout(ctx)
    private val card = RoundedLayout(ctx)
    private var heroBox: FrameLayout? = null
    private var posterView: ImageView? = null
    private var playButton: ImageButton? = null
    private var texture: TextureView? = null
    private var player: MediaPlayer? = null
    private var focusTarget: View? = null
    private var insetTop = 0
    private var insetBottom = 0
    private var bottomSpacer: View? = null
    private var deciding = false
    private var bandViews: List<View> = emptyList()
    private var afterBody: View? = null
    var shown = false
        private set

    init {
        val theme = if (dark) android.R.style.Theme_DeviceDefault_NoActionBar else android.R.style.Theme_DeviceDefault_Light_NoActionBar
        dialog = object : Dialog(activity, theme) {
            @Deprecated("Deprecated in Java")
            override fun onBackPressed() {
                back()
            }
        }
        dialog.setCancelable(false)
        dialog.setCanceledOnTouchOutside(false)
        root.layoutDirection = if (rtl) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR
        // The scrim: the app behind is veiled and takes no touch; a touch on it does nothing (no dismissal).
        val scrim = View(ctx).apply {
            setBackgroundColor(0x6B000000)
            isClickable = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        root.addView(scrim, FrameLayout.LayoutParams(-1, -1))
        card.orientation = LinearLayout.VERTICAL
        val r = ctx.dp(if (tablet) 24 else 28).toFloat()
        card.background = roundedTop(bg, r, if (tablet) r else 0f)
        card.corners(r, if (tablet) r else 0f)
        card.isClickable = true
        card.elevation = ctx.dp(6).toFloat()
        val lp = if (tablet) {
            FrameLayout.LayoutParams(ctx.dp(480), -2, Gravity.CENTER).apply { setMargins(ctx.dp(24), ctx.dp(24), ctx.dp(24), ctx.dp(24)) }
        } else {
            FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM)
        }
        root.addView(card, lp)
        root.setOnApplyWindowInsetsListener { _, insets -> applyInsets(insets) }
        dialog.setContentView(root)
        dialog.setOnDismissListener { release() }
        setupWindow()
        render()
    }

    private fun setupWindow() {
        val win = dialog.window ?: return
        win.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        win.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        win.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        win.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        win.statusBarColor = Color.TRANSPARENT
        win.navigationBarColor = Color.TRANSPARENT
        win.setWindowAnimations(0)
        win.setTitle(t.title)
        if (Build.VERSION.SDK_INT >= 29) win.isNavigationBarContrastEnforced = false
        if (Build.VERSION.SDK_INT >= 30) {
            win.setDecorFitsSystemWindows(false)
        } else {
            @Suppress("DEPRECATION")
            var flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            @Suppress("DEPRECATION")
            if (!dark && !tablet && Build.VERSION.SDK_INT >= 26) flags = flags or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
            @Suppress("DEPRECATION")
            win.decorView.systemUiVisibility = flags
        }
        if (Build.VERSION.SDK_INT >= 28) root.accessibilityPaneTitle = t.title
    }

    private fun applyInsets(insets: WindowInsets): WindowInsets {
        @Suppress("DEPRECATION")
        val top = insets.systemWindowInsetTop
        @Suppress("DEPRECATION")
        val bottom = insets.systemWindowInsetBottom
        @Suppress("DEPRECATION")
        val left = insets.systemWindowInsetLeft
        @Suppress("DEPRECATION")
        val right = insets.systemWindowInsetRight
        insetTop = top
        insetBottom = bottom
        val lp = card.layoutParams as FrameLayout.LayoutParams
        if (tablet) {
            lp.setMargins(ctx.dp(24) + left, ctx.dp(24) + top, ctx.dp(24) + right, ctx.dp(24) + bottom)
        } else {
            // The sheet stops under the status bar; its surface runs under the navigation bar.
            lp.setMargins(left, top + ctx.dp(24), right, 0)
            bottomSpacer?.layoutParams?.height = bottom
        }
        card.layoutParams = lp
        if (Build.VERSION.SDK_INT >= 30 && !dark && !tablet) {
            dialog.window?.insetsController?.setSystemBarsAppearance(
                WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            )
        }
        return insets
    }

    // ------------------------------------------------------------------------------------------------ show / hide

    fun show() {
        if (shown) return
        shown = true
        if (st.shownAt == 0L) st.shownAt = SystemClock.elapsedRealtime()
        dialog.show()
        card.translationY = ctx.dp(48).toFloat()
        card.alpha = 0f
        card.animate().translationY(0f).alpha(1f).setDuration(280).setInterpolator(DecelerateInterpolator(2f)).start()
        card.viewTreeObserver.addOnPreDrawListener(object : android.view.ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                card.viewTreeObserver.removeOnPreDrawListener(this)
                card.post { firstFrame() }
                return true
            }
        })
    }

    /** After the sheet's first frame: the focus for TalkBack, then the video loop (never before the buttons work). */
    private fun firstFrame() {
        if (!shown) return
        focus()
        if (model.videoUrl != null && st.step < 0 && !large) {
            if (!st.userPaused && (st.playing || host.motionAllowed(ctx))) {
                st.playing = true
                paintPlayButton()
                host.loadVideo(this, model.videoUrl, model.videoFile)
            }
        }
    }

    /** Closes without animation (the activity goes away; the state is kept to show again). */
    fun detach() {
        shown = false
        val playing = st.playing
        release()
        st.playing = playing
        try {
            dialog.dismiss()
        } catch (e: IllegalArgumentException) {
            // The window is already gone with its activity.
        }
    }

    /** Closes after a decision. */
    fun close(after: () -> Unit) {
        release()
        card.animate().translationY(card.height.toFloat().coerceAtLeast(ctx.dp(48).toFloat())).alpha(0f).setDuration(200)
            .setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    shown = false
                    try {
                        dialog.dismiss()
                    } catch (e: IllegalArgumentException) {
                        // Already gone.
                    }
                    after()
                }
            }).start()
    }

    // ------------------------------------------------------------------------------------------------ actions

    private fun back() {
        if (deciding) return
        when {
            st.page != null -> closePage()
            model.kind == SheetModel.Kind.PREFERENCES -> closePreferences()
            st.step >= 0 -> goTo(st.step - 1)
            // Android's back on the first layer is « close »: a refusal, recorded as `close` (owner's validation).
            else -> decide("close", emptyMap())
        }
    }

    private fun closePreferences() {
        if (model.consentId != null && host.hasValidChoice()) {
            deciding = true
            close { host.closed(this, decided = false) }
        } else {
            decide("close", emptyMap())
        }
    }

    private fun all(on: Boolean): Map<String, Boolean> = model.optional.associateWith { on }

    private fun decide(action: String?, map: Map<String, Boolean>) {
        if (deciding) return
        deciding = true
        st.decided = true
        release()
        // « Enregistrer » with the TCF layers carries their switches; « Tout accepter » and « Tout refuser » say it all.
        host.decide(this, action, source, map, if (action == "custom") st.tcf?.settled(st.on) else null)
    }

    private fun openPage(page: String) {
        st.pages.add(st.page)
        st.page = page
        render()
        card.post { focus() }
    }

    private fun closePage() {
        st.page = if (st.pages.isEmpty()) null else st.pages.removeAt(st.pages.size - 1)
        render()
        card.post { focus() }
    }

    private fun tcfViews(): TcfViews = TcfViews(
        ctx, activity, st, w, model.lang,
        TcfViews.Colors(fg, sub, line, brand, onBrand, color(pal.edge), if (dark) color("#2A2631") else color("#E6E4EC"), color(pal.soft)),
        host.motionAllowed(ctx), ::openPage, refreshers,
    )

    private fun goTo(step: Int) {
        st.step = step.coerceIn(-1, stepCount - 1)
        if (st.step >= 0) release()
        render()
        card.post { focus() }
    }

    // ------------------------------------------------------------------------------------------------ layout

    fun render() {
        card.removeAllViews()
        refreshers.clear()
        focusTarget = null
        bandViews = emptyList()
        afterBody = null
        heroBox = null
        posterView = null
        playButton = null
        texture = null
        if (model.kind == SheetModel.Kind.BANNER && model.ui.closeLink) card.addView(band())
        val body: View
        val page = st.page
        if (page != null && st.tcf != null) {
            if (model.kind == SheetModel.Kind.PREFERENCES) card.addView(prefsHeader())
            body = pageBody(page)
        } else if (model.kind == SheetModel.Kind.PREFERENCES) {
            card.addView(prefsHeader())
            body = prefsBody()
        } else if (st.step >= steps.size && st.tcf != null) {
            body = stepBody()
        } else if (st.step >= 0) {
            body = stepBody()
        } else {
            val header = if (large) null else header()
            if (header != null) card.addView(header)
            body = firstBody(header == null)
        }
        val scroll = ScrollView(ctx).apply {
            isFillViewport = false
            isVerticalScrollBarEnabled = true
            addView(body)
        }
        card.addView(scroll, LinearLayout.LayoutParams(-1, -2, 1f))
        card.addView(actions())
        if (model.ui.branding && !(model.kind == SheetModel.Kind.BANNER && model.ui.closeLink)) card.addView(proposedBy())
        if (!tablet) {
            val spacer = Space(ctx)
            bottomSpacer = spacer
            card.addView(spacer, LinearLayout.LayoutParams(-1, insetBottom))
        }
    }

    /** The header band: « Certifié par Scruter » (every plan) and « Continuer sans accepter » (docs/CMP.md §4.5). */
    private fun band(): View {
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(brand)
            minimumHeight = ctx.dp(48)
            setPaddingRelative(ctx.dp(14), 0, ctx.dp(6), 0)
        }
        val full = w["certified"] + " Scruter"
        val cert = FitText(ctx, underlined(full), underlined("Scruter")).apply {
            id = View.generateViewId()
            contentDescription = full
            style(13f, Type.regular, onBrand)
            setLines(1)
            gravity = Gravity.CENTER_VERTICAL
            minHeight = ctx.dp(48)
            setPaddingRelative(ctx.dp(4), 0, ctx.dp(4), 0)
            compoundDrawablePadding = ctx.dp(6)
            setCompoundDrawablesRelativeWithIntrinsicBounds(IconDrawable(Icons.ARCS, 64f, ctx.dp(14), onBrand, 12f), null, null, null)
            background = ripple(null, onBrand)
            setOnClickListener { Browser.open(activity, Browser.CERTIFIED_URL, brand) }
            accessibilityRole("link")
        }
        row.addView(cert, LinearLayout.LayoutParams(0, -2, 1f).apply { gravity = Gravity.CENTER_VERTICAL })
        if (model.ui.closeLink) {
            val pillText = if (pal.onBrand == "#FFFFFF") color("#17131F") else Color.WHITE
            val pill = Button(ctx).apply {
                id = View.generateViewId()
                text = t.close + if (rtl) " ←" else " →"
                isAllCaps = false
                stateListAnimator = null
                style(13f, Type.medium, pillText)
                maxLines = 2
                // A large font scale wraps the pill rather than pushing « Certifié par Scruter » out of the band.
                maxWidth = (ctx.dp(if (tablet) 480 else conf.screenWidthDp) * 0.62f).toInt()
                minHeight = ctx.dp(48)
                minimumHeight = ctx.dp(48)
                minWidth = 0
                minimumWidth = 0
                background = pillBackground(ctx, onBrand, pillText)
                // After the background: its inset (the 48 dp touch target around the pill) would replace this padding.
                setPadding(ctx.dp(12), ctx.dp(8), ctx.dp(12), ctx.dp(8))
                contentDescription = t.close
                setOnClickListener { decide("close", emptyMap()) }
            }
            row.addView(pill, LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.CENTER_VERTICAL })
            bandViews = listOf(cert, pill)
        } else {
            bandViews = listOf(cert)
        }
        return row
    }

    /** The media header and the app's icon astride it; null when there is neither media nor panel (`no_panel`). */
    private fun header(): View? {
        val hero = model.ui.hero
        val phoneHidden = !tablet && hero?.hideOnPhone == true
        val media = hero != null && !phoneHidden
        if (!media && (model.ui.noPanel || phoneHidden)) return null
        val h = ctx.dp(if (media) (if (tablet) 120 else 92) else (if (tablet) 66 else 58))
        val icon = model.icon
        val frame = FrameLayout(ctx)
        val box = FrameLayout(ctx).apply { setBackgroundColor(color(pal.tint)) }
        heroBox = box
        frame.addView(box, FrameLayout.LayoutParams(-1, h))
        model.poster?.let { bmp ->
            val img = ImageView(ctx).apply {
                scaleType = ImageView.ScaleType.MATRIX
                setImageBitmap(bmp)
                val alt = t.heroAlt
                if (alt.isNullOrEmpty()) importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO else contentDescription = alt
                addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
                    (v as ImageView).imageMatrix = cover(v, bmp.width, bmp.height, hero?.focalX ?: 50, hero?.focalY ?: 50)
                }
            }
            posterView = img
            box.addView(img, FrameLayout.LayoutParams(-1, -1))
        }
        val edgeShape = hero?.edge ?: "curve"
        if (edgeShape != "straight") box.addView(EdgeView(ctx, edgeShape, bg), FrameLayout.LayoutParams(-1, ctx.dp(22), Gravity.BOTTOM))
        if (hero?.video == true && model.videoUrl != null) {
            val b = ImageButton(ctx).apply {
                id = View.generateViewId()
                background = ripple(null, Color.WHITE)
                scaleType = ImageView.ScaleType.CENTER
                setOnClickListener { togglePlay() }
            }
            playButton = b
            paintPlayButton()
            box.addView(b, FrameLayout.LayoutParams(ctx.dp(48), ctx.dp(48), Gravity.TOP or Gravity.END).apply { setMargins(0, ctx.dp(4), ctx.dp(4), 0) })
        }
        if (icon != null) {
            val badge = IconBadge(ctx, icon, model.iconOnDisc, bg, line)
            val bh = badge.layoutParams.height
            frame.addView(badge, FrameLayout.LayoutParams(badge.layoutParams.width, bh, Gravity.TOP or Gravity.START).apply {
                marginStart = ctx.dp(20)
                topMargin = h - ctx.dp(40)
            })
            frame.layoutParams = LinearLayout.LayoutParams(-1, h - ctx.dp(40) + bh)
        }
        return frame
    }

    /** Kicker, title, message, the privacy policy link (the icon beside the title when there is no header). */
    private fun firstBody(iconBeside: Boolean): View {
        val col = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPaddingRelative(ctx.dp(20), ctx.dp(if (iconBeside) 16 else 10), ctx.dp(20), ctx.dp(8))
        }
        val title = TextView(ctx).apply {
            id = View.generateViewId()
            text = t.title
            style(22f, Type.medium, fg, 1.1f)
            heading()
        }
        focusTarget = title
        val kicker = t.kicker?.takeIf { it.isNotBlank() }?.let { k ->
            TextView(ctx).apply {
                id = View.generateViewId()
                text = k
                style(14f, Type.medium, kick)
            }
        }
        val icon = model.icon
        if (iconBeside && icon != null && !large) {
            val row = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            val badge = IconBadge(ctx, icon, model.iconOnDisc, bg, line)
            row.addView(badge, LinearLayout.LayoutParams(badge.layoutParams.width, badge.layoutParams.height).apply { marginEnd = ctx.dp(12) })
            val texts = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
            kicker?.let { texts.addView(it) }
            texts.addView(title)
            row.addView(texts, LinearLayout.LayoutParams(0, -2, 1f))
            col.addView(row)
        } else {
            kicker?.let { col.addView(it) }
            col.addView(title, LinearLayout.LayoutParams(-1, -2).apply { topMargin = if (kicker != null) ctx.dp(2) else 0 })
        }
        if (st.tcf != null) {
            // The IAB text in the message's place, the policy among its links (docs/CMP.md §4.7, board M7).
            val note = tcfViews().first(col, model.policyUrl) { goTo(it) }
            kicker?.accessibilityTraversalAfter = title.id
            afterBody = note
            return col
        }
        val message = TextView(ctx).apply {
            id = View.generateViewId()
            text = t.message
            style(15f, Type.regular, sub, 1.2f)
        }
        col.addView(message, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(8) })
        var lastText: View = message
        model.policyUrl?.let { url ->
            val link = linkView(w["privacy"]) { Browser.open(activity, url, brand) }
            col.addView(link, LinearLayout.LayoutParams(-2, -2))
            lastText = link
        }
        // TalkBack: title → (kicker) → message → link → buttons → the band → the video's button.
        kicker?.accessibilityTraversalAfter = title.id
        message.accessibilityTraversalAfter = kicker?.id ?: title.id
        afterBody = lastText
        return col
    }

    private fun underlined(t: String) = SpannableString(t).apply { setSpan(UnderlineSpan(), 0, length, 0) }

    private fun linkView(label: String, onClick: () -> Unit): TextView = TextView(ctx).apply {
        id = View.generateViewId()
        text = SpannableString(label).apply { setSpan(UnderlineSpan(), 0, length, 0) }
        style(15f, Type.medium, fg)
        gravity = Gravity.CENTER_VERTICAL
        minHeight = ctx.dp(48)
        background = ripple(null, fg)
        setOnClickListener { onClick() }
        accessibilityRole("link")
    }

    /** One step of « Personnaliser »: one optional purpose, its switch (off unless granted), why, its providers. */
    private fun stepBody(): View {
        val i = st.step
        val last = i == stepCount - 1
        val col = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPaddingRelative(ctx.dp(20), ctx.dp(10), ctx.dp(20), ctx.dp(8))
        }
        val head = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val backBtn = iconButton(Icons.BACK, w["back"], fg, mirror = rtl) { goTo(st.step - 1) }
        head.addView(backBtn, LinearLayout.LayoutParams(ctx.dp(48), ctx.dp(48)).apply { marginStart = -ctx.dp(12) })
        val of = TextView(ctx).apply {
            text = w.stepOf(i + 1, stepCount)
            style(14f, Type.medium, sub)
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        head.addView(of, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = ctx.dp(4) })
        val pips = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        for (j in 0 until stepCount) {
            pips.addView(View(ctx).apply { background = rounded(if (j <= i) kick else line, ctx.dp(3).toFloat()) },
                LinearLayout.LayoutParams(ctx.dp(if (stepCount > 6) 12 else 24), ctx.dp(6)).apply { marginStart = ctx.dp(4) })
        }
        head.addView(pips)
        col.addView(head)
        if (i >= steps.size) {
            // The partners (board M15, 2).
            focusTarget = tcfViews().partners(col)
            return col
        }
        val key = steps[i]
        val required = key in model.required
        val row = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val ico = ImageView(ctx).apply {
            setImageDrawable(IconDrawable(listOf(Icons.purpose(key)), 24f, ctx.dp(20), kick))
            scaleType = ImageView.ScaleType.CENTER
            background = rounded(color(pal.soft), ctx.dp(12).toFloat())
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        row.addView(ico, LinearLayout.LayoutParams(ctx.dp(40), ctx.dp(40)).apply { marginEnd = ctx.dp(12) })
        val name = TextView(ctx).apply {
            id = View.generateViewId()
            text = t.name(key)
            style(19f, Type.medium, fg, 1.1f)
            heading()
        }
        focusTarget = name
        row.addView(name, LinearLayout.LayoutParams(0, -2, 1f))
        row.addView(control(key, required, t.name(key)))
        col.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(4) })
        t.description(key).takeIf { it.isNotBlank() }?.let {
            col.addView(TextView(ctx).apply { text = it; style(15f, Type.regular, sub, 1.2f) }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(10) })
        }
        providers(col, key)
        // The IAB purposes grouped under this purpose (board M15, 1).
        if (st.tcf != null) tcfViews().purposes(col, key)
        if (last && model.consentId != null) {
            col.addView(TextView(ctx).apply {
                text = w["id"] + w["colon"] + model.consentId
                style(13f, Type.regular, sub)
                setTextIsSelectable(true)
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(14) })
        }
        return col
    }

    private fun providers(col: LinearLayout, key: String) {
        val list = model.ui.providers[key].orEmpty()
        if (list.isEmpty()) return
        col.addView(TextView(ctx).apply {
            text = (w["providers"] + " · " + list.size).uppercase(Locale.forLanguageTag(model.lang))
            style(12f, Type.bold, sub)
            letterSpacing = 0.06f
            heading()
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(16); bottomMargin = ctx.dp(6) })
        for (p in list) {
            col.addView(View(ctx).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(-1, ctx.dp(1)))
            col.addView(TextView(ctx).apply {
                text = p
                style(15f, Type.regular, fg)
                gravity = Gravity.CENTER_VERTICAL
                minHeight = ctx.dp(52)
            })
        }
    }

    /** A purpose's control: its switch, or « Toujours actif » for a necessary purpose. */
    private fun control(key: String, required: Boolean, label: String): View {
        if (required) {
            return TextView(ctx).apply {
                text = w["always"]
                style(13f, Type.bold, fg)
                background = rounded(color(pal.soft), ctx.dp(14).toFloat())
                setPadding(ctx.dp(10), ctx.dp(5), ctx.dp(10), ctx.dp(5))
            }
        }
        return M3Switch(ctx, brand, onBrand, color(pal.edge), if (dark) color("#2A2631") else color("#E6E4EC"), host.motionAllowed(ctx)).apply {
            isChecked = st.on[key] == true
            contentDescription = label
            setOnCheckedChangeListener { _, checked ->
                st.on[key] = checked
                // The IAB purposes and partners not touched follow the banner purposes from now on.
                st.tcf?.let { e ->
                    e.moved = true
                    for (f in refreshers) f()
                }
            }
        }
    }

    /** A page of the TCF layers with its way back (the preferences' rows, a partner from the list). */
    private fun pageBody(page: String): View {
        val col = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPaddingRelative(ctx.dp(20), ctx.dp(6), ctx.dp(20), ctx.dp(8))
        }
        val back = iconButton(Icons.BACK, w["back"], fg, mirror = rtl) { closePage() }
        back.tag = "scruter-cmp-tcf-back"
        col.addView(back, LinearLayout.LayoutParams(ctx.dp(48), ctx.dp(48)).apply { marginStart = -ctx.dp(12) })
        val v = tcfViews()
        focusTarget = when {
            page == "purposes" -> {
                v.purposes(col, null)
                back
            }
            page == "partners" -> v.partners(col)
            page.startsWith("vendor:") -> v.vendor(col, page.substringAfter(':').toIntOrNull() ?: 0) ?: back
            page.startsWith("ac:") -> v.acProvider(col, page.substringAfter(':').toIntOrNull() ?: 0) ?: back
            else -> back
        }
        return col
    }

    /** The preferences (the app's settings entry): the title and a close button. */
    private fun prefsHeader(): View {
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPaddingRelative(ctx.dp(20), ctx.dp(12), ctx.dp(8), ctx.dp(4))
        }
        val title = TextView(ctx).apply {
            id = View.generateViewId()
            text = t.preferencesTitle.ifBlank { w["state"] }
            style(22f, Type.medium, fg, 1.1f)
            heading()
        }
        focusTarget = title
        row.addView(title, LinearLayout.LayoutParams(0, -2, 1f))
        row.addView(iconButton(Icons.CLOSE, w["close"], fg) { closePreferences() }, LinearLayout.LayoutParams(ctx.dp(48), ctx.dp(48)))
        return row
    }

    /** Every purpose and its state, the receipt (consent id, date). Withdrawal: « Tout refuser » after a consent. */
    private fun prefsBody(): View {
        val col = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPaddingRelative(ctx.dp(20), 0, ctx.dp(20), ctx.dp(8))
        }
        t.preferencesIntro.takeIf { it.isNotBlank() }?.let {
            col.addView(TextView(ctx).apply { text = it; style(15f, Type.regular, sub, 1.2f) }, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = ctx.dp(8) })
        }
        for (p in model.cmp.purposes) {
            col.addView(View(ctx).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(-1, ctx.dp(1)))
            val row = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = ctx.dp(64)
                setPadding(0, ctx.dp(8), 0, ctx.dp(8))
            }
            val texts = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
            texts.addView(TextView(ctx).apply { text = t.name(p.key); style(16f, Type.medium, fg) })
            val small = model.ui.providers[p.key].orEmpty().joinToString(", ").ifEmpty { t.description(p.key) }
            if (small.isNotBlank()) texts.addView(TextView(ctx).apply { text = small; style(13f, Type.regular, sub, 1.15f) })
            row.addView(texts, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = ctx.dp(12) })
            row.addView(control(p.key, p.required, t.name(p.key)))
            col.addView(row)
        }
        if (st.tcf != null) tcfViews().preferenceRows(col)
        val receipt = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(color(pal.soft), ctx.dp(12).toFloat())
            setPadding(ctx.dp(14), ctx.dp(10), ctx.dp(10), ctx.dp(10))
        }
        val id = model.consentId
        if (id == null) {
            receipt.addView(TextView(ctx).apply { text = w["noChoice"]; style(13f, Type.regular, sub) })
        } else {
            receipt.addView(TextView(ctx).apply { text = w["id"]; style(13f, Type.regular, sub) })
            val idRow = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            idRow.addView(TextView(ctx).apply {
                text = id
                style(14f, Typeface.MONOSPACE, fg)
                setTextIsSelectable(true)
                textDirection = View.TEXT_DIRECTION_LTR
            }, LinearLayout.LayoutParams(0, -2, 1f))
            val copy = Button(ctx).apply {
                text = w["copy"]
                isAllCaps = false
                stateListAnimator = null
                style(13f, Type.medium, fg)
                minHeight = ctx.dp(48)
                minimumHeight = ctx.dp(48)
                setPadding(ctx.dp(10), 0, ctx.dp(10), 0)
                background = ripple(null, fg)
            }
            copy.setOnClickListener {
                val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                cm?.setPrimaryClip(ClipData.newPlainText(w["id"], id))
                copy.text = w["copied"]
                copy.announceForAccessibility(w["copied"])
            }
            idRow.addView(copy)
            receipt.addView(idRow)
            if (model.decidedAt > 0) {
                val df = DateFormat.getDateInstance(DateFormat.LONG, Locale.forLanguageTag(model.lang))
                receipt.addView(TextView(ctx).apply { text = df.format(Date(model.decidedAt)); style(13f, Type.regular, sub) })
            }
        }
        col.addView(receipt, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(12) })
        return col
    }

    /** The joined row under a rule: « Tout refuser | Personnaliser | Tout accepter » and its step variants. */
    private fun actions(): View {
        val box = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
        }
        box.addView(View(ctx).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(-1, ctx.dp(1)))
        val row = JoinedRow(ctx, color(pal.edge), bg)
        val reject = ctx.joinedButton(t.rejectAll, bg, fg, false).apply { setOnClickListener { decide("reject_all", all(false)) } }
        val accept = ctx.joinedButton(t.acceptAll, brand, onBrand, true).apply { setOnClickListener { decide("accept_all", all(true)) } }
        val middle: Button = when {
            model.kind == SheetModel.Kind.PREFERENCES -> ctx.joinedButton(t.save.ifBlank { w["save"] }, bg, fg, false).apply {
                setOnClickListener { decide("custom", HashMap(st.on)) }
            }
            st.step < 0 -> ctx.joinedButton(t.customize, bg, fg, false).apply { setOnClickListener { goTo(0) } }
            st.step == stepCount - 1 -> ctx.joinedButton(t.save.ifBlank { w["save"] }, bg, fg, false).apply {
                setOnClickListener { decide("custom", HashMap(st.on)) }
            }
            else -> ctx.joinedButton(w["next"], bg, fg, false).apply {
                // « Suivant › », the chevron beside the word (pointing the reading direction).
                val chev = IconDrawable(listOf(Icons.CHEV), 24f, ctx.dp(16), fg, mirror = rtl).apply { setBounds(0, 0, ctx.dp(16), ctx.dp(16)) }
                text = SpannableString(w["next"] + "\u00a0 ").apply {
                    setSpan(android.text.style.ImageSpan(chev, if (Build.VERSION.SDK_INT >= 29) android.text.style.DynamicDrawableSpan.ALIGN_CENTER else android.text.style.DynamicDrawableSpan.ALIGN_BASELINE), length - 1, length, 0)
                }
                contentDescription = w["next"]
                setOnClickListener { goTo(st.step + 1) }
            }
        }
        // « Tout refuser » is never smaller than « Tout accepter »: equal parts of one row (docs/CMP.md D11).
        if (!(st.step < 0 && model.kind == SheetModel.Kind.BANNER && model.ui.twoButtons)) row.add(reject)
        row.add(middle)
        row.add(accept)
        for (b in listOf(reject, middle, accept)) b.id = View.generateViewId()
        box.addView(row, LinearLayout.LayoutParams(-1, -2).apply { setMargins(ctx.dp(16), ctx.dp(12), ctx.dp(16), ctx.dp(if (tablet) 16 else 12)) })
        // Reading order: the body, the buttons, then the band and the video's button (docs/CMP-MOBILE.md §3.12).
        val first = if (row.indexOfChild(reject) >= 0) reject else middle
        afterBody?.let { first.accessibilityTraversalAfter = it.id }
        var previous: View = accept
        for (v in bandViews) {
            v.accessibilityTraversalAfter = previous.id
            previous = v
        }
        playButton?.accessibilityTraversalAfter = previous.id
        return box
    }

    /** « Proposé par Scruter » (Free plan, without the band). */
    private fun proposedBy(): View = TextView(ctx).apply {
        text = w["by"] + " Scruter"
        style(12f, Type.regular, sub)
        gravity = Gravity.CENTER
        minHeight = ctx.dp(48)
        compoundDrawablePadding = ctx.dp(6)
        setCompoundDrawablesRelativeWithIntrinsicBounds(IconDrawable(Icons.ARCS, 64f, ctx.dp(14), sub, 12f, colors = Icons.ARC_COLORS), null, null, null)
        background = ripple(null, fg)
        setOnClickListener { Browser.open(activity, Browser.CERTIFIED_URL, brand) }
        accessibilityRole("link")
        layoutParams = LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = ctx.dp(4) }
    }

    private fun iconButton(path: String, label: String, tint: Int, mirror: Boolean = false, onClick: () -> Unit): ImageButton =
        ImageButton(ctx).apply {
            setImageDrawable(IconDrawable(listOf(path), 24f, ctx.dp(22), tint, 2.2f, mirror = mirror))
            scaleType = ImageView.ScaleType.CENTER
            background = ripple(null, tint).also { it.radius = ctx.dp(24) }
            contentDescription = label
            setOnClickListener { onClick() }
        }

    private fun TextView.heading() {
        if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
    }

    private fun View.accessibilityRole(role: String) {
        accessibilityDelegate = object : View.AccessibilityDelegate() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                if (role == "link") info.className = "android.widget.Button"
            }
        }
    }

    /** TalkBack's focus on the title (first layer, preferences) or on the step's purpose. */
    private fun focus() {
        val v = focusTarget ?: return
        val am = ctx.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        if (am?.isEnabled == true) {
            v.performAccessibilityAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null)
            v.sendAccessibilityEvent(AccessibilityEvent.TYPE_VIEW_FOCUSED)
        }
    }

    // ------------------------------------------------------------------------------------------------ video

    private fun paintPlayButton() {
        val b = playButton ?: return
        val playing = st.playing
        b.setImageDrawable(
            if (playing) IconDrawable(listOf(Icons.PAUSE), 24f, ctx.dp(16), Color.WHITE, 3f)
            else IconDrawable(listOf(Icons.PLAY), 24f, ctx.dp(16), Color.WHITE, 0f, fill = true),
        )
        b.background = android.graphics.drawable.InsetDrawable(
            ripple(android.graphics.drawable.GradientDrawable().apply {
                shape = android.graphics.drawable.GradientDrawable.OVAL
                setColor(0x8C1A1C20.toInt())
            }, Color.WHITE),
            ctx.dp(6),
        )
        b.contentDescription = if (playing) w["pause"] else w["play"]
    }

    private fun togglePlay() {
        val p = player
        if (st.playing) {
            st.userPaused = true
            st.playing = false
            try {
                p?.pause()
            } catch (e: IllegalStateException) {
                // Released meanwhile.
            }
        } else {
            st.userPaused = false
            st.playing = true
            if (p != null) {
                try {
                    p.start()
                } catch (e: IllegalStateException) {
                    host.loadVideo(this, model.videoUrl, model.videoFile)
                }
            } else {
                host.loadVideo(this, model.videoUrl, model.videoFile)
            }
        }
        paintPlayButton()
    }

    /** Plays the muted loop over its poster (`MediaPlayer` on a `TextureView`, no player library). */
    fun play(file: File) {
        val box = heroBox ?: return
        if (!shown || st.step >= 0 || deciding || player != null) return
        val tv = TextureView(ctx)
        tv.alpha = 0f
        tv.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        texture = tv
        box.addView(tv, 1, FrameLayout.LayoutParams(-1, -1))
        tv.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                val mp = MediaPlayer()
                player = mp
                try {
                    mp.setDataSource(file.path)
                    mp.setSurface(Surface(surface))
                    mp.isLooping = true
                    mp.setVolume(0f, 0f)
                    mp.setOnPreparedListener {
                        if (player !== mp) return@setOnPreparedListener
                        val hero = model.ui.hero
                        tv.setTransform(videoMatrix(tv, mp.videoWidth, mp.videoHeight, hero?.focalX ?: 50, hero?.focalY ?: 50))
                        mp.start()
                        st.playing = true
                        paintPlayButton()
                        tv.animate().alpha(1f).setDuration(420).start()
                    }
                    mp.setOnErrorListener { _, _, _ -> release(); true }
                    mp.prepareAsync()
                } catch (e: Exception) {
                    release()
                }
            }

            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit

            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                releasePlayer()
                return true
            }

            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
        }
    }

    /** A TextureView stretches its video to its bounds: this matrix crops it like `object-fit: cover` instead. */
    private fun videoMatrix(v: View, vw: Int, vh: Int, fx: Int, fy: Int): android.graphics.Matrix {
        val m = android.graphics.Matrix()
        if (vw <= 0 || vh <= 0 || v.width == 0 || v.height == 0) return m
        val s = maxOf(v.width / vw.toFloat(), v.height / vh.toFloat())
        val sx = vw * s / v.width
        val sy = vh * s / v.height
        m.setScale(sx, sy)
        m.postTranslate((v.width - vw * s) * fx / 100f, (v.height - vh * s) * fy / 100f)
        return m
    }

    private fun releasePlayer() {
        val p = player ?: return
        player = null
        try {
            p.release()
        } catch (e: RuntimeException) {
            // Already released.
        }
    }

    /** Stops and releases the loop (at the decision, when the steps start, when the sheet goes). */
    fun release() {
        releasePlayer()
        texture?.let { tv -> (tv.parent as? ViewGroup)?.removeView(tv) }
        texture = null
        st.playing = false
        paintPlayButton()
    }

    val isShowing: Boolean get() = shown && dialog.isShowing
}
