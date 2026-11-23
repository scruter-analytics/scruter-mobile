package net.scruter.cmp.ui

import android.app.Activity
import android.content.Context
import android.graphics.Typeface
import android.os.Build
import android.text.Editable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextWatcher
import android.text.method.LinkMovementMethod
import android.text.style.StyleSpan
import android.text.style.URLSpan
import android.text.style.UnderlineSpan
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import net.scruter.cmp.internal.AcProvider
import net.scruter.cmp.internal.GvlVendor
import net.scruter.cmp.internal.Tcf
import net.scruter.cmp.internal.TcfChoice
import net.scruter.cmp.internal.TcfSheet
import net.scruter.cmp.internal.TcfText
import net.scruter.cmp.internal.Words
import java.util.Locale

/**
 * The TCF switches of a display (the site script's `TcfEdit` and `settle`): untouched IAB purposes follow the banner
 * purpose they are grouped under (all of them when none), untouched partners follow the IAB purposes their consent rests
 * on; a returning visitor's stored choice holds until a banner or IAB purpose is moved. Kept across recreations.
 */
internal class TcfEdit(val sheet: TcfSheet) {
    val purposes = HashMap<Int, Boolean>()
    val vendors = HashMap<Int, Boolean>()
    val vendorsLi = HashMap<Int, Boolean>()
    val purposesLi = HashMap<Int, Boolean>()
    val specialFeatures = HashMap<Int, Boolean>()
    /** Google's other ad tech providers (Additional Consent). */
    val ac = HashMap<Int, Boolean>()
    val touched = HashSet<String>()
    var moved = false
    var query = ""

    private val follows: Boolean get() = sheet.stored == null || moved

    fun bannerGrants(p: Int, on: Map<String, Boolean>): Boolean =
        sheet.settings.stacks[p]?.let { on[it] == true } ?: sheet.keys.all { on[it] == true }

    fun purpose(p: Int, on: Map<String, Boolean>): Boolean {
        if ("p$p" in touched) return purposes[p] == true
        return if (follows) bannerGrants(p, on) else sheet.stored?.purposes?.get(p) ?: bannerGrants(p, on)
    }

    fun vendor(v: TcfSheet.Vendor, on: Map<String, Boolean>): Boolean {
        if ("v${v.v.id}" in touched) return vendors[v.v.id] == true
        val derived = v.consent.isNotEmpty() && v.consent.all { purpose(it, on) }
        return if (follows) derived else sheet.stored?.vendors?.get(v.v.id) ?: derived
    }

    /** One of Google's providers: untouched, it follows purposes 1, 3 and 4 (as an IAB partner follows its purposes). */
    fun ac(id: Int, on: Map<String, Boolean>): Boolean {
        if ("a$id" in touched) return ac[id] == true
        val derived = Tcf.AC_PURPOSES.all { purpose(it, on) }
        return if (follows) derived else sheet.stored?.ac?.get(id) ?: derived
    }

    fun vendorLi(id: Int): Boolean = vendorsLi[id] ?: sheet.stored?.vendorsLi?.get(id) ?: true
    fun purposeLi(p: Int): Boolean = purposesLi[p] ?: sheet.stored?.purposesLi?.get(p) ?: true
    fun specialFeature(f: Int): Boolean = specialFeatures[f] ?: sheet.stored?.specialFeatures?.get(f) ?: false

    /** The TCF choice « Enregistrer » sends: every switch shown or derived. */
    fun settled(on: Map<String, Boolean>): TcfChoice = TcfChoice(
        sheet.vendors.filter { it.consent.isNotEmpty() }.associate { it.v.id to vendor(it, on) },
        sheet.vendors.filter { it.li.isNotEmpty() }.associate { it.v.id to vendorLi(it.v.id) },
        sheet.liPurposes.associateWith { purposeLi(it) },
        sheet.specialFeatures.associateWith { specialFeature(it) },
        sheet.consentPurposes.associateWith { purpose(it, on) },
        sheet.ac.associate { it.id to ac(it.id, on) },
    )
}

