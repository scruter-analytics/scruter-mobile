package net.scruter.cmp.internal

import org.json.JSONArray
import org.json.JSONObject

// The IAB TCF v2.2 in the app (docs/CMP-MOBILE.md §6): the site's TCF settings, the vendor list, the TC model of a
// decision, the TC string, Google's Additional Consent string and the in-app keys. A port of the site script's
// `cmp/src/tcf/model.ts` and `tcstring.ts`, checked against the kit's `tcf-vectors.json`, which is generated from them.

private fun JSONArray?.ints(): List<Int> {
    if (this == null) return emptyList()
    val out = ArrayList<Int>(length())
    for (i in 0 until length()) (opt(i) as? Number)?.let { out.add(it.toInt()) }
    return out
}

private fun JSONObject?.byId(): Map<Int, String> {
    if (this == null) return emptyMap()
    val out = HashMap<Int, String>()
    for (k in keys()) {
        val id = k.toIntOrNull() ?: continue
        optStringOrNull(k)?.let { out[id] = it }
    }
    return out
}

/** `config.tcf`: the site's TCF settings, which apply to its app. */
internal class TcfSettings(
    val cmpId: Int,
    val cmpVersion: Int,
    val gvlVersion: Int,
    val policyVersion: Int,
    val publisherCC: String,
    val vendors: List<Int>,
    /** IAB purpose → `consent`, `legitimate_interest` or `off`. */
    val purposes: Map<Int, String>,
    val specialFeatures: List<Int>,
    /** IAB purpose → the banner purpose it is grouped under. */
    val stacks: Map<Int, String>,
    val vendorsUrl: String,
    val translationsUrl: String,
    /** Google's other ad tech providers (ids of its Additional Consent list), shown after the vendors. */
    val acProviders: List<Int> = emptyList(),
) {
    /** The publisher's legal basis of IAB purpose [p] (purposes 1 and 3–6 rest on consent only). */
    fun basis(p: Int): String {
        val b = purposes[p] ?: "off"
        return if (b == "legitimate_interest" && p in CONSENT_ONLY) "off" else b
    }

    val cc: String get() = publisherCC.uppercase().let { if (Regex("^[A-Z]{2}$").matches(it)) it else "FR" }

    companion object {
        private val CONSENT_ONLY = setOf(1, 3, 4, 5, 6)

        fun parse(j: JSONObject?): TcfSettings? {
            if (j == null || !j.has("cmp_id") || !j.has("gvl_version") || !j.has("policy_version")) return null
            val gvl = j.optInt("gvl_version")
            return TcfSettings(
                j.optInt("cmp_id"), j.optInt("cmp_version", 1), gvl, j.optInt("policy_version"),
                j.optString("publisher_cc", "FR"), j.optJSONArray("vendors").ints(), j.optJSONObject("purposes").byId(),
                j.optJSONArray("special_features").ints(), j.optJSONObject("stacks").byId(), j.optString("vendors_url"),
                j.optStringOrNull("translations_url") ?: "/cmp/tcf/$gvl/{lang}.json",
                j.optJSONArray("ac_providers").ints(),
            )
        }
    }
}

