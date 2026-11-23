package net.scruter.internal

import android.app.Application
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import net.scruter.Scruter
import org.json.JSONObject
import org.robolectric.Shadows.shadowOf
import java.io.ByteArrayInputStream
import java.io.Closeable
import java.io.File
import java.io.BufferedInputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream

/** A local stand-in for the ingest and the api (docs/API.md §5.3): records requests, answers as scripted. */
class FakeServer : Closeable {
    class Req(val method: String, val path: String, val query: String?, val headers: Map<String, String>, val raw: ByteArray) {
        val body: ByteArray =
            if (headers["content-encoding"] == "gzip") GZIPInputStream(ByteArrayInputStream(raw)).readBytes() else raw
        fun json(): JSONObject = JSONObject(String(body, Charsets.UTF_8))
    }

    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    val requests = LinkedBlockingQueue<Req>()

    @Volatile
    var config = """{"v":1,"on":1,"e":"e1","tz":"Europe/Paris","aa":100,"cr":1,"xs":["Debug*"],"tp":1,"ttl":3600}"""

    @Volatile
    var batch: (Req) -> Pair<Int, String> = { 202 to "{}" }

    @Volatile
    var teamConfig = """{"phone_id":"p1","captured":[],"retake":[],"max_bytes":2000000,"max_height":10000,"ttl":600}"""

    @Volatile
    var teamConfigStatus = 200

    val url: String get() = "http://127.0.0.1:${socket.localPort}"

    init {
        Thread {
            while (!socket.isClosed) {
                val s = try {
                    socket.accept()
                } catch (e: Exception) {
                    break
                }
                Thread { s.use { serve(it) } }.start()
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
        val target = line[1]
        val path = target.substringBefore('?')
        val query = if (target.contains('?')) target.substringAfter('?') else null
        val req = Req(line[0], path, query, headers, raw)
        requests.add(req)
        val (code, body) = when (path) {
            "/m/v1/config" -> 200 to config
            "/m/v1/batch" -> batch(req)
            "/m/v1/team/register" -> 201 to """{"phone_id":"p1","device_token":"scr_tp_${"a".repeat(43)}","name":"Pixel 8"}"""
            "/m/v1/team/config" -> teamConfigStatus to teamConfig
            "/m/v1/team/screens" -> 202 to """{"id":"img1"}"""
            else -> 404 to """{"error":{"code":"not_found","message":"no"}}"""
        }
        val bytes = body.toByteArray()
        val out = s.getOutputStream()
        val extra = if (code == 503 || code == 429) "Retry-After: 1\r\n" else ""
        out.write(("HTTP/1.1 $code X\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\n" +
            "${extra}Connection: close\r\n\r\n").toByteArray())
        out.write(bytes)
        out.flush()
    }

    fun next(path: String, seconds: Long = 10): Req {
        val end = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < end) {
            val r = requests.poll(100, TimeUnit.MILLISECONDS) ?: continue
            if (r.path == path) return r
        }
        throw AssertionError("no request to $path")
    }

    /** The next batch that has [key] (an early "first screen" flush may come before). */
    fun batchWith(key: String, seconds: Long = 10): JSONObject {
        val end = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < end) {
            val b = next("/m/v1/batch", seconds).json()
            if (b.has(key)) return b
        }
        throw AssertionError("no batch with $key")
    }

    fun none(path: String, millis: Long = 500): Boolean {
        val end = System.currentTimeMillis() + millis
        while (System.currentTimeMillis() < end) {
            val r = requests.poll(50, TimeUnit.MILLISECONDS) ?: continue
            if (r.path == path) return false
        }
        return true
    }

    override fun close() {
        socket.close()
    }
}

/** Starts and stops the SDK around a test, against a [FakeServer]. */
internal object Sdk {
    val app: Application get() = ApplicationProvider.getApplicationContext()

    fun start(server: FakeServer, debugKey: String? = null): Engine {
        Scruter.start(app, "ATMONA02", debugKey = debugKey, debug = true, endpoint = server.url, apiEndpoint = server.url)
        val e = Scruter.engine()!!
        worker(e)
        idle()
        return e
    }

    /** Waits until the worker has run everything posted so far. */
    fun worker(e: Engine) {
        repeat(2) {
            val l = CountDownLatch(1)
            e.handler.post { l.countDown() }
            check(l.await(20, TimeUnit.SECONDS)) { "worker stuck" }
        }
    }

    /** Runs the main looper (and its frame callbacks) for [ms]. */
    fun idle(ms: Long = 50) {
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    }

    fun stop() {
        val e = Scruter.engine()
        if (e != null) {
            worker(e)
            e.handler.looper.quitSafely()
        }
        Scruter.resetForTests()
        BridgeState.inspector = null
        Crashes.mutedUntil = 0
        Thread.setDefaultUncaughtExceptionHandler(null)
    }
}

/** Writes payloads for the protocol kit's validator (sdk/android/scripts/conformance.sh). */
internal object Conformance {
    private val dir: File? = System.getProperty("scruter.conformanceOut")?.let { File(it).apply { mkdirs() } }

    fun write(schema: String, name: String, json: JSONObject) {
        val d = dir ?: return
        File(d, "$schema--$name.json").writeText(json.toString(2))
    }

    fun batch(name: String, json: JSONObject) = write("batch", name, json)

    /** A crash report inside a minimal batch, to validate it against the batch schema. */
    fun crash(name: String, report: JSONObject) {
        val s = JSONObject("""{"id":"${report.getString("s")}","d":"${"0".repeat(32)}","q":1,"st":1762345000000,
            "p":"android","av":"1.0","bk":"release","os":"15","m":"Google Pixel 8","f":"phone",
            "c":{"sv":1,"ev":0,"dur":3,"cr":1,"anr":0,"last":1762345000000}}""")
        val b = JSONObject().put("v", 1).put("a", "ATMONA02").put("b", "0".repeat(32)).put("t", 1762345678901L)
            .put("s", org.json.JSONArray().put(s)).put("cr", org.json.JSONArray().put(report))
        write("batch", "crash-$name", b)
    }
}
