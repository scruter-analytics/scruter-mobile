package net.scruter.cmp.internal

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * HTTP for the CMP (worker thread only): the platform's `HttpURLConnection`, a neutral User-Agent (never the
 * platform's, which names the phone's build), short timeouts, no cookie, no redirect.
 */
internal object Net {
    class Response(val code: Int, val body: String, val retryAfter: Long, val etag: String?) {
        val ok: Boolean get() = code in 200..299
    }

    val FAILED = Response(-1, "", -1, null)

    @Volatile
    var userAgent: String = "Scruter-CMP-Android"

    private fun open(url: String, method: String, headers: Map<String, String>, timeout: Int = 15_000): HttpURLConnection {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = timeout
        conn.readTimeout = timeout * 2
        conn.useCaches = false
        conn.instanceFollowRedirects = false
        conn.setRequestProperty("User-Agent", userAgent)
        for ((k, v) in headers) conn.setRequestProperty(k, v)
        return conn
    }

    fun send(method: String, url: String, body: ByteArray? = null, headers: Map<String, String> = emptyMap(), timeout: Int = 15_000): Response {
        var conn: HttpURLConnection? = null
        return try {
            conn = open(url, method, headers + ("Accept" to "application/json"), timeout)
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setFixedLengthStreamingMode(body.size)
                conn.outputStream.use { it.write(body) }
            }
            val code = conn.responseCode
            val stream: InputStream? = if (code >= 400) conn.errorStream else conn.inputStream
            val text = stream?.use { readLimited(it, 1024 * 1024) } ?: ""
            Response(code, text, retryAfter(conn.getHeaderField("Retry-After")), conn.getHeaderField("ETag"))
        } catch (e: IOException) {
            Log.d("network error: ${e.javaClass.simpleName}")
            FAILED
        } catch (e: RuntimeException) {
            Log.w("network error", e)
            FAILED
        } finally {
            conn?.disconnect()
        }
    }

    /** Downloads [url] into [dest] (through a temporary file), at most [max] bytes. */
    fun download(url: String, dest: File, max: Long): Boolean {
        var conn: HttpURLConnection? = null
        val tmp = File(dest.parentFile, dest.name + ".part")
        return try {
            conn = open(url, "GET", emptyMap())
            if (conn.responseCode != 200) return false
            dest.parentFile?.mkdirs()
            var total = 0L
            conn.inputStream.use { input ->
                tmp.outputStream().use { out ->
                    val buf = ByteArray(16 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > max) throw IOException("too large")
                        out.write(buf, 0, n)
                    }
                }
            }
            tmp.renameTo(dest)
        } catch (e: IOException) {
            Log.d("download failed: ${e.javaClass.simpleName}")
            tmp.delete()
            false
        } catch (e: RuntimeException) {
            tmp.delete()
            false
        } finally {
            conn?.disconnect()
        }
    }

    private fun readLimited(input: InputStream, max: Int): String {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (out.size() < max) {
            val n = input.read(buf)
            if (n < 0) break
            out.write(buf, 0, minOf(n, max - out.size()))
        }
        return out.toString("UTF-8")
    }

    /** `Retry-After` in seconds → ms (Scruter's servers send seconds), −1 when absent, at most an hour. */
    fun retryAfter(value: String?): Long {
        val s = value?.trim()?.toLongOrNull() ?: return -1
        return if (s < 0) -1 else minOf(s, 3600) * 1000
    }

    fun enc(v: String): String = java.net.URLEncoder.encode(v, "UTF-8")
}