/** One vendor of the GVL as the vendor subset serves it. */
internal class GvlVendor(j: JSONObject) {
    val id: Int = j.getInt("id")
    val name: String = j.optString("name", "#$id").trim()
    val purposes = j.optJSONArray("purposes").ints()
    val legIntPurposes = j.optJSONArray("legIntPurposes").ints()
    val flexiblePurposes = j.optJSONArray("flexiblePurposes").ints()
    val specialPurposes = j.optJSONArray("specialPurposes").ints()
    val features = j.optJSONArray("features").ints()
    val specialFeatures = j.optJSONArray("specialFeatures").ints()
    val dataDeclaration = j.optJSONArray("dataDeclaration").ints()
    private val policyUrl = j.optStringOrNull("policyUrl")
    private val urls = j.optJSONArray("urls")
    val cookieMaxAgeSeconds: Long? = if (j.isNull("cookieMaxAgeSeconds") || !j.has("cookieMaxAgeSeconds")) null else j.optLong("cookieMaxAgeSeconds")
    val usesCookies = j.optBoolean("usesCookies")
    val cookieRefresh = j.optBoolean("cookieRefresh")
    val usesNonCookieAccess = j.optBoolean("usesNonCookieAccess")
    val storageUrl: String? = j.optStringOrNull("deviceStorageDisclosureUrl")?.takeIf { it.startsWith("https://") }
    private val retentionObj = j.optJSONObject("dataRetention")
    val stdRetention: Int? = retentionObj?.takeIf { it.has("stdRetention") && !it.isNull("stdRetention") }?.optInt("stdRetention")
    val retention: Map<Int, Int> = days(retentionObj?.optJSONObject("purposes"))
    val retentionSp: Map<Int, Int> = days(retentionObj?.optJSONObject("specialPurposes"))
    val deleted = j.optStringOrNull("deletedDate") != null

    private fun days(o: JSONObject?): Map<Int, Int> {
        if (o == null) return emptyMap()
        val out = HashMap<Int, Int>()
        for (k in o.keys()) {
            val p = k.toIntOrNull() ?: continue
            (o.opt(k) as? Number)?.let { out[p] = it.toInt() }
        }
        return out
    }

    /** The vendor's privacy policy or legitimate interest claim in [lang], else English, else the first. */
    fun url(key: String, lang: String): String? {
        val l = lang.lowercase().take(2)
        var pick: JSONObject? = null
        var en: JSONObject? = null
        var first: JSONObject? = null
        for (i in 0 until (urls?.length() ?: 0)) {
            val u = urls!!.optJSONObject(i) ?: continue
            if (first == null) first = u
            val id = u.optString("langId").lowercase()
            if (id == l && pick == null) pick = u
            if (id == "en" && en == null) en = u
        }
        val v = (pick ?: en ?: first)?.optStringOrNull(key) ?: if (key == "privacy") policyUrl else null
        return v?.takeIf { it.startsWith("https://") }
    }
}

/** One of Google's other ad tech providers (its Additional Consent list gives a name and a privacy policy, no more). */
internal class AcProvider(val id: Int, val name: String, /** http or https, as Google lists it. */ val policyUrl: String?)

/** What Google's Additional Consent string says: the providers consented, then those only disclosed. */
internal data class AcData(val consented: List<Int>, val disclosed: List<Int>)

/** An IAB text: a purpose, special purpose, feature, special feature, data category or stack. */
internal class TcfText(val name: String, val description: String, val illustrations: List<String>, val purposes: List<Int>, val specialFeatures: List<Int>)

