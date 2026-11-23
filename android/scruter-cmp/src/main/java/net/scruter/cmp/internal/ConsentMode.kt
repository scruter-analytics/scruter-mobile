package net.scruter.cmp.internal

/**
 * Google Consent Mode v2 signals of a choice (docs/CMP.md §4.8, docs/CMP-MOBILE.md §3.7): granted when the mapped
 * purpose is granted, `security_storage` always granted. Checked against `sdk/protocol/cmp/vectors/consent-mode.json`.
 */
internal object ConsentMode {
    val SIGNALS = listOf(
        "ad_storage",
        "ad_user_data",
        "ad_personalization",
        "analytics_storage",
        "functionality_storage",
        "personalization_storage",
        "security_storage",
    )

    fun signals(map: Map<String, String>, choice: Map<String, Boolean>?): LinkedHashMap<String, Boolean> {
        val out = LinkedHashMap<String, Boolean>()
        for (s in SIGNALS) {
            val p = map[s]
            out[s] = s == "security_storage" || (choice != null && p != null && choice[p] == true)
        }
        return out
    }

    /** The signals sent as granted (the proof's `m`), in order. */
    fun granted(map: Map<String, String>, choice: Map<String, Boolean>): List<String> =
        signals(map, choice).filter { it.value }.keys.toList()
}
