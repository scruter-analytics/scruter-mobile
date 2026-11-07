package net.scruter.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.math.BigInteger
import java.util.TimeZone

/** The contract's small rules (docs/MOBILE.md §2.1, §3.3, §3.5, §3.15, §3.16). */
@RunWith(RobolectricTestRunner::class)
class RulesTest {
    class ProductFragment
    class CheckoutActivity
    class HomeScreen
    class Ab

    @Test
    fun stableIdentifiers() {
        assertTrue(Text.isStableId("add_to_cart"))
        assertTrue(Text.isStableId("addToCart"))
        assertTrue(Text.isStableId("cart.total:v2-a"))
        assertFalse(Text.isStableId("1abc"))
        assertFalse(Text.isStableId("item_12345"))
        assertFalse(Text.isStableId("user@example"))
        assertFalse(Text.isStableId("view_1f2e3d4c"))
        assertFalse(Text.isStableId("1F2E3D4C-5B6A-4978-8695-A4B3C2D1E0F9"))
        assertFalse(Text.isStableId("a".repeat(61)))
        assertFalse(Text.isStableId(null))
    }

    @Test
    fun screenNames() {
        assertEquals("Product", Text.screenNameOf(ProductFragment::class.java))
        assertEquals("Checkout", Text.screenNameOf(CheckoutActivity::class.java))
        assertEquals("Home", Text.screenNameOf(HomeScreen::class.java))
        assertNull("an obfuscated name gives none", Text.screenNameOf(Ab::class.java))
    }

    @Test
    fun cleaning() {
        assertEquals("Cart", Text.clean("  Ca\u0000rt\n ", 120))
        assertNull(Text.clean(" \t ", 120))
        assertEquals(120, Text.clean("é".repeat(200), 120)!!.codePointCount(0, 120))
        assertEquals("😀😀", Text.clean("😀😀😀", 2))
    }

    @Test
    fun wildcards() {
        assertTrue(Text.matches("DebugMenu", "Debug*"))
        assertTrue(Text.matches("Settings/Debug", "*Debug"))
        assertTrue(Text.matches("a-b-c", "a*b*c"))
        assertFalse(Text.matches("Cart", "Debug*"))
        assertTrue(Text.matches("Cart", "Cart"))
        assertFalse(Text.matches("ab", "a*b*b"))
    }

    @Test
    fun midnightInTheAppsTimeZone() {
        val paris = TimeZone.getTimeZone("Europe/Paris")
        // 2026-11-05 23:30 in Paris = 22:30 UTC.
        val t = 1_793_917_800_000L
        assertEquals("2026-11-05", Days.date(t, paris))
        assertEquals("2026-11-06", Days.date(Days.nextMidnight(t, paris), paris))
        assertEquals(30 * 60 * 1000L, Days.nextMidnight(t, paris) - t)
        val la = TimeZone.getTimeZone("America/Los_Angeles")
        assertEquals("2026-11-05", Days.date(t, la))
        assertEquals(TimeZone.getDefault().id, Days.zone("Not/AZone").id)
        assertEquals("Europe/Paris", Days.zone("Europe/Paris").id)
    }

    @Test
    fun sampleRuleIsTheServers() {
        val c = Config(aa = 37)
        for (i in 0 until 2000) {
            val id = Text.randomHex(8)
            val expected = BigInteger(id, 16).mod(BigInteger.valueOf(100)).toInt() < 37
            assertEquals(id, expected, c.samples(id))
        }
        assertFalse(Config(aa = 0).samples("ffffffffffffffff"))
        assertTrue(Config(aa = 100).samples("ffffffffffffffff"))
    }

    @Test
    fun backoff() {
        for (n in 0..20) {
            val d = Engine.delayFor(n, -1)
            val base = minOf(5_000L shl minOf(n, 7), 600_000L)
            assertTrue("attempt $n: $d", d >= base * 0.8 - 1 && d <= minOf(base * 1.2, 600_000.0) + 1)
        }
        assertEquals(120_000L, Engine.delayFor(0, 120_000))
    }

    @Test
    fun configuration() {
        val c = Config.parse("""{"v":1,"on":1,"e":"5d41402a","tz":"Europe/Paris","aa":100,"cr":0,"xs":["Debug*"],"tp":1,"ttl":30}""")!!
        assertTrue(c.on)
        assertEquals("5d41402a", c.etag)
        assertEquals(100, c.aa)
        assertFalse(c.crashes)
        assertTrue(c.teamImages)
        assertEquals(60, c.ttl)
        assertTrue(c.ignores("DebugMenu"))
        assertFalse(Config.parse("""{"v":1,"on":0,"e":"0","ttl":300}""")!!.on)
        assertNull(Config.parse("""{"v":2}"""))
        assertNull(Config.parse("nope"))
    }

    @Test
    fun models() {
        assertEquals("Google Pixel 8", Env.model("Google", "Pixel 8"))
        assertEquals("Samsung SM-S911B", Env.model("samsung", "SM-S911B"))
        assertEquals("OnePlus CPH2449", Env.model("OnePlus", "OnePlus CPH2449"))
        assertEquals(60, Env.model("X", "y".repeat(100)).length)
    }

    @Test
    fun navigationNames() {
        assertEquals("product/{id}", Navigation.name("product/{id}", "Product page"))
        assertEquals("Product/{id}", Navigation.name("com.example.shop.Product/{id}", null))
        assertEquals("search", Navigation.name("search?query={query}", null))
        assertEquals("Cart", Navigation.name(null, "Cart"))
        assertNull(Navigation.name(null, null))
    }

    @Test
    fun links() {
        val u = android.net.Uri.parse("https://atelier-mona.fr/shop?token=secret&utm_source=newsletter&utm_campaign=christmas&gclid=x")
        assertEquals("https://atelier-mona.fr/shop?utm_source=newsletter&utm_campaign=christmas", Openings.link(u))
        val o = Openings.of(android.content.Intent(android.content.Intent.ACTION_VIEW, u), null, false, "fr.app", "scruter-atmona02")
        assertEquals("link", o.getString("k"))
        val n = android.content.Intent(android.content.Intent.ACTION_MAIN).putExtra("google.message_id", "1")
        assertEquals("notification", Openings.of(n, null, false, "fr.app", "scruter-atmona02").getString("k"))
        val w = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("app://x?scruter_open=widget"))
        assertEquals("widget", Openings.of(w, null, false, "fr.app", "scruter-atmona02").getString("k"))
        val launcher = android.content.Intent(android.content.Intent.ACTION_MAIN)
        val r = Openings.of(launcher, android.net.Uri.parse("android-app://com.google.android.gm"), false, "fr.app", "x")
        assertEquals("icon", r.getString("k"))
        assertEquals("android-app://com.google.android.gm", r.getString("r"))
    }
}