/** `GET /cmp/{code}/vendors-{gvl}.json`, and the texts of `GET /cmp/tcf/{gvl}/{lang}.json` laid over it. */
internal class VendorList(
    val vendors: Map<Int, GvlVendor>,
    val purposes: Map<Int, TcfText>,
    val specialPurposes: Map<Int, TcfText>,
    val features: Map<Int, TcfText>,
    val specialFeatures: Map<Int, TcfText>,
    val dataCategories: Map<Int, TcfText>,
    val stacks: Map<Int, TcfText>,
    val featuresText: String?,
    /** Google's other ad tech providers of the selection still on Google's list. */
    val acProviders: Map<Int, AcProvider> = emptyMap(),
) {
    /** A selected vendor of the list, unless the GVL deleted it (its signals stay 0). */
    fun live(id: Int): GvlVendor? = vendors[id]?.takeIf { !it.deleted }

    /** The site's selected providers of Google's list found in the vendor list, by id. */
    fun liveAc(t: TcfSettings): List<AcProvider> = t.acProviders.mapNotNull { acProviders[it] }.sortedBy { it.id }

    /** IAB's translation of the texts (the stacks keep what they gather); the list's standard texts only for English. */
    fun translated(tr: JSONObject?, lang: String): VendorList {
        fun lay(key: String, base: Map<Int, TcfText>): Map<Int, TcfText> {
            val t = texts(tr?.optJSONObject(key))
            if (t.isEmpty()) return base
            val out = HashMap(base)
            for ((id, x) in t) {
                val cur = base[id]
                out[id] = if (cur != null) TcfText(x.name, x.description, if (key == "stacks" && x.illustrations.isEmpty()) cur.illustrations else x.illustrations, cur.purposes, cur.specialFeatures)
                else if (key == "stacks") continue else x
            }
            return out
        }
        val ft = tr?.optJSONObject("standardTexts")?.optStringOrNull("features") ?: if (lang.lowercase().startsWith("en")) featuresText else null
        return VendorList(
            vendors, lay("purposes", purposes), lay("specialPurposes", specialPurposes), lay("features", features),
            lay("specialFeatures", specialFeatures), lay("dataCategories", dataCategories), lay("stacks", stacks), ft, acProviders,
        )
    }

    companion object {
        fun texts(o: JSONObject?): Map<Int, TcfText> {
            if (o == null) return emptyMap()
            val out = HashMap<Int, TcfText>()
            for (k in o.keys()) {
                val id = k.toIntOrNull() ?: continue
                val t = o.optJSONObject(k) ?: continue
                out[id] = TcfText(
                    t.optString("name", "#$id"), t.optString("description"), t.optJSONArray("illustrations").strings(),
                    t.optJSONArray("purposes").ints(), t.optJSONArray("specialFeatures").ints(),
                )
            }
            return out
        }

        fun parse(text: String): VendorList? = try {
            val j = JSONObject(text)
            val vs = j.getJSONObject("vendors")
            val map = HashMap<Int, GvlVendor>()
            for (k in vs.keys()) vs.optJSONObject(k)?.let { o -> if (o.has("id")) GvlVendor(o).let { map[it.id] = it } }
            val ac = HashMap<Int, AcProvider>()
            val acs = j.optJSONObject("acProviders")
            for (k in acs?.keys() ?: emptyList<String>().iterator()) {
                val o = acs!!.optJSONObject(k) ?: continue
                val id = (o.opt("id") as? Number)?.toInt() ?: continue
                val name = o.optStringOrNull("name") ?: continue
                ac[id] = AcProvider(id, name, o.optStringOrNull("policyUrl")?.takeIf { it.startsWith("https://") || it.startsWith("http://") })
            }
            VendorList(
                map, texts(j.optJSONObject("purposes")), texts(j.optJSONObject("specialPurposes")), texts(j.optJSONObject("features")),
                texts(j.optJSONObject("specialFeatures")), texts(j.optJSONObject("dataCategories")), texts(j.optJSONObject("stacks")),
                j.optJSONObject("standardTexts")?.optStringOrNull("features"), ac,
            )
        } catch (e: Exception) {
            null
        }
    }
}

/** What the visitor chose in the TCF layers (`TcfChoice` of the site script): absent entries follow the banner purposes. */
internal data class TcfChoice(
    val vendors: Map<Int, Boolean> = emptyMap(),
    /** Legitimate interest kept (false: the visitor objected). */
    val vendorsLi: Map<Int, Boolean> = emptyMap(),
    val purposesLi: Map<Int, Boolean> = emptyMap(),
    val specialFeatures: Map<Int, Boolean> = emptyMap(),
    /** IAB purposes on consent the visitor set one by one. */
    val purposes: Map<Int, Boolean>? = null,
    /** Google's other ad tech providers; absent ones follow IAB purposes 1, 3 and 4. */
    val ac: Map<Int, Boolean> = emptyMap(),
)

/** A publisher restriction: purpose, type (0 not allowed, 1 require consent, 2 require legitimate interest), vendors. */
internal data class TcRestriction(val purpose: Int, val type: Int, val vendors: MutableList<Int>)

