package net.scruter.cmp.internal

import android.content.SharedPreferences
import org.json.JSONObject
import java.io.File
import java.text.Collator
import java.util.Locale

/**
 * The IAB TCF of the app (docs/CMP-MOBILE.md §6), on the engine's worker: the settings of the configuration, the vendor
 * subset and IAB's translations (fetched from the configuration's endpoint and cached), the stored TC string, Google's
 * Additional Consent string and the in-app keys in the default `SharedPreferences` kept in step with every change, the
 * re-ask of rule 5 (docs/CMP.md §4.4), the proof's `tc` and `gv`.
 */
internal class TcfState(
    /** The default `SharedPreferences`, where ad SDKs read the `IABTCF_*` keys. */
    private val iab: SharedPreferences,
    /** The module's own preferences: the stored TC string (`tcf`, as the web's `scruter_tcf`). */
    private val kept: SharedPreferences,
    private val dir: File,
) {
    @Volatile
    var settings: TcfSettings? = null
        private set

    @Volatile
    var list: VendorList? = null
        private set
    private var listName: String? = null
    private var endpoint = ""

    val stored: String? get() = kept.getString(K_TC, null)
    /** Google's Additional Consent string of the stored decision (a site with Google's other ad tech providers). */
    val storedAc: String? get() = kept.getString(K_AC, null)
    val on: Boolean get() = settings != null

    /** A configuration (cached or new): its TCF settings; with the TCF off, nothing of ours stays for vendors to read. */
    fun configure(c: CmpConfig?) {
        val t = TcfSettings.parse(c?.tcf)
        if (c == null || t == null) {
            settings = null
            list = null
            listName = null
            if (kept.contains(K_MARKER) || stored != null) removeAll()
            return
        }
        settings = t
        endpoint = c.endpoint
        // Vendors know a CMP is there and the GDPR applies before any choice (IAB in-app: « as soon as it is initialized »).
        val e = iab.edit()
        val cur = iab.all
        var changed = false
        fun int(k: String, v: Int) {
            if ((cur[k] as? Int) != v) {
                e.putInt(k, v)
                changed = true
            }
        }
        int("IABTCF_CmpSdkID", t.cmpId)
        int("IABTCF_CmpSdkVersion", t.cmpVersion)
        int("IABTCF_PolicyVersion", t.policyVersion)
        int("IABTCF_gdprApplies", 1)
        int("IABTCF_PurposeOneTreatment", 0)
        int("IABTCF_UseNonStandardTexts", 0)
        if ((cur["IABTCF_PublisherCC"] as? String) != t.cc) {
            e.putString("IABTCF_PublisherCC", t.cc)
            changed = true
        }
        if (changed) e.commit()
        if (!kept.contains(K_MARKER)) kept.edit().putBoolean(K_MARKER, true).commit()
        // The stored decision's keys, kept in step (an app or a library may have removed them).
        stored?.let { tc -> if ((cur["IABTCF_TCString"] as? String) != tc || (cur["IABTCF_AddtlConsent"] as? String) != storedAc) writeKeys(tc, storedAc, null) }
        val name = "tcf-v-" + Integer.toHexString(t.vendorsUrl.hashCode()) + ".json"
        if (name != listName) {
            listName = name
            list = File(dir, name).takeIf { it.isFile }?.let { VendorList.parse(it.readText()) } ?: fetchList(name, t)
        }
    }

    /** Only the configuration's own origin (the web never calls consensu.org: neither does the app). */
    private fun url(path: String): String? =
        if (path.startsWith("/cmp/") && Regex("\\.json(\\?r=\\d+)?$").containsMatchIn(path)) endpoint + path else null

    private fun fetchList(name: String, t: TcfSettings): VendorList? {
        val u = url(t.vendorsUrl) ?: return null
        val f = File(dir, name)
        if (!Net.download(u, f, MAX_LIST)) return null
        val l = VendorList.parse(f.readText())
        if (l == null) f.delete() else dir.listFiles()?.forEach { if (it.name.startsWith("tcf-v-") && it.name != name) it.delete() }
        return l
    }

    /** docs/CMP.md §4.4 rule 5 for the current settings. */
    fun mustAsk(): Boolean {
        val t = settings ?: return false
        return Tcf.mustAsk(t, stored, list, storedAc)
    }

    /** Encodes a decision and writes the string and the keys (before the sheet closes). */
    fun decide(granted: Set<String>, choice: TcfChoice?, c: CmpConfig, lang: String, now: Long) {
        val t = settings ?: return
        val m = Tcf.build(t, list, c.purposes, lang, now, granted, choice)
        val tc = TcString.encode(m)
        val ac = Tcf.ac(t, list, m, choice)?.let { Tcf.acString(it) }
        kept.edit().putString(K_TC, tc).apply { if (ac != null) putString(K_AC, ac) else remove(K_AC) }.putBoolean(K_MARKER, true).commit()
        writeKeys(tc, ac, m)
        Log.d(if (ac == null) "TC string written" else "TC string and Additional Consent string written")
    }

    private fun writeKeys(tc: String, ac: String?, model: TcModel?) {
        val m = model ?: TcString.decode(tc) ?: return
        val e = iab.edit()
        for (k in Tcf.decisionKeys) e.remove(k)
        for ((k, v) in Tcf.keys(m, tc, ac)) if (v is Int) e.putInt(k, v) else e.putString(k, v as String)
        e.commit()
    }

    /** The proof's `tc` (the TC string, then Google's Additional Consent string after `~`) and `gv` (docs/CMP.md §6.1). */
    fun proofFields(): Pair<String, Int>? {
        val t = settings ?: return null
        val tc = stored ?: return null
        return (tc + (storedAc?.let { "~$it" } ?: "")) to t.gvlVersion
    }

    /** The choice ran out or is gone: no decision is signalled until the next one. */
    fun clearDecision() {
        if (stored == null) return
        kept.edit().remove(K_TC).remove(K_AC).commit()
        val e = iab.edit()
        for (k in Tcf.decisionKeys) e.remove(k)
        e.commit()
    }

    /** `debugReset()`, or the TCF turned off: every key of ours goes. */
    fun removeAll() {
        kept.edit().remove(K_TC).remove(K_AC).remove(K_MARKER).commit()
        val e = iab.edit()
        for (k in Tcf.allKeys) e.remove(k)
        e.commit()
    }

    fun reset(c: CmpConfig?) {
        removeAll()
        listName = null
        configure(c)
    }

    /** The vendor list with IAB's texts in [lang] for the sheet (null: no vendor list, the standard layers show). */
    fun sheetList(lang: String): VendorList? {
        val t = settings ?: return null
        val base = list ?: listName?.let { n -> fetchList(n, t)?.also { list = it } } ?: return null
        val l = lang.lowercase()
        if (l.startsWith("en")) return base.translated(null, l)
        val f = File(dir, "tcf-t-${t.gvlVersion}-$l.json")
        if (!f.isFile) url(t.translationsUrl.replace("{lang}", l))?.let { Net.download(it, f, MAX_LIST) }
        val tr = try {
            if (f.isFile) JSONObject(f.readText()) else null
        } catch (e: Exception) {
            f.delete()
            null
        }
        return base.translated(tr, l)
    }

    /** The visitor's previous TCF choice, when the stored string is current. */
    fun storedChoice(): TcfChoice? {
        val t = settings ?: return null
        val tc = stored ?: return null
        val m = TcString.decode(tc) ?: return null
        return if (Tcf.mustAsk(t, tc, null)) null else Tcf.choice(t, m, storedAc?.let { Tcf.parseAc(it) })
    }

    companion object {
        const val K_TC = "tcf"
        const val K_AC = "tcfAc"
        const val K_MARKER = "tcfKeys"
        const val MAX_LIST = 8L * 1024 * 1024
    }
}

