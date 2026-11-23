package net.scruter.cmp.ui

import android.app.Activity
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.AbsoluteSizeSpan
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import net.scruter.cmp.internal.SheetModel

/**
 * The short confirmation after a choice (owner's validation of 2026-11-21, boards M1 and M2): « Vos choix ont été
 * enregistrés. » and, under it, where to change them (`savedHint`), for 4 seconds above the app, announced by TalkBack,
 * then gone. It never takes a touch.
 */
internal object Confirmation {
    const val DURATION = 4_000L

    fun show(activity: Activity, model: SheetModel) {
        if (activity.isFinishing || activity.isDestroyed) return
        val content = activity.findViewById<ViewGroup>(android.R.id.content) as? FrameLayout ?: return
        val ctx = activity
        val saved = model.words["saved"]
        val hint = model.words["savedHint"]
        val text = SpannableStringBuilder(saved).apply {
            if (hint.isNotEmpty()) {
                append("\n")
                val at = length
                append(hint)
                setSpan(AbsoluteSizeSpan(13, true), at, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(ForegroundColorSpan(color("#D9D5E2")), at, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        val v = TextView(ctx).apply {
            this.text = text
            style(14f, Type.regular, color("#F1F0F7"), 1.15f)
            gravity = Gravity.CENTER_VERTICAL
            minHeight = ctx.dp(56)
            setPadding(ctx.dp(16), ctx.dp(12), ctx.dp(16), ctx.dp(12))
            background = rounded(color("#2F3036"), ctx.dp(8).toFloat())
            elevation = ctx.dp(6).toFloat()
            compoundDrawablePadding = ctx.dp(12)
            setCompoundDrawablesRelativeWithIntrinsicBounds(IconDrawable(listOf("M4 13l4 4L20 5"), 24f, ctx.dp(22), color("#2BC48A"), 2.6f), null, null, null)
            layoutDirection = if (model.rtl) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            isClickable = false
            isFocusable = false
            alpha = 0f
        }
        val bottom = content.rootWindowInsets?.let {
            @Suppress("DEPRECATION")
            it.systemWindowInsetBottom
        } ?: 0
        val lp = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
            setMargins(ctx.dp(12), 0, ctx.dp(12), bottom + ctx.dp(16))
        }
        val tablet = ctx.resources.configuration.smallestScreenWidthDp >= 600
        if (tablet) {
            lp.width = ctx.dp(480)
            lp.gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        }
        content.addView(v, lp)
        v.animate().alpha(1f).setDuration(160).start()
        v.announceForAccessibility("$saved $hint".trim())
        v.postDelayed({
            v.animate().alpha(0f).setDuration(200).withEndAction { (v.parent as? ViewGroup)?.removeView(v) }.start()
        }, DURATION)
    }
}
