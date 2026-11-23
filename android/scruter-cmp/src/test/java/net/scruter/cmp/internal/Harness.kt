package net.scruter.cmp.internal

import android.app.Activity
import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.os.Bundle
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import net.scruter.cmp.ConsentState
import net.scruter.cmp.Presentation
import net.scruter.cmp.ScruterCMP
import org.json.JSONArray
import org.json.JSONObject
import org.robolectric.Shadows.shadowOf
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * A local stand-in for the ingest (docs/API.md §5.1 « Mobile apps »): serves the protocol kit's golden configuration
 * (`sdk/protocol/cmp/bodies/config.json`, its URLs pointed at itself), language packs, media and the SDK catalogue,
 * and records every beacon.
 */
class FakeIngest : Closeable {
    class Req(val method: String, val path: String, val query: String?, val headers: Map<String, String>, val body: ByteArray) {
        fun json(): JSONObject = JSONObject(String(body, Charsets.UTF_8))
    }

    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    val url: String get() = "http://127.0.0.1:${socket.localPort}"
    val requests = LinkedBlockingQueue<Req>()
    val all = java.util.Collections.synchronizedList(ArrayList<Req>())

    /** The configuration served (`config.json` with its URLs on this server). */
    @Volatile
    var config: String = golden()

    @Volatile
    var etag = "\"a-0123456789abcdef0123\""

    /** No answer at all: the connection closes (the phone is offline). */
    @Volatile
    var offline = false

    @Volatile
    var beaconCode = 202

    val packs = HashMap<String, String>()

    @Volatile
    var catalogue = """{"v":1,"sdks":[{"k":"junit","android":["org.junit.Test"]},{"k":"appsflyer","android":["com.appsflyer.AppsFlyerLib"]}]}"""

    fun golden(): String = Protocol.file("cmp/bodies/config.json").readText().replace("https://cdn.scruter.net", url)

    /** The golden configuration with the IAB TCF on (`config-tcf.json`, the kit's GVL 186 vendors). */
    fun goldenTcf(): String = Protocol.file("cmp/bodies/config-tcf.json").readText().replace("https://cdn.scruter.net", url)

    /** Edits the configuration served. */
    fun edit(block: (JSONObject) -> Unit) {
        val o = JSONObject(config)
        block(o)
        config = o.toString()
        etag = "\"a-" + Integer.toHexString(config.hashCode()).padStart(8, '0') + "000000000000\""
    }

    init {
        Thread {
            while (!socket.isClosed) {
                val s = try {
                    socket.accept()
                } catch (e: Exception) {
                    break
                }
                Thread { s.use { serve(it) } }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
    }

    private fun readLine(input: InputStream): String {
        val b = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0 || c == '\n'.code) break
            if (c != '\r'.code) b.append(c.toChar())
        }
        return b.toString()
    }

