package net.scruter.sample

import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import androidx.recyclerview.widget.RecyclerView
import androidx.test.core.app.ApplicationProvider
import net.scruter.Scruter
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.time.Duration
import java.util.zip.GZIPInputStream

/**
 * The sample app walked through by a user on the oldest, a middle and the newest Android, in its real layouts, themes
 * and libraries (AppCompat, Material, Fragment, RecyclerView, Navigation Compose), with the SDK against a local server.
 * One test per sandbox: the SDK is a process singleton.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = TestApp::class, sdk = [24, 30, 35])
class JourneyTest {
    private val batches = LinkedBlockingQueue<JSONObject>()

    @Volatile
    private var configured = false
    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))

    private fun line(i: java.io.InputStream): String {
        val b = StringBuilder()
        while (true) {
            val c = i.read()
            if (c < 0 || c == '\n'.code) break
            if (c != '\r'.code) b.append(c.toChar())
        }
        return b.toString()
    }

    private fun serve() {
        Thread {
            while (!socket.isClosed) {
                val s = try {
                    socket.accept()
                } catch (e: Exception) {
                    break
                }
                s.use {
                    val input = BufferedInputStream(it.getInputStream())
                    val path = line(input).split(" ").getOrElse(1) { "" }
                    val headers = HashMap<String, String>()
                    while (true) {
                        val h = line(input)
                        if (h.isEmpty()) break
                        headers[h.substringBefore(':').lowercase()] = h.substringAfter(':').trim()
                    }
                    val raw = ByteArray(headers["content-length"]?.toInt() ?: 0)
                    var at = 0
                    while (at < raw.size) {
                        val n = input.read(raw, at, raw.size - at)
                        if (n < 0) break
                        at += n
                    }
                    val body = if (headers["content-encoding"] == "gzip") GZIPInputStream(ByteArrayInputStream(raw)).readBytes() else raw
                    val answer = if (path.startsWith("/m/v1/config")) {
                        configured = true
                        """{"v":1,"on":1,"e":"e1","tz":"Europe/Paris","aa":100,"cr":1,"xs":[],"tp":0,"ttl":3600}"""
                    } else {
                        batches.add(JSONObject(String(body, Charsets.UTF_8)))
                        "{}"
                    }
                    it.getOutputStream().write(("HTTP/1.1 ${if (path.startsWith("/m/v1/config")) 200 else 202} X\r\nContent-Length: ${answer.length}\r\nConnection: close\r\n\r\n$answer").toByteArray())
                }
            }
        }.apply { isDaemon = true }.start()
    }

    private fun idle(ms: Long = 100) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))

    private fun tap(a: android.app.Activity, v: View) {
        val loc = IntArray(2)
        v.getLocationInWindow(loc)
        val x = loc[0] + v.width / 2f
        val y = loc[1] + v.height / 2f
        val t = SystemClock.uptimeMillis()
        a.window.callback.dispatchTouchEvent(MotionEvent.obtain(t, t, MotionEvent.ACTION_DOWN, x, y, 0))
        a.window.callback.dispatchTouchEvent(MotionEvent.obtain(t, t + 50, MotionEvent.ACTION_UP, x, y, 0))
    }

    /** Every batch until the queue stays quiet: events, analysed views and the last session state. */
    private fun drain(): List<JSONObject> {
        val out = ArrayList<JSONObject>()
        while (true) out.add(batches.poll(3, TimeUnit.SECONDS) ?: break)
        return out
    }

    private fun objects(a: JSONArray?): List<JSONObject> = if (a == null) emptyList() else (0 until a.length()).map { a.getJSONObject(it) }

    @Test
    fun aUserWalksThroughTheApp() {
        org.robolectric.shadows.ShadowLog.stream = System.out
        serve()
        val app = ApplicationProvider.getApplicationContext<android.app.Application>()
        val url = "http://127.0.0.1:${socket.localPort}"
        Scruter.start(app, "ATMONA02", debug = true, endpoint = url, apiEndpoint = url)
        // A session samples Advanced analytics from the configuration it finds: let the first answer arrive.
        while (!configured) Thread.sleep(20)
        Thread.sleep(300)

        // Home hosts a fragment: the fragment is the screen.
        val home = Robolectric.buildActivity(HomeActivity::class.java).setup()
        idle(300)
        val list = home.get().findViewById<RecyclerView>(R.id.products)
        list.measure(View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY))
        list.layout(0, 0, 400, 600)
        idle()
        tap(home.get(), list.findViewHolderForAdapterPosition(1)!!.itemView)
        idle(1200)
        home.pause()

        // The checkout, from layouts: a masked customer, a form by keyed tag, a password field, a Material error.
        val checkout = Robolectric.buildActivity(CheckoutActivity::class.java).setup()
        idle(300)
        val a = checkout.get()
        a.findViewById<EditText>(R.id.postal_code).requestFocus()
        idle()
        a.findViewById<EditText>(R.id.postal_code).setText("75011")
        a.findViewById<EditText>(R.id.account_key).requestFocus()
        a.findViewById<EditText>(R.id.account_key).setText("hunter2")
        idle()
        tap(a, a.findViewById<CheckBox>(R.id.terms))
        idle(600)
        a.findViewById<Button>(R.id.pay).performClick()
        idle()
        checkout.pause().stop().destroy()
        home.resume()
        idle(300)
        home.pause()

        // Navigation Compose.
        val compose = Robolectric.buildActivity(ComposeShopActivity::class.java).setup()
        idle(500)
        compose.pause().stop().destroy()
        home.stop()
        idle(300)

        val all = drain()
        assertTrue(all.isNotEmpty())
        all.forEachIndexed { i, b -> write("journey-$i", b) }
        val events = all.flatMap { objects(it.optJSONArray("e")) }
        val screens = events.filter { it.getString("k") == "screen" }.map { it.getString("n") }
        assertEquals(listOf("Catalog", "Checkout", "Catalog", "shop"), screens)
        val revenue = events.first { it.getString("k") == "event" && it.getString("n") == "Order placed" }
        assertEquals("EUR", revenue.getJSONObject("$").getString("c"))
        val text = all.joinToString("") { it.toString() }
        assertFalse(text.contains("75011"))
        assertFalse(text.contains("hunter2"))
        assertFalse(text.contains("Morgan"))
        assertFalse(text.contains("account_key"))

        val views = all.flatMap { objects(it.optJSONArray("x")) }
        val catalogTaps = views.filter { it.getString("n") == "Catalog" }.flatMap { v ->
            val c = v.optJSONArray("c")
            if (c == null) emptyList() else (0 until c.length()).map { c.getJSONArray(it) }
        }
        assertTrue(views.toString(), catalogTaps.isNotEmpty())
        assertEquals("#products/TextView", catalogTaps.first().getString(0))
        assertEquals(1, catalogTaps.first().getInt(1))
        val form = views.first { it.getString("n") == "Checkout" && it.has("f") }.getJSONArray("f").getJSONObject(0)
        assertEquals("Delivery", form.getString("s"))
        assertEquals(1, form.getInt("ok"))
        val keys = (0 until form.getJSONArray("fd").length()).map { form.getJSONArray("fd").getJSONArray(it).getString(0) }
        assertEquals(listOf("postal_code", "email", "terms"), keys)
    }

    private fun write(name: String, b: JSONObject) {
        val dir = System.getProperty("scruter.conformanceOut") ?: return
        File(dir).mkdirs()
        File(dir, "batch--$name-api${android.os.Build.VERSION.SDK_INT}.json").writeText(b.toString(2))
    }
}
