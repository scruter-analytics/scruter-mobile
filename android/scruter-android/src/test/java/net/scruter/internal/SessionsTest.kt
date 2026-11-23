package net.scruter.internal

import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import net.scruter.FieldError
import net.scruter.Scruter
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ActivityController
import java.io.File

/** Sessions, screens, events, batches and their retries, end to end against a local server (docs/MOBILE.md §3). */
@RunWith(RobolectricTestRunner::class)
class SessionsTest {
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

    private fun <T : android.app.Activity> open(c: Class<T>): ActivityController<T> {
        val controller = Robolectric.buildActivity(c).setup()
        Sdk.idle(100)
        return controller
    }

    private fun background(c: ActivityController<*>, e: Engine) {
        c.pause().stop()
        Sdk.idle()
        Sdk.worker(e)
    }

    private fun tap(activity: android.app.Activity, view: View) {
        val loc = IntArray(2)
        view.getLocationInWindow(loc)
        val x = loc[0] + view.width / 2f
        val y = loc[1] + view.height / 2f
        val t = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(t, t, MotionEvent.ACTION_DOWN, x, y, 0)
        val up = MotionEvent.obtain(t, t + 50, MotionEvent.ACTION_UP, x, y, 0)
        activity.window.callback.dispatchTouchEvent(down)
        activity.window.callback.dispatchTouchEvent(up)
        down.recycle()
        up.recycle()
    }

    @Test
    fun firstSessionBatch() {
        val e = Sdk.start(server)
        val config = server.next("/m/v1/config")
        assertTrue(config.query!!.contains("a=ATMONA02"))
        assertTrue(config.query!!.contains("p=android"))
        val c = open(ProductActivity::class.java)
        Scruter.track("Add to cart", mapOf("color" to "blue", "quantity" to 2, "gift" to true, "object" to Any()), revenue = 49.0, currency = "eur")
        Sdk.idle()
        background(c, e)
        val req = server.next("/m/v1/batch")
        assertEquals("application/json", req.headers["content-type"])
        assertTrue(req.headers["user-agent"]!!.startsWith("Scruter-Android/"))
        val b = req.json()
        Conformance.batch("first-session", b)
        assertEquals(1, b.getInt("v"))
        assertEquals("ATMONA02", b.getString("a"))
        assertEquals("e1", b.getString("ce"))
        assertTrue(b.getString("sdk").startsWith("android/"))
        val s = b.getJSONArray("s").getJSONObject(0)
        assertEquals(1, s.getInt("q"))
        assertFalse(s.has("pv"))
        assertEquals(1, s.getInt("n"))
        assertTrue(s.getString("i").matches(Regex("20\\d\\d-\\d\\d-\\d\\d")))
        assertEquals("android", s.getString("p"))
        assertEquals(32, s.getString("d").length)
        assertEquals("icon", s.getJSONObject("o").getString("k"))
        val st = s.getJSONObject("c")
        assertEquals(1, st.getInt("sv"))
        assertEquals(1, st.getInt("ev"))
        assertEquals("Product", st.getString("en"))
        assertEquals(4900, st.getJSONObject("rev").getInt("EUR"))
        val events = b.getJSONArray("e")
        val kinds = (0 until events.length()).map { events.getJSONObject(it).getString("k") }
        assertEquals(listOf("screen", "event", "screen_end"), kinds)
        val ev = events.getJSONObject(1)
        assertEquals("Add to cart", ev.getString("n"))
        assertEquals("blue", ev.getJSONObject("p").getString("color"))
        assertEquals("2", ev.getJSONObject("p").getString("quantity"))
        assertEquals("true", ev.getJSONObject("p").getString("gift"))
        assertFalse(ev.getJSONObject("p").has("object"))
        assertEquals("EUR", ev.getJSONObject("$").getString("c"))
        assertEquals(49.0, ev.getJSONObject("$").getDouble("a"), 0.0)
        // The analysed screen view (aa = 100 in the fake configuration).
        val x = b.getJSONArray("x").getJSONObject(0)
        assertEquals("Product", x.getString("n"))
        assertEquals(1, x.getInt("q"))
    }

    @Test
    fun theNextStateCarriesTheAcknowledgedOne() {
        val e = Sdk.start(server)
        val c = open(ProductActivity::class.java)
        background(c, e)
        val first = server.next("/m/v1/batch").json().getJSONArray("s").getJSONObject(0)
        c.restart().resume()
        Sdk.idle(100)
        Scruter.track("Share")
        Sdk.idle()
        background(c, e)
        val b = server.next("/m/v1/batch").json()
        Conformance.batch("second-state", b)
        val s = b.getJSONArray("s").getJSONObject(0)
        assertEquals(first.getString("id"), s.getString("id"))
        assertEquals(2, s.getInt("q"))
        assertEquals(first.getJSONObject("c").toString(), s.getJSONObject("pv").toString())
        assertEquals(2, s.getJSONObject("c").getInt("ev") + s.getJSONObject("c").getInt("sv"))
    }