    private fun serve(s: Socket) {
        val input = BufferedInputStream(s.getInputStream())
        val line = readLine(input).split(" ")
        if (line.size < 2) return
        val headers = HashMap<String, String>()
        while (true) {
            val h = readLine(input)
            if (h.isEmpty()) break
            val i = h.indexOf(':')
            if (i > 0) headers[h.substring(0, i).trim().lowercase()] = h.substring(i + 1).trim()
        }
        val length = headers["content-length"]?.toInt() ?: 0
        val raw = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(raw, read, length - read)
            if (n < 0) break
            read += n
        }
        if (offline) return
        val target = line[1]
        val path = target.substringBefore('?')
        val req = Req(line[0], path, target.substringAfter('?', "").ifEmpty { null }, headers, raw)
        requests.add(req)
        all.add(req)
        var type = "application/json"
        var extra = ""
        val (code, body) = when {
            path == "/m/v1/cmp" -> {
                extra = "ETag: $etag\r\nCache-Control: public, max-age=300\r\n"
                if (headers["if-none-match"] == etag) 304 to ByteArray(0) else 200 to config.toByteArray()
            }
            path.startsWith("/m/v1/cmp/sdks/") -> 200 to catalogue.toByteArray()
            path == "/m/v1/cmp/sdks" || path == "/cmp/hit" || path == "/cmp/consent" -> beaconCode to "{}".toByteArray()
            path.matches(Regex("/cmp/[A-Z0-9]+/texts-\\d+-[a-z]+\\.json")) -> {
                val lang = path.substringAfterLast('-').removeSuffix(".json")
                packs[lang]?.let { 200 to it.toByteArray() } ?: (404 to "{}".toByteArray())
            }
            // The IAB TCF: the kit's vendor subset and IAB's translations (sdk/protocol/cmp/tcf).
            path.matches(Regex("/cmp/[A-Z0-9]+/vendors-\\d+\\.json")) -> 200 to Protocol.file("cmp/tcf/vendors-186.json").readBytes()
            path.matches(Regex("/cmp/tcf/\\d+/[a-z-]+\\.json")) -> {
                val f = Protocol.file("cmp/tcf/186-" + path.substringAfterLast('/'))
                if (f.isFile) 200 to f.readBytes() else 404 to "{}".toByteArray()
            }
            path.startsWith("/cmp/media/") -> {
                type = "image/jpeg"
                200 to Images.poster
            }
            path.startsWith("/cmp/assets/logos/") -> {
                type = "image/png"
                200 to Images.icon
            }
            else -> 404 to """{"error":{"code":"not_found"}}""".toByteArray()
        }
        val out = s.getOutputStream()
        val retry = if (code == 503 || code == 429) "Retry-After: 1\r\n" else ""
        out.write(("HTTP/1.1 $code X\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\n$extra$retry" + "Connection: close\r\n\r\n").toByteArray())
        out.write(body)
        out.flush()
    }

    fun next(path: String, seconds: Long = 10): Req {
        val end = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < end) {
            Sdk.idle(10)
            val r = requests.poll(20, TimeUnit.MILLISECONDS) ?: continue
            if (r.path == path) return r
        }
        throw AssertionError("no request to $path")
    }

    fun none(path: String, millis: Long = 600): Boolean {
        val end = System.currentTimeMillis() + millis
        while (System.currentTimeMillis() < end) {
            Sdk.idle(10)
            val r = requests.poll(20, TimeUnit.MILLISECONDS) ?: continue
            if (r.path == path) return false
        }
        return true
    }

    override fun close() {
        socket.close()
    }

    companion object {
        /** A German pack (formal register) and an Arabic one, as `GET /cmp/{code}/texts-{banner}-{lang}.json` serves them. */
        fun pack(lang: String): String = when (lang) {
            "de" -> JSONObject().put("lang", "de").put("dir", "ltr").put("hash", "d".repeat(64)).put("texts", JSONObject("""{
                "title":"Ihre Daten, Ihre Wahl","message":"Atelier Mona und seine Partner verwenden Tracker, um die Nutzung der App zu messen und Werbung zu personalisieren.",
                "accept_all":"Alle akzeptieren","reject_all":"Alle ablehnen","customize":"Anpassen","save":"Speichern","close":"Ohne Zustimmung fortfahren",
                "preferences_title":"Ihre Einstellungen","preferences_intro":"Wählen Sie.","floating_button":"Cookies verwalten","kicker":"Bevor Sie beginnen","policy_url":null,
                "purposes":{"necessary":{"name":"Notwendig","description":"Damit die App funktioniert und Ihre Wahl gespeichert bleibt."},
                "analytics":{"name":"Reichweitenmessung","description":"Verstehen, wie die App genutzt wird."},
                "advertising":{"name":"Werbung","description":"Werbung anzeigen, die Ihren Interessen entspricht."}}}""")).toString()
            "ar" -> JSONObject().put("lang", "ar").put("dir", "rtl").put("hash", "a".repeat(64)).put("texts", JSONObject("""{
                "title":"بياناتك، اختياراتك","message":"يستخدم أتيليه مونا وشركاؤه أدوات تتبّع لقياس استخدام التطبيق وتخصيص الإعلانات.",
                "accept_all":"قبول الكل","reject_all":"رفض الكل","customize":"تخصيص","save":"حفظ","close":"المتابعة دون قبول",
                "preferences_title":"تفضيلاتك","preferences_intro":"اختر.","floating_button":"إدارة ملفات تعريف الارتباط","kicker":"قبل أن تبدأ","policy_url":null,
                "purposes":{"necessary":{"name":"ضرورية","description":"لتشغيل التطبيق والاحتفاظ باختيارك."},
                "analytics":{"name":"قياس الجمهور","description":"فهم كيفية استخدام التطبيق."},
                "advertising":{"name":"الإعلانات","description":"عرض إعلانات تناسب اهتماماتك."}}}""")).toString()
            else -> throw IllegalArgumentException(lang)
        }
    }
}

