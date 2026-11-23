package net.scruter.cmp.internal

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import java.io.File
import java.security.MessageDigest

/**
 * The banner's media and the app's icon (docs/CMP-MOBILE.md §2.4): fetched once and cached with the configuration in
 * the no-backup directory, decoded off the main thread at the size the sheet draws them. Only files of the
 * configuration's own origin are fetched (cdn.scruter.net): a configuration never makes the app load another server.
 */
internal class Media(private val dir: File, private val origins: () -> List<String>) {
    /** Removes the files no configuration names any more (a new banner version replaced them). */
    fun keepOnly(urls: Collection<String>) {
        val keep = urls.map { name(it) }.toSet()
        dir.listFiles()?.forEach { if (it.name !in keep && !it.name.endsWith(".part")) it.delete() }
    }

    fun cached(url: String): File? = File(dir, name(url)).takeIf { it.isFile && it.length() > 0 }

    /** The cached file of [url], downloaded first when needed (at most [max] bytes); null when it cannot be had. */
    fun file(url: String, max: Long): File? {
        cached(url)?.let { return it }
        if (!allowed(url)) {
            Log.w("media outside the configuration's origin ignored: $url")
            return null
        }
        val f = File(dir, name(url))
        return if (Net.download(url, f, max)) f else null
    }

    fun allowed(url: String): Boolean = origins().any { o -> o.isNotEmpty() && (url.startsWith("$o/") || url == o) }

    /** A bitmap of [file] at least [targetWidth] pixels wide when the image allows, sampled down otherwise. */
    fun decode(file: File, targetWidth: Int): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= targetWidth && targetWidth > 0) sample *= 2
        BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
    } catch (e: OutOfMemoryError) {
        null
    } catch (e: RuntimeException) {
        null
    }

    companion object {
        /** File name of a URL: its SHA-256 and its extension (the media URLs are content-addressed already). */
        fun name(url: String): String {
            val ext = url.substringAfterLast('.', "").substringBefore('?').takeIf { it.length in 2..4 && it.all(Char::isLetterOrDigit) } ?: "bin"
            val d = MessageDigest.getInstance("SHA-256").digest(url.toByteArray())
            return d.take(16).joinToString("") { "%02x".format(it.toInt() and 0xFF) } + "." + ext
        }

        /** Image types this Android decodes: AVIF from Android 12, WebP and JPEG everywhere. */
        fun decodable(type: String): Boolean = when {
            type.startsWith("image/avif") -> Build.VERSION.SDK_INT >= 31
            type.startsWith("image/webp") || type.startsWith("image/jpeg") || type.startsWith("image/png") -> true
            else -> false
        }

        /**
         * The poster of the format nearest above [widthPx] (docs/CMP-MOBILE.md §2.4), the lighter format first among
         * equal widths (the configuration lists AVIF, then WebP, then JPEG).
         */
        fun poster(sources: List<Hero.Source>, widthPx: Int): Hero.Source? = nearest(sources.filter { decodable(it.type) }, widthPx)

        /** The H.264 MP4 the platform's `MediaPlayer` plays everywhere (AV1 and VP9 are not on every Android 7). */
        fun video(sources: List<Hero.Source>, widthPx: Int): Hero.Source? =
            nearest(sources.filter { it.type.startsWith("video/mp4") && (it.type.contains("avc1") || !it.type.contains("codecs")) }, widthPx)

        fun nearest(sources: List<Hero.Source>, widthPx: Int): Hero.Source? {
            if (sources.isEmpty()) return null
            val above = sources.filter { it.w >= widthPx }
            return if (above.isNotEmpty()) above.minByOrNull { it.w } else sources.maxByOrNull { it.w }
        }
    }
}