/** The fields of a TC string (core segment, disclosed vendors, publisher TC). */
internal class TcModel {
    var created = 0L
    var updated = 0L
    var cmpId = 0
    var cmpVersion = 0
    var consentScreen = 1
    var consentLanguage = "EN"
    var vendorListVersion = 0
    var policyVersion = 0
    var isServiceSpecific = true
    var useNonStandardTexts = false
    var specialFeatureOptins: List<Int> = emptyList()
    var purposeConsents: List<Int> = emptyList()
    var purposeLegitimateInterests: List<Int> = emptyList()
    var purposeOneTreatment = false
    var publisherCC = "FR"
    var vendorConsents: List<Int> = emptyList()
    var vendorLegitimateInterests: List<Int> = emptyList()
    var restrictions: MutableList<TcRestriction> = ArrayList()
    var vendorsDisclosed: List<Int>? = null
    var publisherConsents: List<Int>? = null
    var publisherLegitimateInterests: List<Int> = emptyList()
}

internal object Tcf {
    const val PURPOSES = 11
    const val SPECIAL_FEATURES = 2
    /** IAB purposes an Additional Consent stands for (storage on the device, profiles and personalised ads). */
    val AC_PURPOSES = listOf(1, 3, 4)

    /** The vendor's purposes resting on [b] under the publisher's settings (its declarations, flexible ones included). */
    fun vendorPurposes(t: TcfSettings, v: GvlVendor, b: String): List<Int> {
        val own = if (b == "consent") v.purposes else v.legIntPurposes
        val other = if (b == "consent") v.legIntPurposes else v.purposes
        return (1..PURPOSES).filter { p -> t.basis(p) == b && (p in own || (p in v.flexiblePurposes && p in other)) }
    }

    /**
     * The TC model of a decision (`buildModel` of the site script): [granted] the banner purposes, [choice] the TCF
     * layers' switches (null: everything follows the banner purposes), [now] in milliseconds.
     */
    fun build(t: TcfSettings, list: VendorList?, purposes: List<Rules.Purpose>, lang: String, now: Long, granted: Set<String>, choice: TcfChoice?): TcModel {
        val optional = purposes.filter { !it.required }
        val allGranted = optional.all { it.key in granted }
        val noneGranted = optional.none { it.key in granted }
        fun purposeGranted(p: Int): Boolean = t.stacks[p]?.let { it in granted } ?: allGranted
        val set = choice?.purposes
        val listed = t.vendors.mapNotNull { list?.live(it) }
        // Google's providers rest on consent for purposes 1, 3 and 4.
        val ac = list?.liveAc(t)?.isNotEmpty() == true
        fun shown(b: String, p: Int) = listed.any { p in vendorPurposes(t, it, b) } || (ac && b == "consent" && p in AC_PURPOSES)
        val pc = (1..PURPOSES).filter { p -> t.basis(p) == "consent" && shown("consent", p) && (set?.get(p) ?: purposeGranted(p)) }
        val pli = (1..PURPOSES).filter { p ->
            t.basis(p) == "legitimate_interest" && shown("legitimate_interest", p) && (if (choice != null) choice.purposesLi[p] != false else !noneGranted)
        }
        val sf = t.specialFeatures.filter { f -> listed.any { f in it.specialFeatures } && (if (choice != null) choice.specialFeatures[f] == true else allGranted) }
        val vc = ArrayList<Int>()
        val vli = ArrayList<Int>()
        val disclosed = ArrayList<Int>()
        val restrictions = ArrayList<TcRestriction>()
        fun restrict(p: Int, type: Int, id: Int) {
            val r = restrictions.firstOrNull { it.purpose == p && it.type == type }
            if (r != null) r.vendors.add(id) else restrictions.add(TcRestriction(p, type, arrayListOf(id)))
        }
        for (id in t.vendors) {
            val v = list?.live(id) ?: continue
            disclosed.add(id)
            val cp = vendorPurposes(t, v, "consent")
            val lp = vendorPurposes(t, v, "legitimate_interest")
            val derived = cp.isNotEmpty() && cp.all { it in pc }
            if (cp.isNotEmpty() && (choice?.vendors?.get(id) ?: derived)) vc.add(id)
            val liDerived = lp.any { it in pli }
            if (lp.isNotEmpty() && (choice?.vendorsLi?.get(id) ?: liDerived)) vli.add(id)
            for (p in 1..PURPOSES) {
                if (p !in v.purposes && p !in v.legIntPurposes) continue
                val b = t.basis(p)
                if (b == "off") restrict(p, 0, id)
                else if (p in v.flexiblePurposes) {
                    if (b == "consent" && p in v.legIntPurposes) restrict(p, 1, id)
                    if (b == "legitimate_interest" && p in v.purposes) restrict(p, 2, id)
                }
            }
        }
        val m = TcModel()
        val day = TcString.day(now)
        m.created = day
        m.updated = day
        m.cmpId = t.cmpId
        m.cmpVersion = t.cmpVersion
        m.consentLanguage = if (Regex("^[a-zA-Z]{2}").containsMatchIn(lang)) lang.take(2).uppercase() else "EN"
        m.vendorListVersion = t.gvlVersion
        m.policyVersion = t.policyVersion
        m.specialFeatureOptins = sf
        m.purposeConsents = pc
        m.purposeLegitimateInterests = pli
        m.publisherCC = t.cc
        m.vendorConsents = vc
        m.vendorLegitimateInterests = vli
        m.restrictions = restrictions
        m.vendorsDisclosed = disclosed
        m.publisherConsents = pc
        m.publisherLegitimateInterests = pli
        return m
    }

