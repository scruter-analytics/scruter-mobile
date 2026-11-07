package net.scruter.internal

import android.content.Intent
import android.net.Uri
import net.scruter.Scruter
import net.scruter.bridge.BridgeElement
import net.scruter.bridge.ElementInspector
import net.scruter.bridge.ScruterBridge
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowAlertDialog

/** What a wrapper SDK drives (docs/MOBILE.md §20): its routes, the inspector of its views, its fatal errors. */
@RunWith(RobolectricTestRunner::class)
class BridgeTest {
    private lateinit var server: FakeServer

    @Before
    fun setUp() {
        server = FakeServer()
    }

    @After
    fun tearDown() {
        Sdk.stop()
        server.close()
    }

    private fun start(): Engine {
        ScruterBridge.start(Sdk.app, "ATMONA02", "react_native/1.0.0", endpoint = server.url, apiEndpoint = server.url, debug = true)
        val e = Scruter.engine()!!
        Sdk.worker(e)
        Sdk.idle()
        return e
    }

    @Test
    fun theInspectorNamesAViewAndDecidesWhatItIs() {
        val e = start()
        Sdk.worker(e)
        val c = Robolectric.buildActivity(ProductActivity::class.java).setup()
        Sdk.idle(100)
        val a = c.get()
        ScruterBridge.setElementInspector(
            ElementInspector { v ->
                when (v) {
                    a.description -> BridgeElement("from_inspector", index = 7, interactive = true, kind = "cell")
                    a.button -> BridgeElement(ignore = true)
                    a.secret -> BridgeElement(mask = true, form = "Delivery")
                    else -> null
                }
            },
        )
        val tree = ViewNodes.build(a.window.decorView)
        val text = tree.nodes.first { it.source === a.description }
        assertEquals("#from_inspector", text.part)
        assertEquals("cell", text.kind)
        assertEquals(7, tree.identity(text).second)
        assertTrue(text.interactive)
        assertTrue(tree.nodes.first { it.source === a.button }.ignored)
        val secret = tree.nodes.first { it.source === a.secret }
        assertTrue(secret.masked)
        assertEquals("Delivery", secret.form)
    }

    @Test
    fun aWrappersScreensAreItsRoutesAndItsSdkIsNamed() {
        val e = start()
        val c = Robolectric.buildActivity(ProductActivity::class.java).setup()
        Sdk.idle(100)
        ScruterBridge.screen("Home", true)
        Sdk.idle(100)
        Sdk.worker(e)
        Scruter.engine()!!.post { e.flush("test") }
        val b = server.batchWith("e")
        assertEquals("react_native/1.0.0", b.getString("sdk"))
        val events = b.getJSONArray("e")
        val names = (0 until events.length()).map { events.getJSONObject(it) }.filter { it.getString("k") == "screen" }.map { it.getString("n") }
        assertEquals(listOf("Home"), names)
        c.pause().stop()
    }

    @Test
    fun aFatalErrorIsWrittenAtOnceAndTheAbortThatFollowsIsNotASecondCrash() {
        val e = start()
        val c = Robolectric.buildActivity(ProductActivity::class.java).setup()
        Sdk.idle(100)
        ScruterBridge.reportError(true, "js", "TypeError", "oops", listOf(mapOf("fn" to "onPress", "fl" to "index.android.bundle", "l" to 1L, "co" to 123L, "ia" to true)), "bundle-1", null)
        val written = e.crashDir.listFiles()!!.filter { it.name.endsWith(".json") }
        assertEquals(1, written.size)
        val text = written[0].readText()
        assertTrue(text, text.contains("\"src\":\"js\"") && text.contains("\"bun\":\"bundle-1\""))
        Thread.getDefaultUncaughtExceptionHandler()!!.uncaughtException(Thread.currentThread(), RuntimeException("com.facebook.react.common.JavascriptException"))
        assertEquals(1, e.crashDir.listFiles()!!.count { it.name.endsWith(".json") })
        c.pause().stop()
    }

    @Test
    fun aNativeCrashIsStillCaughtWithoutAFatalJavaScriptError() {
        val e = start()
        val c = Robolectric.buildActivity(ProductActivity::class.java).setup()
        Sdk.idle(100)
        Thread.getDefaultUncaughtExceptionHandler()!!.uncaughtException(Thread.currentThread(), RuntimeException("native"))
        assertEquals(1, e.crashDir.listFiles()!!.count { it.name.endsWith(".json") })
        c.pause().stop()
    }

    @Test
    fun aQrCodeThatOpensTheAppBeforeTheWrapperStartsIsNotLost() {
        Scruter.handle(Intent(Intent.ACTION_VIEW, Uri.parse("scruter-atmona02://team?t=scr_qr_" + "q".repeat(32))))
        val e = start()
        Robolectric.buildActivity(ProductActivity::class.java).setup()
        Sdk.idle(300)
        val asked = ShadowAlertDialog.getLatestAlertDialog() as android.app.AlertDialog
        asked.getButton(android.content.DialogInterface.BUTTON_POSITIVE).performClick()
        Sdk.idle()
        Sdk.worker(e)
        assertEquals("/m/v1/team/register", server.next("/m/v1/team/register").path)
    }

    @Test
    fun theDebugLogReachesTheSink() {
        val lines = java.util.concurrent.CopyOnWriteArrayList<String>()
        ScruterBridge.setLogSink { lines.add(it) }
        val e = start()
        Sdk.worker(e)
        ScruterBridge.setLogSink(null)
        assertFalse(lines.isEmpty())
    }

    @Test
    fun teamModeIsReadAndLeft() {
        val e = start()
        assertFalse(ScruterBridge.isTeamPhone())
        Robolectric.buildActivity(ProductActivity::class.java).setup()
        ScruterBridge.handleUrl("scruter-atmona02://team?t=scr_qr_" + "q".repeat(32))
        Sdk.idle(100)
        val asked = ShadowAlertDialog.getLatestAlertDialog() as android.app.AlertDialog
        asked.getButton(android.content.DialogInterface.BUTTON_POSITIVE).performClick()
        Sdk.idle()
        Sdk.worker(e)
        server.next("/m/v1/team/register")
        Sdk.worker(e)
        assertTrue(ScruterBridge.isTeamPhone())
        ScruterBridge.leaveTeamMode()
        Sdk.worker(e)
        assertFalse(ScruterBridge.isTeamPhone())
    }
}
