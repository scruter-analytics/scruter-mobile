package net.scruter.cmp.internal

import java.security.SecureRandom

/**
 * The stored choice, format 1 (docs/CMP.md §4.3, docs/CMP-MOBILE.md M5): the value of the web's cookie
 * `scruter_consent`, kept under the key `choice` of the app's `SharedPreferences` file `net.scruter.cmp`.
 *
 *   1.<consent_id>.<decided_at base36 s>.<consent_rev>.<banner_version_id>.<granted keys joined by "+">.<flags>
 *
 * Flags: empty, or `p<a><o>` while the proof is not acknowledged. Pure functions, checked against
 * `sdk/protocol/cmp/vectors/stored-value.json`.
 */
internal data class Stored(
    /** `cns_` + 20 lowercase hex. */
    val id: String,
    /** Decision time, Unix seconds. */
    val at: Long,
    /** `consent_rev` of the configuration answered. */
    val rev: Long,
    /** Banner version id answered. */
    val banner: Long,
    val granted: List<String>,
    /** The proof not acknowledged yet: its action and source. */
    val pending: Pending?,
) {
    data class Pending(val action: String, val source: String)

    fun serialize(): String {
        val flags = pending?.let { "p" + ACTION_LETTERS[ACTIONS.indexOf(it.action)] + SOURCE_LETTERS[SOURCES.indexOf(it.source)] } ?: ""
        return listOf("1", id, java.lang.Long.toString(at, 36), rev.toString(), banner.toString(), granted.joinToString("+"), flags)
            .joinToString(".")
    }

    companion object {
        val ACTIONS = listOf("accept_all", "reject_all", "custom", "close", "withdraw")
        const val ACTION_LETTERS = "arcxw"
        val SOURCES = listOf("banner", "preferences", "floating_button", "api")
        const val SOURCE_LETTERS = "bpfi"

        private val ID = Regex("^cns_[0-9a-f]{20}$")
        private val KEY = Regex("^[a-z][a-z0-9_]{1,39}$")
        private val INT = Regex("^[0-9]{1,10}$")
        private val B36 = Regex("^[0-9a-z]{1,8}$")

        fun parse(value: String?): Stored? {
            if (value == null) return null
            val f = value.split('.')
            if (f.size != 7 || f[0] != "1" || !ID.matches(f[1]) || !B36.matches(f[2]) || !INT.matches(f[3]) || !INT.matches(f[4])) {
                return null
            }
            val granted = if (f[5].isEmpty()) emptyList() else f[5].split('+')
            if (!granted.all { KEY.matches(it) }) return null
            var pending: Pending? = null
            val flags = f[6]
            if (flags.isNotEmpty()) {
                // As the web core reads it: the first three letters.
                if (flags.length < 3 || flags[0] != 'p') return null
                val a = ACTION_LETTERS.indexOf(flags[1])
                val o = SOURCE_LETTERS.indexOf(flags[2])
                if (a < 0 || o < 0) return null
                pending = Pending(ACTIONS[a], SOURCES[o])
            }
            return Stored(f[1], java.lang.Long.parseLong(f[2], 36), f[3].toLong(), f[4].toLong(), granted, pending)
        }

        private val random by lazy { SecureRandom() }

        /** `cns_` + 20 lowercase hex digits: 80 random bits, the visitor's receipt (docs/CMP.md §6.1). */
        fun newConsentId(): String {
            val b = ByteArray(10)
            random.nextBytes(b)
            val sb = StringBuilder("cns_")
            for (x in b) {
                val v = x.toInt() and 0xFF
                sb.append(HEX[v shr 4]).append(HEX[v and 15])
            }
            return sb.toString()
        }

        private const val HEX = "0123456789abcdef"
    }
}

/**
 * What the re-ask rules read of a configuration (docs/CMP.md §4.4 rules 1–4): kept beside the stored choice as a short
 * line, so that `start` decides on the main thread without parsing the cached configuration's JSON.
 *
 *   <renew months>;<banner id>;<variant B's banner id or empty>;<key>:<r|o>:<rev>,…
 */
internal data class Rules(val renewMonths: Int, val banner: Long, val bannerB: Long?, val purposes: List<Purpose>) {
    data class Purpose(val key: String, val required: Boolean, val rev: Long)

    fun encode(): String =
        "$renewMonths;$banner;${bannerB ?: ""};" + purposes.joinToString(",") { "${it.key}:${if (it.required) "r" else "o"}:${it.rev}" }

    /** True when the first layer must show (rules 1–4, the TCF's rule 5 comes with its layers). */
    fun mustAsk(s: Stored?, nowSeconds: Long): Boolean {
        if (s == null) return true
        if (nowSeconds - s.at > renewSeconds(renewMonths)) return true
        val current = s.banner == banner || (bannerB != null && s.banner == bannerB)
        for (p in purposes) {
            if (p.required || p.rev <= s.rev) continue
            if (p.key in s.granted || !current) return true
        }
        return false
    }

    /**
     * During a re-ask (docs/CMP-MOBILE.md §3.8), the purposes that did not change keep the answer given until the new
     * decision: granted when the stored choice granted it and its revision is not newer than the choice's.
     */
    fun keptGrants(s: Stored): Set<String> =
        purposes.filter { !it.required && it.key in s.granted && it.rev <= s.rev }.map { it.key }.toSet()

    companion object {
        /** Re-consent period in seconds: months × 30.44 days, rounded. */
        fun renewSeconds(months: Int): Long = Math.round(months * 30.44 * 86400)

        fun decode(line: String?): Rules? {
            if (line.isNullOrEmpty()) return null
            return try {
                val f = line.split(';')
                if (f.size != 4) return null
                val purposes = if (f[3].isEmpty()) emptyList() else f[3].split(',').map {
                    val p = it.split(':')
                    Purpose(p[0], p[1] == "r", p[2].toLong())
                }
                Rules(f[0].toInt(), f[1].toLong(), f[2].ifEmpty { null }?.toLong(), purposes)
            } catch (e: RuntimeException) {
                null
            }
        }
    }
}