    /**
     * The Additional Consent of a decision ([m] its TC model), or null for a site without Google's other ad tech
     * providers: every selected provider of the vendor list disclosed, consented when purposes 1, 3 and 4 are and the
     * visitor did not refuse it (`buildAc` of the site script).
     */
    fun ac(t: TcfSettings, list: VendorList?, m: TcModel, choice: TcfChoice?): AcData? {
        if (t.acProviders.isEmpty()) return null
        val personal = AC_PURPOSES.all { it in m.purposeConsents }
        val consented = ArrayList<Int>()
        val disclosed = ArrayList<Int>()
        for (a in list?.liveAc(t) ?: emptyList()) if (personal && choice?.ac?.get(a.id) != false) consented.add(a.id) else disclosed.add(a.id)
        return AcData(consented, disclosed)
    }

    /** Google's Additional Consent string v2: `2~<consented>~dv.<only disclosed>`, ids ascending. */
    fun acString(a: AcData): String = "2~" + a.consented.sorted().joinToString(".") + "~dv." + a.disclosed.sorted().joinToString(".")

    /** A stored Additional Consent string (version 2, or 1: consents only), else null. */
    fun parseAc(s: String): AcData? {
        val m = Regex("^2~([0-9.]*)~dv\\.?([0-9.]*)$").find(s) ?: Regex("^1~([0-9.]*)()$").find(s) ?: return null
        fun ids(x: String) = x.split('.').filter { it.isNotEmpty() }.map { it.toInt() }
        return try {
            AcData(ids(m.groupValues[1]), ids(m.groupValues[2]))
        } catch (e: NumberFormatException) {
            null
        }
    }

    /** What the TCF layers show of a stored model (the visitor's previous TCF choice; [ac] its Additional Consent). */
    fun choice(t: TcfSettings, m: TcModel, ac: AcData? = null): TcfChoice {
        val vendors = HashMap<Int, Boolean>()
        val vendorsLi = HashMap<Int, Boolean>()
        for (id in t.vendors) {
            vendors[id] = id in m.vendorConsents
            vendorsLi[id] = id in m.vendorLegitimateInterests
        }
        val purposesLi = HashMap<Int, Boolean>()
        val purposes = HashMap<Int, Boolean>()
        for (p in 1..PURPOSES) {
            if (t.basis(p) == "legitimate_interest") purposesLi[p] = p in m.purposeLegitimateInterests
            if (t.basis(p) == "consent") purposes[p] = p in m.purposeConsents
        }
        val sf = t.specialFeatures.associateWith { it in m.specialFeatureOptins }
        val acs = if (ac == null) emptyMap() else t.acProviders.associateWith { it in ac.consented }
        return TcfChoice(vendors, vendorsLi, purposesLi, sf, purposes, acs)
    }

