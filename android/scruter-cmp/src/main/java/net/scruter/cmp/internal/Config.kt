package net.scruter.cmp.internal

import org.json.JSONArray
import org.json.JSONObject

/**
 * The answer of `GET /m/v1/cmp` (docs/CMP-MOBILE.md §4.1, `sdk/protocol/schema/cmp-config.schema.json`): the site
 * script's `ScriptConfig` without what only a page uses, and the `app` block. Parsed on the worker thread only; the web-only
 * fields (`template`, `position`, `style`) are ignored.
 */
internal class AppConfig(
    /** `false`: unknown app, no published banner, CMP removed or suspended: show nothing, grant nothing. */
    val on: Boolean,
    /** Seconds before the SDK asks again. */
    val ttl: Long,
    val cmp: CmpConfig?,
    val policyUrl: String?,
    val icon: String?,
    val ids: List<String>,
    val sdkCatalogue: Int,
) {
    companion object {
        fun parse(text: String): AppConfig? = try {
            val o = JSONObject(text)
            if (o.optInt("v") != 1) {
                null
            } else {
                val on = o.optInt("on") == 1
                val ttl = o.optLong("ttl", if (on) 3600 else 300).coerceIn(60, 86_400)
                if (!on) {
                    AppConfig(false, ttl, null, null, null, emptyList(), 0)
                } else {
                    val app = o.getJSONObject("app")
                    AppConfig(
                        true,
                        ttl,
                        CmpConfig.parse(o.getJSONObject("config")),
                        app.optStringOrNull("policy_url"),
                        app.optStringOrNull("icon"),
                        app.optJSONArray("ids").strings(),
                        app.optInt("sdk_catalogue"),
                    )
                }
            }
        } catch (e: Exception) {
            Log.w("configuration unreadable: ${e.javaClass.simpleName} ${e.message}")
            null
        }
    }
}

internal class CmpConfig(
    val site: String,
    val configRev: Long,
    val consentRev: Long,
    val endpoint: String,
    val banner: Long,
    val bannerVersion: Int,
    val abTest: AbTest?,
    val renewMonths: Int,
    val purposes: List<Rules.Purpose>,
    /** Google signal → purpose key (docs/CMP.md §4.8); null without Consent Mode. */
    val gcm: Map<String, String>?,
    /** The IAB TCF settings, as they come: their layers arrive with lot cmp-mobile-tcf; meanwhile the standard ones. */
    val tcf: JSONObject?,
    val ui: UiConfig,
) {
    class AbTest(val id: String, val splitB: Int, val banner: Long, val ui: UiConfig)

    val rules: Rules get() = Rules(renewMonths, banner, abTest?.banner, purposes)

    val optional: List<String> get() = purposes.filter { !it.required }.map { it.key }

    companion object {
        fun parse(c: JSONObject): CmpConfig {
            if (c.getInt("format") != 1) throw IllegalArgumentException("format")
            val purposes = ArrayList<Rules.Purpose>()
            val pa = c.getJSONArray("purposes")
            for (i in 0 until pa.length()) {
                val p = pa.getJSONObject(i)
                purposes.add(Rules.Purpose(p.getString("key"), p.optBoolean("required"), p.optLong("rev", 1)))
            }
            val gcm = c.optJSONObject("gcm")?.optJSONObject("map")?.let { m ->
                val out = LinkedHashMap<String, String>()
                for (k in m.keys()) m.optStringOrNull(k)?.let { out[k] = it }
                out
            }
            val ab = c.optJSONObject("ab_test")?.let {
                AbTest(it.getString("id"), it.getInt("split_b"), it.getJSONObject("b").getLong("id"), UiConfig.parse(it.getJSONObject("b_ui")))
            }
            val banner = c.getJSONObject("banner")
            return CmpConfig(
                c.getString("site"),
                c.optLong("config_rev"),
                c.optLong("consent_rev", 1),
                c.optString("endpoint"),
                banner.getLong("id"),
                banner.optInt("version"),
                ab,
                c.optJSONObject("cookie")?.optInt("renew_months", 6) ?: 6,
                purposes,
                gcm,
                c.optJSONObject("tcf"),
                UiConfig.parse(c.getJSONObject("ui")),
            )
        }
    }
}

internal class Texts(
    val title: String,
    val message: String,
    val acceptAll: String,
    val rejectAll: String,
    val customize: String,
    val save: String,
    val close: String,
    val preferencesTitle: String,
    val preferencesIntro: String,
    val kicker: String?,
    val heroAlt: String?,
    val policyUrl: String?,
    val purposes: Map<String, Pair<String, String>>,
) {
    fun name(key: String): String = purposes[key]?.first ?: key

    /** The same texts through [f] (display only: the link stays as it is). */
    fun mapped(f: (String) -> String): Texts = Texts(
        f(title), f(message), f(acceptAll), f(rejectAll), f(customize), f(save), f(close), f(preferencesTitle),
        f(preferencesIntro), kicker?.let(f), heroAlt?.let(f), policyUrl, purposes.mapValues { f(it.value.first) to f(it.value.second) },
    )

    fun description(key: String): String = purposes[key]?.second ?: ""

    companion object {
        fun parse(t: JSONObject): Texts {
            val purposes = LinkedHashMap<String, Pair<String, String>>()
            t.optJSONObject("purposes")?.let { p ->
                for (k in p.keys()) {
                    val o = p.optJSONObject(k) ?: continue
                    purposes[k] = o.optString("name", k) to o.optString("description")
                }
            }
            return Texts(
                t.getString("title"),
                t.optString("message"),
                t.getString("accept_all"),
                t.getString("reject_all"),
                t.getString("customize"),
                t.optString("save"),
                t.optString("close"),
                t.optString("preferences_title"),
                t.optString("preferences_intro"),
                t.optStringOrNull("kicker"),
                t.optStringOrNull("hero_alt"),
                t.optStringOrNull("policy_url"),
                purposes,
            )
        }
    }
}

