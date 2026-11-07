package net.scruter.internal

import org.json.JSONObject

/**
 * The remote configuration (docs/MOBILE.md §3.16, docs/API.md §5.3), immutable; the defaults before the first answer:
 * collection on, Advanced analytics off, crash reports on, no team images.
 */
internal class Config(
    val on: Boolean = true,
    val etag: String = "",
    val tz: String? = null,
    val aa: Int = 0,
    val crashes: Boolean = true,
    val ignored: List<String> = emptyList(),
    val teamImages: Boolean = false,
    val ttl: Int = 3600,
    val json: String = "",
) {
    fun ignores(screen: String): Boolean = ignored.any { Text.matches(screen, it) }

    /** docs/MOBILE.md §3.16: a session collects taps, scroll, blocks and forms when `session_id mod 100 < aa`. */
    fun samples(sessionId: String): Boolean {
        if (aa <= 0) return false
        if (aa >= 100) return true
        var r = 0
        for (ch in sessionId) r = (r * 16 + Character.digit(ch, 16)) % 100
        return r < aa
    }

    companion object {
        val DEFAULT = Config()

        fun parse(text: String): Config? = try {
            val o = JSONObject(text)
            if (o.optInt("v") != 1) {
                null
            } else {
                val xs = ArrayList<String>()
                o.optJSONArray("xs")?.let { a -> for (i in 0 until a.length()) a.optString(i).takeIf { it.isNotEmpty() }?.let(xs::add) }
                Config(
                    on = o.optInt("on", 1) == 1,
                    etag = o.optString("e", ""),
                    tz = o.optString("tz", "").ifEmpty { null },
                    aa = o.optInt("aa", 0).coerceIn(0, 100),
                    crashes = o.optInt("cr", 1) == 1,
                    ignored = xs,
                    teamImages = o.optInt("tp", 0) == 1,
                    ttl = o.optInt("ttl", 3600).coerceIn(60, 86_400),
                    json = text,
                )
            }
        } catch (e: Exception) {
            null
        }
    }
}