    /**
     * docs/CMP.md §4.4 rule 5: no or an unreadable string, another CMP id or policy, a selected vendor of the vendor
     * list (when it could be read) that the string did not disclose, or one of Google's providers of the list that the
     * stored Additional Consent string does not name.
     */
    fun mustAsk(t: TcfSettings, stored: String?, list: VendorList?, storedAc: String? = null): Boolean {
        val m = stored?.let { TcString.decode(it) } ?: return true
        if (m.cmpId != t.cmpId || m.policyVersion != t.policyVersion) return true
        val disclosed = m.vendorsDisclosed ?: emptyList()
        val a = storedAc?.let { parseAc(it) }
        val named = (a?.consented ?: emptyList()) + (a?.disclosed ?: emptyList())
        return t.vendors.any { it !in disclosed && list?.live(it) != null } ||
            t.acProviders.any { it !in named && list?.acProviders?.get(it) != null }
    }

    /**
     * The in-app keys of a decision (IAB CMP API v2.2, « In-App Details »; [ac]: Google's Additional Consent string,
     * « In-app » of its specification): `Int` or `String` values.
     */
    fun keys(m: TcModel, tc: String, ac: String? = null): Map<String, Any> {
        fun bits(ids: List<Int>, n: Int? = null): String {
            val len = n ?: (ids.maxOrNull() ?: 0)
            val b = StringBuilder(len)
            for (i in 1..len) b.append(if (i in ids) '1' else '0')
            return b.toString()
        }
        val k = linkedMapOf<String, Any>(
            "IABTCF_CmpSdkID" to m.cmpId, "IABTCF_CmpSdkVersion" to m.cmpVersion, "IABTCF_PolicyVersion" to m.policyVersion,
            "IABTCF_gdprApplies" to 1, "IABTCF_PublisherCC" to m.publisherCC,
            "IABTCF_PurposeOneTreatment" to (if (m.purposeOneTreatment) 1 else 0),
            "IABTCF_UseNonStandardTexts" to (if (m.useNonStandardTexts) 1 else 0),
            "IABTCF_TCString" to tc, "IABTCF_VendorConsents" to bits(m.vendorConsents),
            "IABTCF_VendorLegitimateInterests" to bits(m.vendorLegitimateInterests),
            "IABTCF_DisclosedVendors" to bits(m.vendorsDisclosed ?: emptyList()),
            "IABTCF_PurposeConsents" to bits(m.purposeConsents, PURPOSES),
            "IABTCF_PurposeLegitimateInterests" to bits(m.purposeLegitimateInterests, PURPOSES),
            "IABTCF_SpecialFeaturesOptIns" to bits(m.specialFeatureOptins, SPECIAL_FEATURES),
            "IABTCF_PublisherConsent" to bits(m.publisherConsents ?: emptyList(), PURPOSES),
            "IABTCF_PublisherLegitimateInterests" to bits(m.publisherLegitimateInterests, PURPOSES),
            "IABTCF_PublisherCustomPurposesConsents" to "", "IABTCF_PublisherCustomPurposesLegitimateInterests" to "",
        )
        for (p in 1..PURPOSES) {
            val types = HashMap<Int, Int>()
            for (r in m.restrictions) if (r.purpose == p) for (v in r.vendors) types[v] = r.type
            val max = types.keys.maxOrNull() ?: continue
            val s = StringBuilder(max)
            for (i in 1..max) s.append(types[i]?.toString() ?: "_")
            k["IABTCF_PublisherRestrictions$p"] = s.toString()
        }
        if (ac != null) k["IABTCF_AddtlConsent"] = ac
        return k
    }

    /** The keys of a decision (removed when it no longer holds). */
    val decisionKeys: List<String> = listOf(
        "IABTCF_TCString", "IABTCF_VendorConsents", "IABTCF_VendorLegitimateInterests", "IABTCF_DisclosedVendors",
        "IABTCF_PurposeConsents", "IABTCF_PurposeLegitimateInterests", "IABTCF_SpecialFeaturesOptIns", "IABTCF_PublisherConsent",
        "IABTCF_PublisherLegitimateInterests", "IABTCF_PublisherCustomPurposesConsents",
        "IABTCF_PublisherCustomPurposesLegitimateInterests", "IABTCF_AddtlConsent",
    ) + (1..PURPOSES).map { "IABTCF_PublisherRestrictions$it" }

