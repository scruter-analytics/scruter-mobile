package net.scruter.cmp.internal

import android.content.Context
import org.json.JSONObject

/** The banner's language (docs/CMP.md §4.5, docs/CMP-MOBILE.md §2.2) and the sheet's own words. */
internal object Lang {
    /**
     * The first of [preferred] (an explicit language, then the device's `LocaleList`) the banner speaks: the exact tag,
     * an alias (`no` → `nb`), the primary subtag (`pt-BR` → `pt`, `zh-Hant-TW` → `zh`), its alias; else [fallback].
     * Mirrors `pickLanguage` of the site script and `scruter_cmp::languages::negotiate`.
     */
    fun pick(enabled: List<String>, fallback: String, preferred: List<String?>, aliases: Map<String, String>): String {
        for (raw in preferred) {
            if (raw.isNullOrEmpty()) continue
            val l = raw.lowercase().replace('_', '-')
            val p = l.substringBefore('-')
            for (c in arrayOf(l, aliases[l], p, aliases[p])) if (c != null && c in enabled) return c
        }
        return fallback
    }

    /**
     * French typography, for display only (docs/CMP.md §4.5, `cmp/src/ui/labels.ts`): a narrow no-break space after «
     * and before », ; : ! ?, not inside URLs or times. The stored texts, their hashes and the proofs are untouched.
     */
    fun frenchSpacing(s: String): String = s
        .replace(Regex("«[ \u00a0\u202f]?"), "«\u202f")
        .replace(Regex("[ \u00a0\u202f]?»"), "\u202f»")
        .replace(Regex("[ \u00a0]([;:!?]+)(?=[\\s\u00a0\u202f]|\u202f»|$)"), "\u202f\$1")
        .replace(Regex("([^\\s\u00a0\u202f;:!?«])([;:!?]+)(?=[\\s\u00a0\u202f]|\u202f»|$)"), "\$1\u202f\$2")

    /** Android's old codes for Hebrew, Indonesian and Yiddish, as `Locale.toLanguageTag` already fixes them. */
    fun tag(locale: java.util.Locale): String = locale.toLanguageTag()
}

/** The sheet's words in one language (`sdk/protocol/cmp/words/<lang>.json`, embedded as assets). */
internal class Words(private val w: Map<String, String>) {
    fun mapped(f: (String) -> String): Words = Words(w.mapValues { f(it.value) })

    operator fun get(key: String): String = w[key] ?: key

    fun stepOf(n: Int, t: Int): String = get("stepOf").replace("{n}", n.toString()).replace("{t}", t.toString())

    companion object {
        private val cache = HashMap<String, Words>()

        /** The words of [lang], else English (the site script's rule); read once from the assets, off the main thread. */
        fun load(context: Context, lang: String): Words = synchronized(cache) {
            cache[lang]?.let { return it }
            val w = read(context, lang) ?: read(context, "en") ?: Words(emptyMap())
            cache[lang] = w
            w
        }

        private fun read(context: Context, lang: String): Words? = try {
            val text = context.assets.open("net.scruter.cmp/words/$lang.json").use { it.readBytes().toString(Charsets.UTF_8) }
            val o = JSONObject(text)
            val m = HashMap<String, String>()
            for (k in o.keys()) m[k] = o.getString(k)
            Words(m)
        } catch (e: Exception) {
            null
        }
    }
}
