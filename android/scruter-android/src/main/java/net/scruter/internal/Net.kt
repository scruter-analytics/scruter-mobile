package net.scruter.internal

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPOutputStream

/**
 * HTTP for the SDK (worker thread only): `HttpURLConnection` from the platform, a neutral User-Agent (never the
 * platform's, which names the phone's build), short timeouts, no cookie.
 */
internal object Net {
    class Response(val code: Int, val body: String, val retryAfter: Long, val etag: String?) {
        val ok: Boolean get() = code in 200..299
    }

    /** A network failure: the caller retries. */
    val FAILED = Response(-1, "", -1, null)

    @Volatile
    var userAgent: String = "Scruter-Android"

    fun send(
        method: String,
        url: String,
        body: ByteArray? = null,
        contentType: String? = null,
        headers: Map<String, String> = emptyMap(),
    ): Response {
        var conn: HttpURLConnection? = null
        return try {
            conn = URL(url).openConnection() as HttpURLConnection
            conn.requestMethod = method
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.useCaches = false
            conn.instanceFollowRedirects = false
            conn.setRequestProperty("User-Agent", userAgent)
            conn.setRequestProperty("Accept", "application/json")
            for ((k, v) in headers) conn.setRequestProperty(k, v)
            if (body != null) {
                conn.doOutput = true
                if (contentType != null) conn.setRequestProperty("Content-Type", contentType)
                conn.setFixedLengthStreamingMode(body.size)
                conn.outputStream.use { it.write(body) }
            }
            val code = conn.responseCode
            val stream: InputStream? = if (code >= 400) conn.errorStream else conn.inputStream
            val text = stream?.use { readLimited(it, 256 * 1024) } ?: ""
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

    /** `Retry-After` in seconds → ms (the HTTP-date form is not used by Scruter's servers), −1 when absent. */
    fun retryAfter(value: String?): Long {
        val s = value?.trim()?.toLongOrNull() ?: return -1
        return if (s < 0) -1 else minOf(s, 3600) * 1000
    }

    fun gzip(data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(data.size / 4 + 64)
        GZIPOutputStream(out).use { it.write(data) }
        return out.toByteArray()
    }

    /** A `multipart/form-data` body: parts of (name, file name or null, content type, bytes). */
    class Multipart {
        val boundary = "scruter-" + Text.randomHex(12)
        private val out = ByteArrayOutputStream()

        fun part(name: String, fileName: String?, type: String, data: ByteArray): Multipart {
            val disposition = "form-data; name=\"$name\"" + (fileName?.let { "; filename=\"$it\"" } ?: "")
            out.write("--$boundary\r\nContent-Disposition: $disposition\r\nContent-Type: $type\r\n\r\n".toByteArray())
            out.write(data)
            out.write("\r\n".toByteArray())
            return this
        }

        fun build(): ByteArray {
            out.write("--$boundary--\r\n".toByteArray())
            return out.toByteArray()
        }

        val contentType: String get() = "multipart/form-data; boundary=$boundary"
    }
}