    /** Every key this module writes (removed by `debugReset()` and when the site turns the TCF off). */
    val allKeys: List<String> = listOf(
        "IABTCF_CmpSdkID", "IABTCF_CmpSdkVersion", "IABTCF_PolicyVersion", "IABTCF_gdprApplies", "IABTCF_PublisherCC",
        "IABTCF_PurposeOneTreatment", "IABTCF_UseNonStandardTexts",
    ) + decisionKeys
}

/**
 * The TC string v2 (IAB « Consent string and vendor list formats »): core segment, disclosed vendors (type 1) and
 * publisher TC (type 3), base64url without padding, each segment's bits padded to a multiple of 24.
 */
internal object TcString {
    private const val DICT = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    /** Deciseconds of [now]'s UTC day at 00:00 (TCF v2.2: created and updated at the day). */
    fun day(now: Long): Long = (now / 86_400_000L) * 864_000L

    private class Bits {
        val b = java.util.BitSet()
        var n = 0
        fun int(v: Long, bits: Int) {
            for (i in bits - 1 downTo 0) bool((v shr i) and 1L == 1L)
        }
        fun int(v: Int, bits: Int) = int(v.toLong(), bits)
        fun bool(v: Boolean) {
            if (v) b.set(n)
            n++
        }
        fun field(ids: List<Int>, len: Int) {
            for (i in 1..len) bool(i in ids)
        }
        fun letters(s: String) {
            for (ch in s.uppercase().take(2)) int(maxOf(0, ch.code - 65), 6)
        }
        fun ranges(ids: List<Int>) {
            val r = runs(ids)
            int(r.size, 12)
            for ((a, z) in r) {
                bool(a != z)
                int(a, 16)
                if (a != z) int(z, 16)
            }
        }
        /** MaxVendorId, then a bit field or ranges, whichever is shorter (the IAB reference library's rule). */
        fun vendors(set: List<Int>) {
            val ids = set.filter { it > 0 }.toSortedSet().toList()
            val max = ids.lastOrNull() ?: 0
            var rangeLength = 12
            for ((a, z) in runs(ids)) rangeLength += if (a == z) 17 else 33
            int(max, 16)
            if (max > 45 && rangeLength < max) {
                bool(true)
                ranges(ids)
            } else {
                bool(false)
                field(ids, max)
            }
        }
        fun base64(): String {
            val total = if (n % 24 == 0) n else n + 24 - n % 24
            val out = StringBuilder(total / 6)
            var i = 0
            while (i < total) {
                var v = 0
                for (k in 0 until 6) v = (v shl 1) or (if (b.get(i + k)) 1 else 0)
                out.append(DICT[v])
                i += 6
            }
            return out.toString()
        }
    }

    private fun runs(ids: List<Int>): List<Pair<Int, Int>> {
        val out = ArrayList<Pair<Int, Int>>()
        for (id in ids) {
            val last = out.lastOrNull()
            if (last != null && last.second == id - 1) out[out.size - 1] = last.first to id else out.add(id to id)
        }
        return out
    }