/** A link inside a text that runs an action of the sheet (an absolute URL, as accessibility services expect). */
internal class ActionLink(url: String, private val action: () -> Unit) : URLSpan(url) {
    override fun onClick(widget: View) = action()
}

/**
 * The TCF layers of the sheet (docs/CMP.md §4.7, boards M7 and M15) in the sheet's anatomy: the first layer's IAB text,
 * the IAB purposes of a step, the partners, one partner's declarations, the preferences' two rows.
 */
internal class TcfViews(
    private val ctx: Context,
    private val activity: Activity,
    private val st: SheetState,
    private val w: Words,
    private val lang: String,
    private val c: Colors,
    private val motion: Boolean,
    /** Opens a page (`purposes`, `partners`, `vendor:<id>`, `ac:<id>`). */
    private val go: (String) -> Unit,
    /** Run when a banner purpose moves: the untouched IAB switches follow. */
    private val refreshers: MutableList<() -> Unit>,
) {
    class Colors(val fg: Int, val sub: Int, val line: Int, val brand: Int, val onBrand: Int, val edge: Int, val offTrack: Int, val soft: Int)

    private val edit = st.tcf!!
    private val t = edit.sheet

    private fun fill(s: String, n: Int) = s.replace("{n}", n.toString())

    private fun text(s: CharSequence, size: Float, face: Typeface, colour: Int): TextView = TextView(ctx).apply {
        text = s
        style(size, face, colour, 1.2f)
    }

    private fun LinearLayout.add(v: View, top: Int = 0) = addView(v, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(top) })

    private fun heading(s: String): TextView = TextView(ctx).apply {
        text = s.uppercase(Locale.forLanguageTag(lang))
        style(12f, Type.bold, c.sub)
        letterSpacing = 0.06f
        if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
    }

    private fun switch(label: String, on: Boolean, change: (Boolean) -> Unit): M3Switch =
        M3Switch(ctx, c.brand, c.onBrand, c.edge, c.offTrack, motion).apply {
            isChecked = on
            contentDescription = label
            setOnCheckedChangeListener { _, checked -> change(checked) }
        }

    /** The first layer: IAB's text in the message's place, its small print and inline links (board M7, 1). */
    fun first(col: LinearLayout, policyUrl: String?, openStep: (Int) -> Unit): View {
        val sb = SpannableStringBuilder()
        for ((s, bold) in t.first) {
            val at = sb.length
            sb.append(s)
            if (bold) sb.setSpan(StyleSpan(Typeface.BOLD), at, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        for (item in t.items) sb.append("\n•  ").append(item)
        val main = text(sb, 15f, Type.regular, c.sub).apply { id = View.generateViewId(); tag = "scruter-cmp-tcf-text" }
        col.add(main, 8)
        val note = SpannableStringBuilder(t.note + " ")
        fun link(label: String, url: String, action: () -> Unit) {
            val at = note.length
            note.append(label)
            note.setSpan(ActionLink(url, action), at, note.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            note.setSpan(StyleSpan(Typeface.BOLD), at, note.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        // Every partner: the IAB's and Google's others.
        link(fill(w["viewPartners"], t.vendors.size + t.ac.size), "scruter-cmp://partners") { openStep(t.keys.size) }
        if (t.hasLi) {
            note.append(" · ")
            link(w["li"], "scruter-cmp://li") { openStep(t.liPlace?.let { t.keys.indexOf(it) }?.takeIf { it >= 0 } ?: t.keys.size) }
        }
        if (policyUrl != null) {
            note.append(" · ")
            link(w["privacy"], policyUrl) { Browser.open(activity, policyUrl, c.brand) }
        }
        val small = text(note, 13f, Type.regular, c.sub).apply {
            id = View.generateViewId()
            movementMethod = LinkMovementMethod.getInstance()
            setLinkTextColor(c.fg)
            minHeight = ctx.dp(48)
            tag = "scruter-cmp-tcf-note"
        }
        col.add(small, 6)
        small.accessibilityTraversalAfter = main.id
        return small
    }

    /** A row: its title, what it says, and its switch (none for what the visitor cannot refuse). */
    private fun row(col: LinearLayout, title: String, sw: View?, extra: (LinearLayout) -> Unit) {
        col.addView(View(ctx).apply { setBackgroundColor(c.line) }, LinearLayout.LayoutParams(-1, ctx.dp(1)))
        val r = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP
            minimumHeight = ctx.dp(48)
            setPadding(0, ctx.dp(8), 0, ctx.dp(8))
        }
        val body = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        body.addView(text(title, 15f, Type.medium, c.fg).apply { if (sw != null) importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO })
        extra(body)
        r.addView(body, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = ctx.dp(10) })
        if (sw != null) r.addView(sw)
        col.addView(r)
    }

    /** An IAB text's description, then its examples and the partners concerned (their names), folded (a tap unfolds them). */
    private fun about(body: LinearLayout, d: TcfText?, names: List<String>) {
        d?.description?.takeIf { it.isNotBlank() }?.let { body.add(text(it, 13f, Type.regular, c.sub), 2) }
        d?.illustrations?.takeIf { it.isNotEmpty() }?.let { fold(body, w["examples"], it.joinToString("\n\n")) }
        if (names.isNotEmpty()) fold(body, fill(w["partners"], names.size), names.joinToString(", "))
    }

    private fun fold(body: LinearLayout, title: String, content: String) {
        val more = text(content, 13f, Type.regular, c.sub).apply { visibility = View.GONE }
        val head = TextView(ctx).apply {
            text = SpannableStringBuilder(title).apply { setSpan(UnderlineSpan(), 0, length, 0) }
            style(13f, Type.medium, c.fg)
            gravity = Gravity.CENTER_VERTICAL
            minHeight = ctx.dp(48)
            background = ripple(null, c.fg)
            setOnClickListener { more.visibility = if (more.visibility == View.GONE) View.VISIBLE else View.GONE }
        }
        body.addView(head, LinearLayout.LayoutParams(-2, -2))
        body.add(more)
    }

    private fun name(d: Map<Int, TcfText>, id: Int) = TcfSheet.name(d, id)

    /** The IAB purposes of a step (the banner purpose [key]) or all of them ([key] null): consent switches, objections
     *  to legitimate interest, the special features (board M15, 1). */
    fun purposes(col: LinearLayout, key: String?) {
        fun mine(p: Int) = key == null || t.place(p) == key
        val cp = t.consentPurposes.filter(::mine)
        val lp = t.liPurposes.filter(::mine)
        val sf = if (key == null || t.place(0) == key) t.specialFeatures else emptyList()
        if (cp.isNotEmpty()) {
            col.add(heading(w["iabPurposes"] + " — " + w["consent"]), 16)
            for (p in cp) {
                val sw = switch(name(t.list.purposes, p), edit.purpose(p, st.on)) { on ->
                    edit.touched.add("p$p")
                    edit.purposes[p] = on
                    edit.moved = true
                    for (f in refreshers) f()
                }
                refreshers.add { if ("p$p" !in edit.touched) sw.isChecked = edit.purpose(p, st.on) }
                sw.tag = "scruter-cmp-iab-$p"
                row(col, name(t.list.purposes, p), sw) { about(it, t.list.purposes[p], t.consentNames(p)) }
            }
        }
        if (lp.isNotEmpty()) {
            col.add(heading(w["li"]), 16)
            col.add(text(w["liIntro"], 13f, Type.regular, c.sub), 4)
            for (p in lp) {
                val sw = switch(name(t.list.purposes, p), edit.purposeLi(p)) { edit.purposesLi[p] = it }
                sw.tag = "scruter-cmp-li-$p"
                row(col, name(t.list.purposes, p), sw) { about(it, t.list.purposes[p], t.vendors.filter { v -> p in v.li }.map { v -> v.v.name }) }
            }
        }
        if (sf.isNotEmpty()) {
            col.add(heading(w["specialFeatures"]), 16)
            for (f in sf) {
                val sw = switch(name(t.list.specialFeatures, f), edit.specialFeature(f)) { edit.specialFeatures[f] = it }
                sw.tag = "scruter-cmp-sf-$f"
                row(col, name(t.list.specialFeatures, f), sw) { about(it, t.list.specialFeatures[f], t.vendors.filter { v -> f in v.v.specialFeatures }.map { v -> v.v.name }) }
            }
        }
    }

    /** The partners (boards M7, 2 and M15, 2): IAB's notice, a search, each partner, Google's other ad tech providers in
     *  their own group, what nobody can refuse, the storage. */
    fun partners(col: LinearLayout): TextView {
        val title = text(fill(w["tcfTitle"], t.vendors.size), 19f, Type.medium, c.fg).apply {
            this.id = View.generateViewId()
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
            tag = "scruter-cmp-partners"
        }
        col.add(title)
        col.add(text(w["tcfPrefsIntro"], 13f, Type.regular, c.sub), 6)
        col.add(text(w["tcfLimits"].replace("{b}", name(t.list.specialPurposes, 1)), 13f, Type.regular, c.sub), 6)
        val list = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        val search = EditText(ctx).apply {
            hint = w["tcfSearch"]
            setText(edit.query)
            style(16f, Type.regular, c.fg)
            setHintTextColor(c.sub)
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            minHeight = ctx.dp(48)
            background = rounded(c.soft, ctx.dp(12).toFloat())
            setPaddingRelative(ctx.dp(12), 0, ctx.dp(12), 0)
            compoundDrawablePadding = ctx.dp(8)
            setCompoundDrawablesRelativeWithIntrinsicBounds(IconDrawable(listOf(SEARCH), 24f, ctx.dp(18), c.sub, 2.2f), null, null, null)
            // Its hint names it (an editable field's content description would hide what was typed).
            tag = "scruter-cmp-search"
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, d: Int) = Unit
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, d: Int) = Unit
                override fun afterTextChanged(s: Editable?) {
                    edit.query = s?.toString().orEmpty()
                    vendorRows(list)
                }
            })
        }
        col.add(search, 10)
        col.add(list, 6)
        vendorRows(list)
        if (t.specialPurposes.isNotEmpty()) {
            col.add(heading(w["specialPurposes"]), 16)
            for (p in t.specialPurposes) row(col, name(t.list.specialPurposes, p), null) { about(it, t.list.specialPurposes[p], t.vendors.filter { v -> p in v.v.specialPurposes }.map { v -> v.v.name }) }
        }
        if (t.features.isNotEmpty()) {
            col.add(heading(w["features"]), 16)
            col.add(text(t.list.featuresText ?: w["featuresText"], 13f, Type.regular, c.sub), 4)
            for (f in t.features) row(col, name(t.list.features, f), null) { about(it, t.list.features[f], t.vendors.filter { v -> f in v.v.features }.map { v -> v.v.name }) }
        }
        col.add(text(fill(w["tcfStorage"], t.renewMonths), 13f, Type.regular, c.sub), 14)
        return title
    }

    private fun vendorRows(list: LinearLayout) {
        list.removeAllViews()
        val q = edit.query.trim().lowercase(Locale.ROOT)
        for (v in t.vendors) {
            if (q.isNotEmpty() && q !in v.v.name.lowercase(Locale.ROOT)) continue
            list.addView(View(ctx).apply { setBackgroundColor(c.line) }, LinearLayout.LayoutParams(-1, ctx.dp(1)))
            val r = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            val open = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = ctx.dp(56)
                background = ripple(null, c.fg)
                isClickable = true
                setOnClickListener { go("vendor:${v.v.id}") }
                tag = "scruter-cmp-vendor-${v.v.id}"
            }
            val texts = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
            texts.addView(text(v.v.name, 16f, Type.medium, c.fg))
            val bases = listOfNotNull(w["consent"].takeIf { v.consent.isNotEmpty() }, w["li"].takeIf { v.li.isNotEmpty() })
            texts.addView(text(bases.joinToString(" · "), 13f, Type.regular, c.sub))
            open.addView(texts, LinearLayout.LayoutParams(0, -2, 1f))
            open.addView(ImageView(ctx).apply {
                setImageDrawable(IconDrawable(listOf(Icons.CHEV), 24f, ctx.dp(18), c.sub, 2.2f, mirror = st.model.rtl))
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(ctx.dp(24), ctx.dp(24)).apply { marginEnd = ctx.dp(8) })
            open.contentDescription = v.v.name + ", " + bases.joinToString(", ")
            r.addView(open, LinearLayout.LayoutParams(0, -2, 1f))
            if (v.consent.isNotEmpty()) {
                val sw = switch(v.v.name + " — " + w["consent"], edit.vendor(v, st.on)) { on ->
                    edit.touched.add("v${v.v.id}")
                    edit.vendors[v.v.id] = on
                }
                sw.tag = "scruter-cmp-vendor-consent-${v.v.id}"
                refreshers.add { if ("v${v.v.id}" !in edit.touched) sw.isChecked = edit.vendor(v, st.on) }
                r.addView(sw)
            }
            list.addView(r)
        }
        // Google's other ad tech providers (Additional Consent): apart from the TCF's partners (board M7, 2).
        val acs = t.ac.filter { q.isEmpty() || q in it.name.lowercase(Locale.ROOT) }
        if (acs.isEmpty()) return
        list.add(heading(fill(w["acTitle"], t.ac.size)).apply { tag = "scruter-cmp-ac" }, 16)
        list.add(text(w["acIntro"], 13f, Type.regular, c.sub), 4)
        for (a in acs) {
            list.addView(View(ctx).apply { setBackgroundColor(c.line) }, LinearLayout.LayoutParams(-1, ctx.dp(1)))
            val r = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            val open = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = ctx.dp(56)
                background = ripple(null, c.fg)
                isClickable = true
                setOnClickListener { go("ac:${a.id}") }
                tag = "scruter-cmp-ac-${a.id}"
                contentDescription = a.name + ", " + w["consent"]
            }
            val texts = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
            texts.addView(text(a.name, 16f, Type.medium, c.fg))
            texts.addView(text(w["consent"], 13f, Type.regular, c.sub))
            open.addView(texts, LinearLayout.LayoutParams(0, -2, 1f))
            open.addView(ImageView(ctx).apply {
                setImageDrawable(IconDrawable(listOf(Icons.CHEV), 24f, ctx.dp(18), c.sub, 2.2f, mirror = st.model.rtl))
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(ctx.dp(24), ctx.dp(24)).apply { marginEnd = ctx.dp(8) })
            r.addView(open, LinearLayout.LayoutParams(0, -2, 1f))
            val sw = switch(a.name + " — " + w["consent"], edit.ac(a.id, st.on)) { on ->
                edit.touched.add("a${a.id}")
                edit.ac[a.id] = on
            }
            sw.tag = "scruter-cmp-ac-consent-${a.id}"
            refreshers.add { if ("a${a.id}" !in edit.touched) sw.isChecked = edit.ac(a.id, st.on) }
            r.addView(sw)
            list.addView(r)
        }
    }

    /** One of Google's other ad tech providers: its consent, what that consent allows, its privacy policy (Google's list
     *  gives no more). */
    fun acProvider(col: LinearLayout, id: Int): TextView? {
        val a: AcProvider = t.ac.firstOrNull { it.id == id } ?: return null
        val title = text(a.name, 20f, Type.medium, c.fg).apply {
            this.id = View.generateViewId()
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        }
        col.add(title)
        val sw = switch(a.name + " — " + w["consent"], edit.ac(id, st.on)) { on ->
            edit.touched.add("a$id")
            edit.ac[id] = on
        }
        sw.tag = "scruter-cmp-detail-consent"
        row(col, w["consent"], sw) { it.add(text(w["acProviderIntro"], 14f, Type.regular, c.sub), 2) }
        val url = a.policyUrl ?: return title
        col.addView(TextView(ctx).apply {
            text = SpannableStringBuilder(w["privacy"]).apply { setSpan(UnderlineSpan(), 0, length, 0) }
            style(15f, Type.medium, c.fg)
            gravity = Gravity.CENTER_VERTICAL
            minHeight = ctx.dp(48)
            background = ripple(null, c.fg)
            setOnClickListener { Browser.open(activity, url, c.brand) }
        }, LinearLayout.LayoutParams(-2, -2))
        return title
    }

    /** One partner (board M7, 3): its consent and objection, purposes with retention, data, storage, policies. */
    fun vendor(col: LinearLayout, id: Int): TextView? {
        val v = t.vendors.firstOrNull { it.v.id == id } ?: return null
        val title = text(v.v.name, 20f, Type.medium, c.fg).apply {
            this.id = View.generateViewId()
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        }
        col.add(title)
        fun days(n: Int?) = n?.let { " (" + fill(w["retention"], it) + ")" } ?: ""
        fun list(ids: List<Int>, d: Map<Int, TcfText>, keep: Map<Int, Int>?) =
            text(ids.joinToString("\n") { "•  " + name(d, it) + days(keep?.get(it)) }, 14f, Type.regular, c.sub)
        if (v.consent.isNotEmpty()) {
            val sw = switch(v.v.name + " — " + w["consent"], edit.vendor(v, st.on)) { on ->
                edit.touched.add("v$id")
                edit.vendors[id] = on
            }
            sw.tag = "scruter-cmp-detail-consent"
            row(col, w["consent"], sw) { it.add(list(v.consent, t.list.purposes, v.v.retention), 2) }
        }
        if (v.li.isNotEmpty()) {
            val sw = switch(v.v.name + " — " + w["li"], edit.vendorLi(id)) { edit.vendorsLi[id] = it }
            sw.tag = "scruter-cmp-detail-li"
            row(col, w["li"], sw) { it.add(list(v.li, t.list.purposes, v.v.retention), 2) }
        }
        fun fact(label: String, ids: List<Int>, d: Map<Int, TcfText>, keep: Map<Int, Int>?) {
            if (ids.isEmpty()) return
            col.add(heading(label), 16)
            col.add(list(ids, d, keep), 4)
        }
        fact(w["specialPurposes"], v.v.specialPurposes, t.list.specialPurposes, v.v.retentionSp)
        fact(w["features"], v.v.features, t.list.features, null)
        fact(w["specialFeatures"], v.v.specialFeatures, t.list.specialFeatures, null)
        fact(w["dataCategories"], v.v.dataDeclaration, t.list.dataCategories, null)
        for (s in storage(v.v)) col.add(text(s, 14f, Type.regular, c.sub), 8)
        fun link(label: String, url: String?) {
            if (url == null) return
            col.addView(TextView(ctx).apply {
                text = SpannableStringBuilder(label).apply { setSpan(UnderlineSpan(), 0, length, 0) }
                style(15f, Type.medium, c.fg)
                gravity = Gravity.CENTER_VERTICAL
                minHeight = ctx.dp(48)
                background = ripple(null, c.fg)
                setOnClickListener { Browser.open(activity, url, c.brand) }
            }, LinearLayout.LayoutParams(-2, -2))
        }
        link(w["privacy"], v.policyUrl)
        link(w["liClaim"], v.liClaimUrl)
        link(w["storageDetails"], v.v.storageUrl)
        return title
    }

    /** Retention, the cookies' duration and renewal, other means than cookies (D(c)(VI)). */
    private fun storage(v: GvlVendor): List<String> {
        val out = ArrayList<String>()
        v.stdRetention?.let { out.add(fill(w["retention"], it)) }
        if (v.usesCookies && v.cookieMaxAgeSeconds != null) {
            out.add(w["duration"] + w["colon"] + duration(v.cookieMaxAgeSeconds, lang, w) + if (v.cookieRefresh) ", " + w["refresh"] else "")
        }
        if (v.usesNonCookieAccess) out.add(w["nonCookie"])
        return out
    }

    /** The preferences' two ways into the TCF layers (board M15, 3). */
    fun preferenceRows(col: LinearLayout) {
        val kinds = listOfNotNull(
            w["consent"].takeIf { t.consentPurposes.isNotEmpty() }, w["li"].takeIf { t.liPurposes.isNotEmpty() },
            w["specialFeatures"].takeIf { t.specialFeatures.isNotEmpty() },
        )
        fun row(title: String, sub: String, page: String, id: String) {
            col.addView(View(ctx).apply { setBackgroundColor(c.line) }, LinearLayout.LayoutParams(-1, ctx.dp(1)))
            val r = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = ctx.dp(64)
                background = ripple(null, c.fg)
                isClickable = true
                setOnClickListener { go(page) }
                contentDescription = if (sub.isEmpty()) title else "$title, $sub"
                tag = id
            }
            val texts = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
            texts.addView(text(title, 16f, Type.medium, c.fg))
            if (sub.isNotEmpty()) texts.addView(text(sub, 13f, Type.regular, c.sub))
            r.addView(texts, LinearLayout.LayoutParams(0, -2, 1f))
            r.addView(ImageView(ctx).apply {
                setImageDrawable(IconDrawable(listOf(Icons.CHEV), 24f, ctx.dp(20), c.sub, 2.2f, mirror = st.model.rtl))
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(ctx.dp(24), ctx.dp(24)))
            col.addView(r)
        }
        row(w["iabPurposes"], kinds.joinToString(" · "), "purposes", "scruter-cmp-tcf-purposes")
        row(fill(w["tcfTitle"], t.vendors.size), if (t.ac.isEmpty()) "" else fill(w["acTitle"], t.ac.size), "partners", "scruter-cmp-tcf-partners")
    }

    companion object {
        const val SEARCH = "M17.5 11A6.5 6.5 0 1 1 4.5 11A6.5 6.5 0 1 1 17.5 11M16 16L20.5 20.5"

        /** « 13 mois », « 1 an » in the banner's language (the site script's `duration`). */
        fun duration(seconds: Long, lang: String, w: Words): String {
            if (seconds < 0) return w["persistent"]
            val day = 86_400L
            val (n, unit) = when {
                seconds < day -> maxOf(1L, Math.round(seconds / 3600.0)) to android.icu.util.MeasureUnit.HOUR
                seconds < 60 * day -> Math.round(seconds / day.toDouble()) to android.icu.util.MeasureUnit.DAY
                seconds < 730 * day -> Math.round(seconds / (30.44 * day)) to android.icu.util.MeasureUnit.MONTH
                else -> Math.round(seconds / (365.25 * day)) to android.icu.util.MeasureUnit.YEAR
            }
            return try {
                android.icu.text.MeasureFormat.getInstance(Locale.forLanguageTag(lang), android.icu.text.MeasureFormat.FormatWidth.WIDE)
                    .format(android.icu.util.Measure(n, unit))
            } catch (e: RuntimeException) {
                "$n"
            }
        }
    }
}
