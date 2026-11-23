package net.scruter.cmp.internal

import android.app.Dialog
import net.scruter.cmp.ScruterCMP
import net.scruter.cmp.bridge.ScruterCMPBridge
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
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowDialog

/** What the React Native and Flutter wrappers read and hear (ScruterCMPBridge, docs/CMP-MOBILE.md §3.16). */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BridgeTest {
    private lateinit var server: FakeIngest
    private val events = ArrayList<Pair<Map<String, Any?>, Boolean>>()

    @Before
    fun setUp() {
        Sdk.wipe()
        ScruterCMPBridge.reset()
        server = FakeIngest()
    }

    @After
    fun tearDown() {
        Sdk.stop()
        ScruterCMPBridge.reset()
        server.close()
    }

    private fun sheet(): Dialog {
        Sdk.until(what = "the sheet") { ScruterCMP.engine()?.ui?.current()?.isShowing == true }
        return ShadowDialog.getLatestDialog()
    }

    private fun start(): Boolean {
        ScruterCMPBridge.listen { s, fresh -> events.add(s to fresh) }
        val started = ScruterCMPBridge.start(Sdk.app, "ATMONA02", "react_native/1.1.0", endpoint = server.url, debug = true)
        ScruterCMP.engine()?.let { Sdk.worker(it) }
        Sdk.idle()
        return started
    }

    @Suppress("UNCHECKED_CAST")
    private fun choice(s: Map<String, Any?>) = s["choice"] as Map<String, Any?>?

    @Test
    fun beforeAStartNothingIsGranted() {
        val s = ScruterCMPBridge.snapshot()
        assertEquals("unavailable", s["state"])
        assertEquals(listOf("necessary"), s["granted"])
        assertNull(s["choice"])
        @Suppress("UNCHECKED_CAST")
        val signals = s["signals"] as Map<String, String>
        assertEquals("granted", signals["security_storage"])
        assertEquals("denied", signals["analytics_storage"])
    }

    @Test
    fun onceAProcessTheWrapperInTheBeaconsAndOneEventPerChoice() {
        assertTrue(start())
        assertFalse("a reload starts nothing", ScruterCMPBridge.start(Sdk.app, "ATMONA02", "react_native/1.1.0", endpoint = server.url))
        Robolectric.buildActivity(TestActivity::class.java).setup()
        val d = sheet()
        assertEquals("needsDecision", ScruterCMPBridge.snapshot()["state"])
        val hit = server.next("/cmp/hit").json()
        assertEquals("react_native/1.1.0", hit.getString("cv"))
        Conformance.write("cmp-hit", "react-native", hit)
        Views.click(d.window!!.decorView, "Tout accepter")
        Sdk.until(what = "the choice") { events.any { it.second } }
        val proof = server.next("/cmp/consent").json()
        assertEquals("react_native/1.1.0", proof.getString("cv"))
        Conformance.write("cmp-consent", "react-native", proof)
        Sdk.idle(200)
        assertEquals("one event for the first decision (Android's whenReady and onChange both see it)", 1, events.count { it.second })
        val s = events.last { it.second }.first
        assertEquals("ready", s["state"])
        val c = choice(s)!!
        assertEquals(listOf("advertising", "analytics", "necessary"), c["granted"])
        assertEquals(emptyList<String>(), c["denied"])
        assertEquals(proof.getString("i"), c["consentId"])
        assertEquals(s["consentId"], c["consentId"])
        assertTrue((c["decidedAt"] as Long) % 1000 == 0L)
        @Suppress("UNCHECKED_CAST")
        assertEquals("granted", (s["signals"] as Map<String, String>)["ad_storage"])
        assertEquals(s, ScruterCMPBridge.snapshot())
    }

    @Test
    fun aReplacedListenerIsTheOnlyOneTold() {
        start()
        var other = 0
        ScruterCMPBridge.listen { _, _ -> other++ }
        val before = events.size
        Robolectric.buildActivity(TestActivity::class.java).setup()
        Views.click(sheet().window!!.decorView, "Tout refuser")
        Sdk.until(what = "the other listener") { other > 0 }
        assertEquals(before, events.size)
        assertEquals(listOf("necessary"), ScruterCMPBridge.snapshot()["granted"])
        assertEquals(listOf("advertising", "analytics"), choice(ScruterCMPBridge.snapshot())!!["denied"])
    }

    @Test
    fun aDebugResetForgetsTheChoiceThenTheNextDecisionIsNew() {
        start()
        Robolectric.buildActivity(TestActivity::class.java).setup()
        Views.click(sheet().window!!.decorView, "Tout accepter")
        Sdk.until(what = "the first choice") { events.count { it.second } == 1 }
        ScruterCMP.debugReset()
        Sdk.until(what = "the reset") { ScruterCMPBridge.snapshot()["state"] == "needsDecision" }
        assertNull(choice(ScruterCMPBridge.snapshot()))
        assertFalse(events.last().second)
        ScruterCMP.forceShow = true
        Views.click(sheet().window!!.decorView, "Tout refuser")
        Sdk.until(what = "the second choice") { events.count { it.second } == 2 }
    }
}