    fun encode(m: TcModel): String {
        val c = Bits()
        c.int(2, 6)
        c.int(m.created, 36)
        c.int(m.updated, 36)
        c.int(m.cmpId, 12)
        c.int(m.cmpVersion, 12)
        c.int(m.consentScreen, 6)
        c.letters(m.consentLanguage)
        c.int(m.vendorListVersion, 12)
        c.int(m.policyVersion, 6)
        c.bool(m.isServiceSpecific)
        c.bool(m.useNonStandardTexts)
        c.field(m.specialFeatureOptins, 12)
        c.field(m.purposeConsents, 24)
        c.field(m.purposeLegitimateInterests, 24)
        c.bool(m.purposeOneTreatment)
        c.letters(m.publisherCC)
        c.vendors(m.vendorConsents)
        c.vendors(m.vendorLegitimateInterests)
        c.int(m.restrictions.size, 12)
        for (r in m.restrictions) {
            c.int(r.purpose, 6)
            c.int(r.type, 2)
            c.ranges(r.vendors.filter { it > 0 }.toSortedSet().toList())
        }
        val parts = arrayListOf(c.base64())
        m.vendorsDisclosed?.let { d ->
            val s = Bits()
            s.int(1, 3)
            s.vendors(d)
            parts.add(s.base64())
        }
        m.publisherConsents?.let { pc ->
            val s = Bits()
            s.int(3, 3)
            s.field(pc, 24)
            s.field(m.publisherLegitimateInterests, 24)
            s.int(0, 6)
            parts.add(s.base64())
        }
        return parts.joinToString(".")
    }

    private class Reader(val b: BooleanArray) {
        var i = 0
        fun int(n: Int): Long {
            if (i + n > b.size) throw IllegalArgumentException("truncated")
            var v = 0L
            for (k in 0 until n) v = (v shl 1) or (if (b[i + k]) 1L else 0L)
            i += n
            return v
        }
        fun small(n: Int) = int(n).toInt()
        fun field(n: Int): List<Int> {
            if (i + n > b.size) throw IllegalArgumentException("truncated")
            val out = ArrayList<Int>()
            for (k in 0 until n) if (b[i + k]) out.add(k + 1)
            i += n
            return out
        }
        fun letters(): String = "${(65 + small(6)).toChar()}${(65 + small(6)).toChar()}"
        fun ranges(): List<Int> {
            val n = small(12)
            val out = ArrayList<Int>()
            repeat(n) {
                val isRange = small(1) == 1
                val a = small(16)
                val z = if (isRange) small(16) else a
                if (z < a) throw IllegalArgumentException("range")
                for (id in a..z) out.add(id)
            }
            return out
        }
        fun vendors(): List<Int> {
            val max = small(16)
            return if (small(1) == 1) ranges() else field(max)
        }
    }

    private fun bits(segment: String): BooleanArray {
        val out = BooleanArray(segment.length * 6)
        for ((j, ch) in segment.withIndex()) {
            val v = DICT.indexOf(ch)
            if (v < 0) throw IllegalArgumentException("not base64url")
            for (k in 0 until 6) out[j * 6 + k] = (v shr (5 - k)) and 1 == 1
        }
        return out
    }

    /** A v2 TC string's fields, or null. */
    fun decode(tc: String): TcModel? = try {
        val segments = tc.split('.')
        val r = Reader(bits(segments[0]))
        if (r.small(6) != 2) throw IllegalArgumentException("version")
        val m = TcModel()
        m.created = r.int(36)
        m.updated = r.int(36)
        m.cmpId = r.small(12)
        m.cmpVersion = r.small(12)
        m.consentScreen = r.small(6)
        m.consentLanguage = r.letters()
        m.vendorListVersion = r.small(12)
        m.policyVersion = r.small(6)
        m.isServiceSpecific = r.small(1) == 1
        m.useNonStandardTexts = r.small(1) == 1
        m.specialFeatureOptins = r.field(12)
        m.purposeConsents = r.field(24)
        m.purposeLegitimateInterests = r.field(24)
        m.purposeOneTreatment = r.small(1) == 1
        m.publisherCC = r.letters()
        m.vendorConsents = r.vendors()
        m.vendorLegitimateInterests = r.vendors()
        repeat(r.small(12)) { m.restrictions.add(TcRestriction(r.small(6), r.small(2), r.ranges().toMutableList())) }
        for (seg in segments.drop(1)) {
            val s = Reader(bits(seg))
            when (s.small(3)) {
                1 -> m.vendorsDisclosed = s.vendors()
                3 -> {
                    m.publisherConsents = s.field(24)
                    m.publisherLegitimateInterests = s.field(24)
                }
            }
        }
        m
    } catch (e: RuntimeException) {
        null
    }
}
