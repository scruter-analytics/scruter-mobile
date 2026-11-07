package net.scruter.internal

import android.content.Intent
import android.net.Uri
import net.scruter.Scruter
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowAlertDialog

/** Team phones: QR registration, the session flag, the masked screen image and its element tree (docs/MOBILE.md §3.11–§3.12). */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TeamTest {
    private val server = FakeServer()

    @After
    fun tearDown() {
        Sdk.stop()
        server.close()
    }

    /** The parts of a multipart body by name. */
    private fun parts(req: FakeServer.Req): Map<String, ByteArray> {
        val boundary = req.headers["content-type"]!!.substringAfter("boundary=")
        val text = String(req.body, Charsets.ISO_8859_1)
        val out = HashMap<String, ByteArray>()
        for (chunk in text.split("--$boundary")) {
            val head = chunk.substringBefore("\r\n\r\n", "")
            val name = Regex("name=\"([^\"]+)\"").find(head)?.groupValues?.get(1) ?: continue
            val body = chunk.substringAfter("\r\n\r\n").removeSuffix("\r\n")
            out[name] = body.toByteArray(Charsets.ISO_8859_1)
        }
        return out
    }

    private val key = "scr_dbg_" + "k".repeat(43)

    /** Robolectric's WebView gets no frame, so it never reaches a captured tree: its kind is checked here. */
    @Test
    fun aWebViewIsWebInTheTreeAndMediaForATap() {
        val web = android.webkit.WebView(Sdk.app)
        val node = { kind: String, source: Any -> UiNode(null, "", false, kind, false, true, false, 0, 0, 10, 10, -1, source) }
        assertEquals("media", ViewNodes.kind(web, false))
        assertEquals("web", ViewNodes.treeKind(node("media", web)))
        assertEquals("media", ViewNodes.treeKind(node("media", android.widget.VideoView(Sdk.app))))
    }

    @Test
    fun aReleaseBuildNeverUsesTheDebugKey() {
        val flags = Sdk.app.applicationInfo.flags
        Sdk.app.applicationInfo.flags = flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE.inv()
        val e = Sdk.start(server, debugKey = key)
        assertTrue(server.none("/m/v1/team/register", 500))
        assertFalse(e.team.active)
        Sdk.app.applicationInfo.flags = flags
    }

    @Test
    fun aDebugBuildRegistersWithItsKeyAndARevokedPhoneLeaves() {
        val flags = Sdk.app.applicationInfo.flags
        Sdk.app.applicationInfo.flags = flags or android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE
        server.teamConfigStatus = 401
        val e = Sdk.start(server, debugKey = key)
        val r = server.next("/m/v1/team/register").json()
        Conformance.write("team-register", "debug", r)
        assertEquals(key, r.getString("debug_key"))
        assertEquals("debug", r.getString("build_kind"))
        server.next("/m/v1/team/config")
        Sdk.worker(e)
        assertFalse("401 on the team configuration: token deleted", e.team.active)
        Sdk.app.applicationInfo.flags = flags
    }

    /** A link can come from anyone: a phone only becomes a team phone when the person holding it says yes. */
    @Test
    fun aTeamLinkAsksFirstAndRefusingRegistersNothing() {
        val e = Sdk.start(server)
        Robolectric.buildActivity(ProductActivity::class.java).setup()
        val link = Uri.parse("scruter-atmona02://team?t=scr_qr_" + "c".repeat(32))
        Scruter.handle(Intent(Intent.ACTION_VIEW, link))
        Sdk.idle()
        val asked = ShadowAlertDialog.getLatestAlertDialog() as android.app.AlertDialog
        val text = org.robolectric.Shadows.shadowOf(asked)
        assertTrue(text.title.toString().contains(Sdk.app.applicationInfo.loadLabel(Sdk.app.packageManager)))
        asked.getButton(android.content.DialogInterface.BUTTON_NEGATIVE).performClick()
        Sdk.idle()
        Sdk.worker(e)
        assertTrue(server.none("/m/v1/team/register"))
        assertFalse(e.team.active)
    }

    /** The same table as the server's and iOS's tests (docs/MOBILE.md §3.13). */
    @Test
    fun linksLoseTheirPersonalSegments() {
        for ((from, to) in listOf(
            "https://a.fr/promo/noel" to "https://a.fr/promo/noel",
            "https://a.fr/u/camille@x.fr/edit" to "https://a.fr/u/:id/edit",
            "https://a.fr/orders/123456?utm_source=mail&token=abc" to "https://a.fr/orders/:id?utm_source=mail",
            "https://a.fr/c/42" to "https://a.fr/c/:id",
            "https://a.fr/CMD-2026-48213/x" to "https://a.fr/:id/x",
            "https://a.fr/t/1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9" to "https://a.fr/t/:id",
            "https://a.fr/r/9fK2mQ7xLp3Tz8Wq" to "https://a.fr/r/:id",
            "https://a.fr/soldes-hiver-2026" to "https://a.fr/soldes-hiver-2026",
            "https://a.fr/iphone-15-pro" to "https://a.fr/iphone-15-pro",
        )) {
            assertEquals(from, to, Openings.link(Uri.parse(from)))
        }
    }

    @Test
    fun aPhoneAddedByQrCodeTakesMaskedImages() {
        val start = System.currentTimeMillis()
        val e = Sdk.start(server)
        println("TIMING start ${System.currentTimeMillis() - start} ms")
        val link = Uri.parse("scruter-atmona02://team?t=scr_qr_" + "b".repeat(32))
        Robolectric.buildActivity(ProductActivity::class.java).setup()
        Scruter.handle(Intent(Intent.ACTION_VIEW, link))
        Sdk.idle()
        Sdk.worker(e)
        assertTrue("nothing leaves before the person says yes", server.none("/m/v1/team/register"))
        val asked = ShadowAlertDialog.getLatestAlertDialog() as android.app.AlertDialog
        asked.getButton(android.content.DialogInterface.BUTTON_POSITIVE).performClick()
        Sdk.idle()
        Sdk.worker(e)
        val register = server.next("/m/v1/team/register").json()
        Conformance.write("team-register", "qr", register)
        assertEquals("scr_qr_" + "b".repeat(32), register.getString("token"))
        assertEquals("android", register.getString("platform"))
        assertTrue(e.team.active)
        server.next("/m/v1/team/config")

        val c = Robolectric.buildActivity(ProductActivity::class.java).setup()
        Sdk.idle(100)
        Sdk.worker(e)
        val t0 = System.currentTimeMillis()
        // Idle for 1 s, layout stable, then the stitched capture scrolls frame by frame.
        repeat(60) { Sdk.idle(100) }
        Sdk.worker(e)
        println("TIMING idle loop ${System.currentTimeMillis() - t0} ms")
        val upload = server.next("/m/v1/team/screens", 20)
        println("TIMING upload ${System.currentTimeMillis() - t0} ms")
        assertEquals("Bearer scr_tp_" + "a".repeat(43), upload.headers["authorization"])
        val p = parts(upload)
        val meta = JSONObject(String(p["meta"]!!))
        val tree = JSONObject(String(p["tree"]!!))
        Conformance.write("team-screen#meta", "product", meta)
        Conformance.write("team-screen#tree", "product", tree)
        assertEquals("Product", meta.getString("screen"))
        val jpeg = p["image"]!!
        assertEquals(0xFF.toByte(), jpeg[0])
        assertEquals(0xD8.toByte(), jpeg[1])
        assertTrue("stitched: taller than the window", meta.getInt("height") > c.get().window.decorView.height * 0.9)
        val nodes = tree.getJSONArray("nodes")
        val all = (0 until nodes.length()).map { nodes.getJSONObject(it) }
        val button = all.first { it.getString("s") == "#button1" }
        assertEquals("Add to cart", button.getString("l"))
        val masked = all.filter { it.optInt("m") == 1 }
        assertTrue(masked.size >= 3)
        assertTrue(masked.none { it.has("l") })
        assertFalse(tree.toString().contains("Morgan Smith"))

        // The phone's sessions are never counted.
        c.pause().stop()
        Sdk.idle()
        Sdk.worker(e)
        val b = server.batchWith("s")
        assertEquals(1, b.getJSONArray("s").getJSONObject(0).getInt("tm"))
    }
}
