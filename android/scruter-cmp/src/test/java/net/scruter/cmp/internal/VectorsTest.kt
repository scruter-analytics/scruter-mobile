package net.scruter.cmp.internal

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/** The conformance vectors of the protocol kit (`sdk/protocol/cmp/vectors`), shared with the site script and iOS. */
@RunWith(RobolectricTestRunner::class)
class VectorsTest {
    private fun vectors(name: String) = JSONObject(Protocol.file("cmp/vectors/$name").readText())

    private fun stored(o: JSONObject?): Stored? {
        if (o == null) return null
        val p = o.optJSONObject("pending")
        return Stored(
            o.getString("id"),
            o.getLong("at"),
            o.getLong("rev"),
            o.getLong("banner"),
            o.getJSONArray("granted").let { a -> (0 until a.length()).map { a.getString(it) } },
            p?.let { Stored.Pending(it.getString("action"), it.getString("source")) },
        )
    }

    @Test
    fun storedValues() {
        val v = vectors("stored-value.json")
        val valid = v.getJSONArray("valid")
        for (i in 0 until valid.length()) {
            val c = valid.getJSONObject(i)
            val expected = stored(c.getJSONObject("stored"))
            assertEquals(c.getString("note"), expected, Stored.parse(c.getString("value")))
            assertEquals(c.getString("note"), c.getString("value"), expected!!.serialize())
        }
        val invalid = v.getJSONArray("invalid")
        for (i in 0 until invalid.length()) {
            val c = invalid.getJSONObject(i)
            assertNull(c.getString("note"), Stored.parse(c.getString("value")))
        }
    }

    @Test
    fun reask() {
        val v = vectors("reask.json")
        val now = v.getLong("now")
        val cases = v.getJSONArray("cases")
        assertTrue(cases.length() >= 10)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val conf = c.getJSONObject("config")
            val purposes = conf.getJSONArray("purposes").let { a ->
                (0 until a.length()).map { a.getJSONObject(it) }.map { Rules.Purpose(it.getString("key"), it.getBoolean("required"), it.getLong("rev")) }
            }
            val rules = Rules(conf.getInt("renew_months"), conf.getLong("banner"), if (conf.isNull("ab_test_b")) null else conf.getLong("ab_test_b"), purposes)
            val s = if (c.isNull("stored")) null else stored(c.getJSONObject("stored"))
            assertEquals(c.getString("name"), c.getBoolean("ask"), rules.mustAsk(s, now))
            // The short line kept beside the choice gives the same answers.
            assertEquals(c.getString("name"), c.getBoolean("ask"), Rules.decode(rules.encode())!!.mustAsk(s, now))
        }
    }

    @Test
    fun consentMode() {
        val v = vectors("consent-mode.json")
        val map = v.getJSONObject("map").let { m -> m.keys().asSequence().associateWith { m.getString(it) } }
        val order = v.getJSONArray("order").let { a -> (0 until a.length()).map { a.getString(it) } }
        assertEquals(order, ConsentMode.SIGNALS)
        val cases = v.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val choice = if (c.isNull("choice")) null else c.getJSONObject("choice").let { o -> o.keys().asSequence().associateWith { o.getBoolean(it) } }
            val expected = c.getJSONObject("signals")
            val got = ConsentMode.signals(map, choice)
            for (k in order) assertEquals("${c.getString("name")} $k", expected.getString(k) == "granted", got[k])
            assertEquals(c.getString("name"), c.getJSONArray("granted").strings(), ConsentMode.granted(map, choice ?: emptyMap()))
        }
    }

    @Test
    fun goldenConfiguration() {
        val c = AppConfig.parse(Protocol.file("cmp/bodies/config.json").readText())!!
        assertTrue(c.on)
        assertEquals(3600L, c.ttl)
        val cmp = c.cmp!!
        assertEquals("ATMONA02", cmp.site)
        assertEquals(412L, cmp.banner)
        assertEquals(listOf("analytics", "advertising"), cmp.optional)
        assertEquals("analytics", cmp.gcm!!["analytics_storage"])
        assertEquals("fr", cmp.ui.defaultLanguage)
        assertEquals("Vos données, vos choix", cmp.ui.texts["fr"]!!.title)
        assertEquals(listOf("Firebase Analytics"), cmp.ui.providers["analytics"])
        assertEquals("https://atelier-mona.fr/confidentialite", c.policyUrl)
        assertEquals(1, c.sdkCatalogue)
        assertTrue(cmp.ui.closeLink)
        assertEquals("curve", cmp.ui.hero!!.edge)
        val off = AppConfig.parse(Protocol.file("cmp/bodies/config-off.json").readText())!!
        assertTrue(!off.on)
        assertEquals(300L, off.ttl)
        assertNull(off.cmp)
    }

    @Test
    fun languages() {
        val enabled = listOf("fr", "en", "de", "nb", "pt", "zh")
        val aliases = mapOf("no" to "nb", "nn" to "nb")
        assertEquals("de", Lang.pick(enabled, "fr", listOf(null, "de-CH", "fr-FR"), aliases))
        assertEquals("nb", Lang.pick(enabled, "fr", listOf("nn-NO"), aliases))
        assertEquals("pt", Lang.pick(enabled, "fr", listOf("pt-BR"), aliases))
        assertEquals("zh", Lang.pick(enabled, "fr", listOf("zh-Hant-TW"), aliases))
        assertEquals("fr", Lang.pick(enabled, "fr", listOf("ja-JP"), aliases))
        assertEquals("en", Lang.pick(enabled, "fr", listOf("en", "de"), aliases))
    }

    @Test
    fun colours() {
        // The dark theme's brand colour reaches 3:1 on the dark surface, with its label at 4.5:1 (docs/CMP.md §4.5).
        for (c in listOf("#17131F", "#1F4E8C", "#1F6F5C", "#B4441E", "#6B4EFF", "#000080", "#FFC233", "#2BC48A")) {
            val d = Colors.darkBrand(c)
            assertTrue("$c → $d", Colors.contrast(d, Colors.DARK_BG) >= 3)
            assertTrue("$c → $d", Colors.contrast(d, Colors.onColor(d)) >= 4.5)
        }
        // The site script's own results (cmp/src/shared/color.ts darkBrand), colour for colour.
        val web = mapOf(
            "#17131F" to "#FFFFFF", "#1F4E8C" to "#2968BA", "#1F6F5C" to "#217763", "#B4441E" to "#B4441E",
            "#6B4EFF" to "#6B4EFF", "#000080" to "#4D4DFF", "#FFC233" to "#FFC233", "#3A0CA3" to "#743EF1",
        )
        for ((c, d) in web) assertEquals(c, d, Colors.darkBrand(c))
        assertEquals(Colors.WHITE, Colors.onColor("#1F6F5C"))
        assertEquals(Colors.INK, Colors.onColor("#FFC233"))
        assertEquals("#FFFFFF", Colors.mix("#FFFFFF", "#FFFFFF", 0.14))
    }

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
}

/** The protocol kit, from the build (`scruter.protocolDir`). */
internal object Protocol {
    val dir: File = File(System.getProperty("scruter.protocolDir") ?: "../../protocol")

    fun file(path: String) = File(dir, path)
}
