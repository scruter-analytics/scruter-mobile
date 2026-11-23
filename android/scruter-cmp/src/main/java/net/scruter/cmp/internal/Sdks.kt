package net.scruter.cmp.internal

import org.json.JSONObject

/**
 * Detected SDKs (docs/CMP-MOBILE.md §3.14): which SDKs of the catalogue the app links, by the presence of their classes
 * only. `Class.forName(name, false, loader)` never initialises a class (no static block of the SDK runs), and nothing
 * else of the app is listed or read.
 */
internal object Sdks {
    private val CLASS = Regex("^[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)+$")
    private val KEY = Regex("^[a-z][a-z0-9_]{1,39}$")

    /** The catalogue's keys whose classes are present, sorted; null for a body that is not a catalogue. */
    fun detect(catalogue: String, loader: ClassLoader): List<String>? {
        val o = try {
            JSONObject(catalogue)
        } catch (e: Exception) {
            return null
        }
        val sdks = o.optJSONArray("sdks") ?: return null
        val found = sortedSetOf<String>()
        for (i in 0 until sdks.length()) {
            val s = sdks.optJSONObject(i) ?: continue
            val k = s.optString("k")
            if (!KEY.matches(k)) continue
            val names = s.optJSONArray("android") ?: continue
            for (j in 0 until names.length()) {
                val n = names.optString(j)
                if (CLASS.matches(n) && present(n, loader)) {
                    found.add(k)
                    break
                }
            }
        }
        return found.toList().take(200)
    }

    fun present(name: String, loader: ClassLoader): Boolean = try {
        Class.forName(name, false, loader)
        true
    } catch (e: ClassNotFoundException) {
        false
    } catch (e: LinkageError) {
        // Present, but with a missing dependency of its own: still linked into the app.
        true
    }
}
