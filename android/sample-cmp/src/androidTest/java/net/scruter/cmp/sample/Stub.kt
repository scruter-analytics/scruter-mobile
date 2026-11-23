package net.scruter.cmp.sample

import android.content.Context
import android.os.Bundle
import androidx.test.runner.AndroidJUnitRunner
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Starts the stub of the ingest before the app's `Application.onCreate` (the CMP fetches its configuration from its
 * first line): the instrumented tests run in the app's own process, the stub listens on 127.0.0.1:8787, the
 * `scruter.cmpEndpoint` of the build.
 */
class StubRunner : AndroidJUnitRunner() {
    override fun onCreate(arguments: Bundle?) {
        // The test APK's own assets: the protocol kit's bodies and the language packs. `-e tcf true`: the run of the IAB
        // TCF (TcfFlowTest), whose configuration has the TCF from the first launch.
        Stub.start(context, arguments?.getString("tcf") == "true")
        super.onCreate(arguments)
    }
}

/**
 * The stub: serves the protocol kit's golden configuration (`sdk/protocol/cmp/bodies/config.json`) pointed at itself, an
 * English and a German language pack, the media, the SDK catalogue; records every beacon.
 */
object Stub {
    const val PORT = 8787
    const val URL = "http://127.0.0.1:$PORT"

    class Req(val method: String, val path: String, val body: String) {
        fun json(): JSONObject = JSONObject(body)
    }

    val requests = LinkedBlockingQueue<Req>()
    val all: MutableList<Req> = Collections.synchronizedList(ArrayList())

    @Volatile
    var config = ""
    private lateinit var assets: android.content.res.AssetManager

    @Volatile
    var tcf = false

    fun start(test: Context, tcf: Boolean = false) {
        if (config.isNotEmpty()) return
        assets = test.assets
        this.tcf = tcf
        config = read(if (tcf) "config-tcf.json" else "config.json").replace("https://cdn.scruter.net", URL)
        val socket = ServerSocket(PORT, 50, InetAddress.getByName("127.0.0.1"))
        Thread {
            while (true) {
                val s = try {
                    socket.accept()
                } catch (e: Exception) {
                    break
                }
                Thread { s.use { serve(it) } }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
    }

    private fun read(name: String) = assets.open(name).use { it.readBytes().toString(Charsets.UTF_8) }

    private fun line(input: InputStream): String {
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
        val first = line(input).split(" ")
        if (first.size < 2) return
        var length = 0
        while (true) {
            val h = line(input)
            if (h.isEmpty()) break
            if (h.lowercase().startsWith("content-length:")) length = h.substringAfter(':').trim().toInt()
        }
        val raw = ByteArray(length)
        var n = 0
        while (n < length) {
            val r = input.read(raw, n, length - n)
            if (r < 0) break
            n += r
        }
        val path = first[1].substringBefore('?')
        val req = Req(first[0], path, String(raw, Charsets.UTF_8))
        requests.add(req)
        all.add(req)
        val (code, body) = when {
            path == "/m/v1/cmp" -> 200 to config
            path.startsWith("/m/v1/cmp/sdks/") -> 200 to """{"v":1,"sdks":[{"k":"jetpack_compose","android":["androidx.compose.runtime.Composer"]},{"k":"appsflyer","android":["com.appsflyer.AppsFlyerLib"]}]}"""
            path == "/m/v1/cmp/sdks" || path == "/cmp/hit" || path == "/cmp/consent" -> 202 to "{}"
            path.matches(Regex("/cmp/[A-Z0-9]+/texts-\\d+-(en|de)\\.json")) -> 200 to read("pack-" + path.substringAfterLast('-'))
            path.matches(Regex("/cmp/[A-Z0-9]+/vendors-\\d+\\.json")) -> 200 to read("vendors-186.json")
            path.matches(Regex("/cmp/tcf/\\d+/(fr|de)\\.json")) -> 200 to read("186-" + path.substringAfterLast('/'))
            else -> 404 to "{}"
        }
        val bytes = body.toByteArray()
        val out = s.getOutputStream()
        out.write("HTTP/1.1 $code X\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(bytes)
        out.flush()
    }

    /** The next request to [path] that [where] accepts (a previous test's proof may still be on its way). */
    fun next(path: String, seconds: Long = 15, where: (JSONObject) -> Boolean = { true }): Req {
        val end = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < end) {
            val r = requests.poll(100, TimeUnit.MILLISECONDS) ?: continue
            if (r.path == path && where(r.json())) return r
        }
        throw AssertionError("no request to $path")
    }

    /** The next proof of [action]. */
    fun proof(action: String): JSONObject = next("/cmp/consent") { it.optString("c") == action }.json()
}