    @Test
    fun aRetryResendsTheSameBatch() {
        var calls = 0
        server.batch = { if (calls++ == 0) 503 to """{"error":{"code":"unavailable","message":"x"}}""" else 202 to "{}" }
        val e = Sdk.start(server)
        val c = open(ProductActivity::class.java)
        background(c, e)
        val first = server.next("/m/v1/batch").json()
        e.post { e.flush("test") }
        Sdk.worker(e)
        val second = server.next("/m/v1/batch").json()
        assertEquals(first.getString("b"), second.getString("b"))
        assertEquals(first.getJSONArray("s").toString(), second.getJSONArray("s").toString())
        assertEquals(first.getJSONArray("e").toString(), second.getJSONArray("e").toString())
        assertEquals(0, e.store!!.count)
        assertNull(e.store!!.inflight())
    }

    @Test
    fun aRefusedBatchIsDroppedAndTheStateReverts() {
        var calls = 0
        server.batch = { if (calls++ == 0) 400 to """{"error":{"code":"invalid_payload","message":"x"}}""" else 202 to "{}" }
        val e = Sdk.start(server)
        val c = open(ProductActivity::class.java)
        background(c, e)
        server.next("/m/v1/batch")
        assertEquals(0, e.store!!.count)
        c.restart().resume()
        Sdk.idle(100)
        Scruter.track("Share")
        Sdk.idle()
        background(c, e)
        val s = server.next("/m/v1/batch").json().getJSONArray("s").getJSONObject(0)
        assertEquals("nothing was acknowledged: q starts again at 1", 1, s.getInt("q"))
        assertFalse(s.has("pv"))
    }

    @Test
    fun namedScreensAndIgnoredScreens() {
        val e = Sdk.start(server)
        val c = open(CartActivity::class.java)
        Scruter.screen("DebugMenu")
        Sdk.idle()
        Scruter.screen("Payment")
        Sdk.idle()
        background(c, e)
        val b = server.next("/m/v1/batch").json()
        val names = (0 until b.getJSONArray("e").length()).map { b.getJSONArray("e").getJSONObject(it) }
            .filter { it.getString("k") == "screen" }.map { it.getString("n") }
        assertEquals(listOf("Shopping cart", "Payment"), names)
        assertEquals("Payment", b.getJSONArray("s").getJSONObject(0).getJSONObject("c").getString("ex"))
    }

    @Test
    fun tapsDeadAndRage() {
        val e = Sdk.start(server)
        val c = open(ProductActivity::class.java)
        val a = c.get()
        tap(a, a.button)
        Sdk.idle(1200)
        tap(a, a.description)
        Sdk.idle(1200)
        tap(a, a.secret)
        Sdk.idle(30)
        tap(a, a.secret)
        Sdk.idle(30)
        tap(a, a.secret)
        Sdk.idle(1200)
        background(c, e)
        val b = server.batchWith("x")
        Conformance.batch("taps", b)
        val x = b.getJSONArray("x").getJSONObject(0)
        val taps = x.getJSONArray("c")
        assertEquals(5, x.getInt("cn"))
        val first = taps.getJSONArray(0)
        assertEquals("#button1", first.getString(0))
        assertEquals(0, first.getInt(1))
        assertEquals("button", first.getString(2))
        assertTrue(first.getInt(3) in 40..60)
        assertEquals(0, first.getInt(6))
        val dead = taps.getJSONArray(1)
        assertEquals("#text1", dead.getString(0))
        assertEquals("text", dead.getString(2))
        assertEquals(1, dead.getInt(6))
        // The masked view is the target itself; the third tap opens a rage burst.
        val third = taps.getJSONArray(4)
        assertEquals(2, third.getInt(6) and 2)
        assertEquals(1, x.getInt("cr"))
        assertTrue(x.getInt("cd") >= 1)
    }

    @Test
    fun listCellsAreIndexedByPosition() {
        val e = Sdk.start(server)
        val c = open(ListActivity::class.java)
        val a = c.get()
        val third = a.list.findViewHolderForAdapterPosition(2)!!.itemView
        tap(a, third)
        Sdk.idle(1200)
        background(c, e)
        val x = server.batchWith("x").getJSONArray("x").getJSONObject(0)
        val t = x.getJSONArray("c").getJSONArray(0)
        assertEquals("#list/LinearLayout[cell]", t.getString(0))
        assertEquals(2, t.getInt(1))
        assertEquals("cell", t.getString(2))
    }