/** The images the stub serves: a warm gradient « photo » and a round app icon, made at test time. */
object Images {
    val poster: ByteArray by lazy {
        val b = Bitmap.createBitmap(960, 540, Bitmap.Config.ARGB_8888)
        val c = Canvas(b)
        val p = Paint().apply { shader = LinearGradient(0f, 0f, 960f, 540f, Color.parseColor("#C98B5A"), Color.parseColor("#3E5C76"), Shader.TileMode.CLAMP) }
        c.drawRect(0f, 0f, 960f, 540f, p)
        val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#F3E3CF") }
        c.drawCircle(300f, 300f, 120f, dot)
        dot.color = Color.parseColor("#E7C39D")
        c.drawCircle(620f, 330f, 90f, dot)
        ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
    }
    val icon: ByteArray by lazy {
        val b = Bitmap.createBitmap(192, 192, Bitmap.Config.ARGB_8888)
        val c = Canvas(b)
        c.drawColor(Color.parseColor("#1F6F5C"))
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textSize = 110f; textAlign = Paint.Align.CENTER; isFakeBoldText = true }
        c.drawText("M", 96f, 135f, p)
        ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }
}

/** An app screen behind the sheet. */
class TestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply {
            text = "Atelier Mona — des bols qu’on a envie de garder."
            textSize = 24f
            setPadding(48, 160, 48, 48)
            setBackgroundColor(Color.parseColor("#FBF8F4"))
        })
    }
}

/** Starts and stops the CMP around a test. */
internal object Sdk {
    val app: Application get() = ApplicationProvider.getApplicationContext()

    fun start(server: FakeIngest, presentation: Presentation = Presentation.AUTOMATIC): Engine {
        ScruterCMP.debug = true
        ScruterCMP.start(app, "ATMONA02", presentation, server.url)
        val e = ScruterCMP.engine()!!
        worker(e)
        idle()
        return e
    }

    fun worker(e: Engine) {
        repeat(2) {
            val l = CountDownLatch(1)
            e.handler.post { l.countDown() }
            check(l.await(20, TimeUnit.SECONDS)) { "worker stuck" }
        }
    }

    fun idle(ms: Long = 50) {
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    }

    /** Runs the main looper and the worker until [cond] holds. */
    fun until(seconds: Long = 10, what: String = "condition", cond: () -> Boolean) {
        val end = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < end) {
            ScruterCMP.engine()?.let { worker(it) }
            idle(50)
            if (cond()) return
            Thread.sleep(10)
        }
        throw AssertionError("timed out waiting for $what")
    }

    fun stop() {
        val e = ScruterCMP.engine()
        if (e != null) worker(e)
        ScruterCMP.resetForTests()
        Log.sink = null
    }

    /** Forgets everything the CMP stored (a new install). */
    fun wipe() {
        app.getSharedPreferences(Engine.PREFS, 0).edit().clear().commit()
        app.getSharedPreferences(app.packageName + "_preferences", 0).edit().clear().commit()
        File(app.noBackupFilesDir, "scruter-cmp").deleteRecursively()
    }

    fun state(): ConsentState = ScruterCMP.state
}

/** Finding things in a window's views. */
internal object Views {
    fun all(root: View): List<View> {
        val out = ArrayList<View>()
        fun walk(v: View) {
            out.add(v)
            if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
        }
        walk(root)
        return out
    }

    fun text(root: View, text: String): TextView? = all(root).filterIsInstance<TextView>().firstOrNull { it.text.toString() == text }

    fun button(root: View, text: String): Button =
        all(root).filterIsInstance<Button>().firstOrNull { it.text.toString().trim() == text } ?: throw AssertionError("no button \"$text\"")

    fun click(root: View, text: String) {
        button(root, text).performClick()
    }

    fun hasText(root: View, text: String): Boolean = all(root).filterIsInstance<TextView>().any { it.text.toString().contains(text) }
}

/** Writes beacons for the protocol kit's validator (sdk/android/scripts/conformance.sh). */
internal object Conformance {
    private val dir: File? = System.getProperty("scruter.conformanceOut")?.let { File(it).apply { mkdirs() } }

    fun write(schema: String, name: String, json: JSONObject) {
        val d = dir ?: return
        File(d, "$schema--$name.json").writeText(json.toString(2))
    }
}

internal fun JSONArray.list(): List<String> = (0 until length()).map { getString(it) }