/** The media header (`HeroUi`): every URL on cdn.scruter.net. */
internal class Hero(
    val video: Boolean,
    val w: Int,
    val h: Int,
    val poster: List<Source>,
    val videos: List<Source>,
    val focalX: Int,
    val focalY: Int,
    val hideOnPhone: Boolean,
    /** `curve`, `angle` or `straight`. */
    val edge: String,
) {
    class Source(val url: String, val type: String, val w: Int)

    companion object {
        fun parse(h: JSONObject): Hero {
            fun sources(a: JSONArray?): List<Source> {
                val out = ArrayList<Source>()
                if (a != null) for (i in 0 until a.length()) {
                    val s = a.optJSONObject(i) ?: continue
                    out.add(Source(s.getString("url"), s.optString("type"), s.optInt("w")))
                }
                return out
            }
            val focal = h.optJSONArray("focal")
            return Hero(
                h.optString("type") == "video",
                h.optInt("w"),
                h.optInt("h"),
                sources(h.optJSONArray("poster")),
                sources(h.optJSONArray("video")),
                focal?.optInt(0, 50) ?: 50,
                focal?.optInt(1, 50) ?: 50,
                h.optString("phone") == "hide",
                h.optString("edge", "curve"),
            )
        }
    }
}

internal class UiConfig(
    /** `three` or `two` (« Personnaliser | Tout accepter », with « Continuer sans accepter » in the band). */
    val twoButtons: Boolean,
    val closeLink: Boolean,
    /** Free plan: « Proposé par Scruter » without the band. */
    val branding: Boolean,
    val color: String,
    val onColor: String,
    /** `light`, `dark` or `auto`. */
    val theme: String,
    val radius: Int,
    val languages: List<String>,
    val defaultLanguage: String,
    val texts: Map<String, Texts>,
    val textHashes: Map<String, String>,
    val rtl: List<String>,
    val aliases: Map<String, String>,
    val providers: Map<String, List<String>>,
    val hero: Hero?,
    val noPanel: Boolean,
    /** `auto`, `custom` or `none`. */
    val logoMode: String,
    val logoUrl: String?,
    val delaySeconds: Int,
) {
    companion object {
        fun parse(u: JSONObject): UiConfig {
            val texts = LinkedHashMap<String, Texts>()
            u.getJSONObject("texts").let { t -> for (k in t.keys()) texts[k] = Texts.parse(t.getJSONObject(k)) }
            val hashes = HashMap<String, String>()
            u.optJSONObject("text_hashes")?.let { t -> for (k in t.keys()) hashes[k] = t.getString(k) }
            val aliases = HashMap<String, String>()
            u.optJSONObject("aliases")?.let { t -> for (k in t.keys()) aliases[k] = t.getString(k) }
            val providers = HashMap<String, List<String>>()
            u.optJSONObject("providers")?.let { t -> for (k in t.keys()) providers[k] = t.optJSONArray(k).strings() }
            val logoUrl = u.optStringOrNull("logo_url")
            val default = u.getString("default_language")
            if (texts[default] == null) throw IllegalArgumentException("no texts for the default language")
            return UiConfig(
                u.optString("buttons") == "two" && u.optBoolean("close_link"),
                u.optBoolean("close_link"),
                u.optBoolean("branding"),
                Colors.safe(u.optString("color")),
                u.optString("on_color", "#FFFFFF"),
                u.optString("theme", "light"),
                u.optInt("radius", 16).coerceIn(0, 32),
                u.optJSONArray("languages").strings().ifEmpty { listOf(default) },
                default,
                texts,
                hashes,
                u.optJSONArray("rtl").strings(),
                aliases,
                providers,
                u.optJSONObject("hero")?.let { Hero.parse(it) },
                u.optBoolean("no_panel"),
                u.optString("logo_mode", if (logoUrl != null) "custom" else "auto"),
                logoUrl,
                u.optInt("delay_s").coerceIn(0, 10),
            )
        }
    }
}

/** `GET /cmp/{code}/texts-{banner id}-{lang}.json`: one language of a version, frozen. */
internal class LanguagePack(val lang: String, val rtl: Boolean, val hash: String, val texts: Texts) {
    companion object {
        fun parse(text: String): LanguagePack? = try {
            val o = JSONObject(text)
            LanguagePack(o.getString("lang"), o.optString("dir") == "rtl", o.getString("hash"), Texts.parse(o.getJSONObject("texts")))
        } catch (e: Exception) {
            null
        }
    }
}

internal fun JSONObject.optStringOrNull(key: String): String? =
    if (isNull(key) || !has(key)) null else optString(key).takeIf { it.isNotEmpty() }

internal fun JSONArray?.strings(): List<String> {
    if (this == null) return emptyList()
    val out = ArrayList<String>(length())
    for (i in 0 until length()) optString(i).takeIf { it.isNotEmpty() }?.let { out.add(it) }
    return out
}