    @Test
    fun formsNeverCarryAValue() {
        val e = Sdk.start(server)
        val c = open(ProductActivity::class.java)
        val a = c.get()
        Sdk.idle(100)
        a.postal.requestFocus()
        Sdk.idle()
        a.postal.setText("75011")
        a.password.requestFocus()
        a.password.setText("hunter2")
        Sdk.idle()
        tap(a, a.terms)
        Sdk.idle(600)
        Scruter.fieldError("postalCode", FieldError.FORMAT)
        Scruter.formSent("Delivery")
        Sdk.idle()
        background(c, e)
        val b = server.batchWith("x")
        val text = b.toString()
        assertFalse(text.contains("75011"))
        assertFalse(text.contains("hunter2"))
        Conformance.batch("forms", b)
        val f = b.getJSONArray("x").getJSONObject(0).getJSONArray("f").getJSONObject(0)
        assertEquals("Delivery", f.getString("s"))
        assertEquals(1, f.getInt("b"))
        assertEquals(1, f.getInt("ok"))
        val fields = f.getJSONArray("fd")
        val keys = (0 until fields.length()).map { fields.getJSONArray(it).getString(0) }
        assertEquals(listOf("postalCode", "terms"), keys)
        val postal = fields.getJSONArray(0)
        assertEquals("number", postal.getString(1))
        assertTrue(postal.getInt(4) >= 1)
        assertEquals(2, postal.getInt(7) and 2)
        assertEquals(1, postal.getInt(8))
        assertEquals("checkbox", fields.getJSONArray(1).getString(1))
    }

    @Test
    fun optOutSendsNothingAndForgets() {
        val e = Sdk.start(server)
        val c = open(ProductActivity::class.java)
        Scruter.optOut()
        Sdk.idle()
        Sdk.worker(e)
        assertTrue(Scruter.isOptedOut)
        assertFalse(File(Sdk.app.noBackupFilesDir, "scruter").exists())
        Scruter.track("Add to cart")
        background(c, e)
        assertTrue(server.none("/m/v1/batch", 800))
        Scruter.optIn()
        Sdk.idle()
        Sdk.worker(e)
        c.restart().resume()
        Sdk.idle(100)
        background(c, e)
        val s = server.next("/m/v1/batch").json().getJSONArray("s").getJSONObject(0)
        assertEquals("a new install without install day", 0, s.getInt("n"))
        assertFalse(s.has("i"))
        assertFalse(s.has("ins"))
    }

    @Test
    fun configurationOffKeepsNothing() {
        server.config = """{"v":1,"on":0,"e":"0","ttl":300}"""
        val e = Sdk.start(server)
        val c = open(ProductActivity::class.java)
        Scruter.track("Add to cart")
        background(c, e)
        assertTrue(server.none("/m/v1/batch", 800))
        assertEquals(0, e.store!!.count)
    }

    @Test
    fun crashesAreSentAtTheNextLaunch() {
        val e = Sdk.start(server)
        val c = open(ProductActivity::class.java)
        Scruter.track("Payment opened")
        Sdk.idle()
        Sdk.worker(e)
        val id = e.clock.sessionId!!
        val error = IllegalStateException("Broken for jane@example.com", RuntimeException("wrapper"))
        val report = Crashes.report(e, id, "crash", Thread.currentThread(), Crashes.rootCause(error), System.currentTimeMillis())
        Crashes.save(e, id, report)
        // The process dies: a new one starts.
        Sdk.stop()
        val e2 = Sdk.start(server)
        val b = server.next("/m/v1/batch").json()
        Conformance.batch("crash-relaunch", b)
        val s = b.getJSONArray("s").getJSONObject(0)
        assertEquals(id, s.getString("id"))
        assertEquals(1, s.getJSONObject("c").getInt("cr"))
        val r = b.getJSONArray("cr").getJSONObject(0)
        assertEquals("crash", r.getString("k"))
        assertEquals("java.lang.RuntimeException", r.getJSONObject("ex").getString("type"))
        val bc = r.getJSONArray("bc")
        assertEquals("Payment opened", bc.getJSONObject(bc.length() - 1).getString("n"))
        assertNotNull(r.getJSONArray("th").getJSONObject(0).getJSONArray("f").getJSONObject(0).getString("cl"))
        c.pause().stop()
        Sdk.worker(e2)
    }

    @Test
    fun theQueueKeepsItsLimits() {
        val s = Store(File(Sdk.app.cacheDir, "limits.db"))
        repeat(Store.MAX_ITEMS + 20) { s.add(Store.EVENT, "s", it.toLong(), "{}") }
        assertTrue(s.count <= Store.MAX_ITEMS)
        repeat(15) { s.add(Store.CRASH, "s", it.toLong(), "{}") }
        assertEquals(Store.MAX_CRASHES, s.crashes)
        s.dropBefore(Long.MAX_VALUE)
        assertEquals(0, s.count)
        s.close()
    }

    @Test
    fun batchesKeepTheirCaps() {
        val e = Sdk.start(server)
        val c = open(CartActivity::class.java)
        repeat(260) { Scruter.track("Event $it") }
        Sdk.idle()
        Sdk.worker(e)
        background(c, e)
        val first = server.next("/m/v1/batch").json()
        assertTrue(first.getJSONArray("e").length() <= 200)
        Conformance.batch("caps", first)
        val second = server.next("/m/v1/batch").json()
        assertEquals(2, second.getJSONArray("s").getJSONObject(0).getInt("q"))
        assertTrue(String(first.toString().toByteArray()).length < Batches.MAX_JSON)
    }
}