/** What the TCF layers draw (docs/CMP.md §4.7 « As built », boards M7 and M15), prepared on the worker. */
internal class TcfSheet(
    val settings: TcfSettings,
    val list: VendorList,
    val vendors: List<Vendor>,
    /** Google's other ad tech providers of the selection, by name (Additional Consent). */
    val ac: List<AcProvider>,
    /** The first layer's IAB text in the message's place: runs, bold for what it names. */
    val first: List<Pair<String, Boolean>>,
    /** Without stacks (purpose 1 alone): the purposes and special features as a list under [first]. */
    val items: List<String>,
    val note: String,
    val hasLi: Boolean,
    /** The banner purposes the steps show, in order. */
    val keys: List<String>,
    val consentPurposes: List<Int>,
    val liPurposes: List<Int>,
    val specialPurposes: List<Int>,
    val features: List<Int>,
    val specialFeatures: List<Int>,
    /** The visitor's previous TCF choice (preferences, a returning visitor), else null. */
    val stored: TcfChoice?,
    val renewMonths: Int,
) {
    class Vendor(val v: GvlVendor, val consent: List<Int>, val li: List<Int>, val policyUrl: String?, val liClaimUrl: String?)

    /** The step (banner purpose key) that shows IAB purpose [p]: the one it is grouped under, else (and for the special
     *  features, [p] 0) the one grouping the most IAB purposes. */
    fun place(p: Int): String? {
        settings.stacks[p]?.let { if (it in keys) return it }
        var main = keys.firstOrNull()
        var most = -1
        for (k in keys) {
            val n = settings.stacks.values.count { it == k }
            if (n > most) {
                main = k
                most = n
            }
        }
        return main
    }

    /** The step the « Intérêt légitime » link opens: the one of the first purpose a vendor rests on it for. */
    val liPlace: String? get() = liPurposes.firstOrNull()?.let { place(it) }

    /** The names of the partners resting on consent for IAB purpose [p]: the IAB's, then Google's for 1, 3 and 4. */
    fun consentNames(p: Int): List<String> = vendors.filter { p in it.consent }.map { it.v.name } + (if (p in Tcf.AC_PURPOSES) ac.map { it.name } else emptyList())

    companion object {
        fun name(d: Map<Int, TcfText>, id: Int): String = d[id]?.name ?: "#$id"

        fun build(t: TcfSettings, list: VendorList, purposes: List<Rules.Purpose>, names: Map<String, String>, w: Words, lang: String, stored: TcfChoice?, renewMonths: Int): TcfSheet? {
            val vs = t.vendors.mapNotNull { list.live(it) }.map {
                Vendor(it, Tcf.vendorPurposes(t, it, "consent"), Tcf.vendorPurposes(t, it, "legitimate_interest"), it.url("privacy", lang), it.url("legIntClaim", lang))
            }
            val acs = list.liveAc(t)
            if (vs.isEmpty() && acs.isEmpty()) return null
            val collator = Collator.getInstance(Locale.forLanguageTag(lang))
            val sorted = vs.sortedWith { a, b -> collator.compare(a.v.name, b.v.name) }
            val acSorted = acs.sortedWith { a, b -> collator.compare(a.name, b.name) }
            val all = (1..Tcf.PURPOSES).toList()
            // Google's providers rest on consent for purposes 1, 3 and 4.
            val cps = all.filter { p -> vs.any { p in it.consent } || (acs.isNotEmpty() && p in Tcf.AC_PURPOSES) }
            val lps = all.filter { p -> vs.any { p in it.li } }
            val sfs = t.specialFeatures.filter { f -> vs.any { f in it.v.specialFeatures } }
            val li = vs.any { it.li.isNotEmpty() }
            // Every partner: the IAB's and Google's others.
            val n = vs.size + acs.size
            val shown = all.filter { it in cps || it in lps }
            fun fill(s: String) = s.replace("{n}", n.toString())
            fun bold(s: String, k: String, b: String): List<Pair<String, Boolean>> {
                val i = s.indexOf(k)
                if (i < 0) return listOf(s to false)
                return listOf(s.substring(0, i) to false, b to true, s.substring(i + k.length) to false)
            }
            val first: List<Pair<String, Boolean>>
            val items: List<String>
            if (1 in shown && shown.size > 1) {
                // Purpose 1 is the sentence itself; first the banner's purposes no IAB purpose is grouped under, then the
                // IAB purposes by the stacks that gather them (`cmp/src/tcf/stacks.ts`).
                val grouped = t.stacks.values.toSet()
                val own = purposes.filter { !it.required && it.key !in grouped }.map { names[it.key] ?: it.key }
                val said = own + cover(list.stacks, shown.drop(1)).map { if (it > 0) name(list.stacks, it) else name(list.purposes, -it) }
                val runs = ArrayList(bold(fill(w["tcfShort"]), "{s}", phrase(said, lang)))
                if (sfs.isNotEmpty()) {
                    val fs = featureStack(list.stacks, sfs)
                    val sfNames = if (fs > 0) listOf(name(list.stacks, fs)) else sfs.map { name(list.specialFeatures, it) }
                    runs.add(" " to false)
                    runs.addAll(bold(w["tcfSfShort"], "{f}", phrase(sfNames, lang)))
                }
                first = runs.filter { it.first.isNotEmpty() }
                items = emptyList()
            } else {
                first = listOf(fill(w["tcfIntro"]) to false)
                items = shown.map { name(list.purposes, it) } + sfs.map { name(list.specialFeatures, it) }
            }
            return TcfSheet(
                t, list, sorted, acSorted, first, items, (if (li) w["tcfLiShort"] + " " else "") + w["tcfScope"], li,
                purposes.filter { !it.required }.map { it.key }, cps, lps,
                all.filter { p -> vs.any { p in it.v.specialPurposes } }, all.filter { p -> vs.any { p in it.v.features } },
                sfs, stored, renewMonths,
            )
        }

        /** [items] as one phrase of the language (« a, b et c »); names in a sentence start in lower case, but in German. */
        fun phrase(items: List<String>, lang: String): String {
            val low = items.map { s -> if (lang.lowercase().startsWith("de") || s.isEmpty()) s else s.substring(0, 1).lowercase(Locale.forLanguageTag(lang)) + s.substring(1) }
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                try {
                    return android.icu.text.ListFormatter.getInstance(Locale.forLanguageTag(lang)).format(low)
                } catch (e: RuntimeException) {
                    // A language ICU does not know: the plain list below.
                }
            }
            return low.joinToString(", ")
        }

        /**
         * The stacks of purposes only that say [want] (IAB purposes 2–11), disjoint, the fewest first; where no exact cover
         * exists, those covering the most, then the remaining purposes alone: stack ids (> 0) and purposes (< 0).
         */
        fun cover(stacks: Map<Int, TcfText>, want: List<Int>): List<Int> {
            fun mask(ids: List<Int>) = ids.fold(0) { m, p -> m or (1 shl p) }
            val all = mask(want)
            val cand = stacks.mapNotNull { (id, s) ->
                val m = mask(s.purposes)
                if (m != 0 && s.specialFeatures.isEmpty() && (m and all.inv()) == 0) id to m else null
            }.sortedBy { it.first }
            val best = HashMap<Int, List<Int>>()
            best[0] = emptyList()
            val queue = arrayListOf(0)
            var top = 0
            var i = 0
            while (i < queue.size) {
                val m = queue[i++]
                if (Integer.bitCount(m) > Integer.bitCount(top)) top = m
                for ((id, c) in cand) if ((m and c) == 0 && best[m or c] == null) {
                    best[m or c] = best[m]!! + id
                    queue.add(m or c)
                }
            }
            return best[top]!!.sorted() + want.filter { (top and (1 shl it)) == 0 }.map { -it }
        }

        /** The stack of special features only that gathers exactly [sf] (stack 1: both), else 0. */
        fun featureStack(stacks: Map<Int, TcfText>, sf: List<Int>): Int {
            fun mask(ids: List<Int>) = ids.fold(0) { m, p -> m or (1 shl p) }
            return stacks.filter { it.value.purposes.isEmpty() && mask(it.value.specialFeatures) == mask(sf) }.keys.minOrNull() ?: 0
        }
    }
}
