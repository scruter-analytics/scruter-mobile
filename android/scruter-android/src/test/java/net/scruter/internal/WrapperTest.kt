package net.scruter.internal

import android.app.Activity
import android.widget.FrameLayout
import net.scruter.Scruter
import net.scruter.bridge.ScruterBridge
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

/** A wrapper that measures its own screens (Flutter, docs/MOBILE.md §17): the SDK keeps sessions and transport only. */
@RunWith(RobolectricTestRunner::class)
class WrapperTest {
    class Host : Activity() {
        override fun onCreate(savedInstanceState: android.os.Bundle?) {
            super.onCreate(savedInstanceState)
            setContentView(FrameLayout(this))
        }
    }

    private class Seen(val session: String, val name: String, val analysed: Boolean, val capture: Boolean)

    private lateinit var server: FakeServer
    private val seen = CopyOnWriteArrayList<Seen>()

    @Before
    fun setUp() {
        server = FakeServer()
    }

    @After
    fun tearDown() {
        Sdk.stop()
        server.close()
    }

    private fun start(debugKey: String? = null): Engine {
        // The configuration first: the session of the test is in the sample.
        ScruterBridge.start(
            Sdk.app, "ATMONA02", "flutter/1.0.0", debugKey = debugKey, debug = true, endpoint = server.url,
            apiEndpoint = server.url,
            screens = { session, name, _, analysed, capture, _, _ -> seen.add(Seen(session, name, analysed, capture)) },
        )
        val e = Scruter.engine()!!
        Sdk.worker(e)
        return e
    }

    @Test
    fun theWrapperIsToldAndOwnsTheMeasures() {
        val e = start()
        server.next("/m/v1/config")
        val c = Robolectric.buildActivity(Host::class.java).setup()
        Sdk.idle(100)
        Sdk.worker(e)
        ScruterBridge.screen("/cart")
        Sdk.idle()
        Sdk.worker(e)
        assertEquals("/cart", seen.single().name)
        assertTrue(seen.single().analysed)
        assertFalse(seen.single().capture)
        // The window is not hooked: Flutter's surface is one view, its taps mean nothing here.
        assertFalse(c.get().window.callback is WindowCallback)
        val session = seen.single().session
        ScruterBridge.screenEnd(session, "/cart", 4200, 80)
        ScruterBridge.analysedScreen(session, """{"s":"$session","k":7,"q":1,"n":"/cart","t":${System.currentTimeMillis()},"sd":80}""")
        ScruterBridge.screen("/done")
        Sdk.idle()
        Sdk.worker(e)
        ScruterBridge.flush()
        Sdk.worker(e)
        val b = server.batchWith("x")
        assertEquals("flutter/1.0.0", b.getString("sdk"))
        val events = b.getJSONArray("e")
        val ends = (0 until events.length()).map { events.getJSONObject(it) }.filter { it.getString("k") == "screen_end" }
        // Only the wrapper's: the SDK's own engagement would say a depth of 100.
        assertEquals(1, ends.size)
        assertEquals(4200, ends[0].getInt("ms"))
        assertEquals(80, ends[0].getInt("sc"))
        assertEquals(1, b.getJSONArray("x").length())
        Conformance.batch("wrapper", b)
    }

    @Test
    fun aNewSessionAnnouncesTheScreenAgain() {
        val e = start()
        server.next("/m/v1/config")
        val c = Robolectric.buildActivity(Host::class.java).setup()
        Sdk.idle(100)
        ScruterBridge.screen("/home")
        Sdk.idle()
        Sdk.worker(e)
        val first = seen.single().session
        c.pause().stop()
        Sdk.idle()
        // Short returns: the same session, no new screen view.
        repeat(2) {
            c.restart().resume()
            Sdk.idle(200)
            Sdk.worker(e)
            assertEquals(1, seen.size)
            c.pause().stop()
            Sdk.idle()
        }
        Sdk.idle(31 * 60 * 1000)
        c.restart().resume()
        Sdk.idle(200)
        Sdk.worker(e)
        assertEquals(2, seen.size)
        assertEquals("/home", seen[1].name)
        assertTrue("a new session: ${seen.map { it.session }}, running ${e.clock.sessionId}", seen[1].session != first)
    }

    @Test
    fun aTeamPhoneIsAskedForItsImageOnce() {
        val key = "scr_dbg_" + "a".repeat(43)
        val e = start(key)
        val c = Robolectric.buildActivity(Host::class.java).setup()
        Sdk.idle(100)
        Sdk.worker(e)
        assertTrue(ScruterBridge.isTeamPhone())
        ScruterBridge.screen("/home")
        Sdk.idle()
        Sdk.worker(e)
        assertTrue(seen.single().capture)
        ScruterBridge.screen("/next")
        ScruterBridge.screen("/home")
        Sdk.idle()
        Sdk.worker(e)
        assertFalse(seen.last().capture)
        val tree = """{"v":1,"nodes":[{"s":"#a","i":0,"k":"input","x":0,"y":0,"w":10,"h":10,"m":1}]}"""
        ScruterBridge.teamImage("/home", byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1), tree, 100, 200, 2f)
        Sdk.worker(e)
        val up = server.next("/m/v1/team/screens")
        val body = String(up.body, Charsets.ISO_8859_1)
        assertTrue(body, body.contains("\"screen\":\"\\/home\""))
        assertTrue(body.contains("\"nodes\""))
        c.pause().stop()
    }

    @Test
    fun aUsersPhoneTakesNoImage() {
        val e = start()
        val c = Robolectric.buildActivity(Host::class.java).setup()
        Sdk.idle(100)
        ScruterBridge.screen("/home")
        Sdk.idle()
        Sdk.worker(e)
        assertFalse(seen.single().capture)
        ScruterBridge.teamImage("/home", byteArrayOf(0xFF.toByte(), 0xD8.toByte()), """{"v":1,"nodes":[]}""", 1, 1, 1f)
        Sdk.worker(e)
        assertTrue(server.none("/m/v1/team/screens"))
        c.pause().stop()
    }

    @Test
    fun aDartErrorNamesItsSnapshot() {
        val e = start()
        val c = Robolectric.buildActivity(Host::class.java).setup()
        Sdk.idle(100)
        Sdk.worker(e)
        ScruterBridge.reportError(
            fatal = false, source = "dart", type = "StateError", reason = "Bad state",
            frames = listOf(mapOf("a" to "0x1234", "i" to 0)), buildId = "7d7673e24f49333c",
            images = listOf(mapOf("n" to "libapp.so", "u" to "7d7673e24f49333c", "la" to "0x0", "ar" to "arm64")),
        )
        Sdk.worker(e)
        ScruterBridge.flush()
        Sdk.worker(e)
        val b = server.batchWith("cr")
        val r: JSONObject = b.getJSONArray("cr").getJSONObject(0)
        assertEquals("nonfatal", r.getString("k"))
        assertEquals("dart", r.getString("src"))
        assertEquals("7d7673e24f49333c", r.getString("bld"))
        assertEquals("libapp.so", r.getJSONArray("img").getJSONObject(0).getString("n"))
        assertEquals(0, r.getJSONArray("th").getJSONObject(0).getJSONArray("f").getJSONObject(0).getInt("i"))
        assertNull(r.opt("map").takeIf { it != "" })
        Conformance.crash("dart", r)
        c.pause().stop()
    }
}
