package net.scruter.internal

import android.app.Activity
import android.content.Intent
import android.net.Uri
import org.json.JSONObject

/**
 * How a session opened (docs/MOBILE.md §3.13): icon, notification, link, widget, shortcut, other. For a link the SDK
 * keeps only its scheme, host, path and utm_* values (the server would drop the rest anyway: a magic-link token never
 * leaves the phone); the referring app when Android gives it.
 */
internal object Openings {
    fun of(intent: Intent?, referrer: Uri?, notified: Boolean, packageName: String, teamScheme: String): JSONObject {
        val o = JSONObject()
        val data = intent?.data
        val widget = data?.getQueryParameterSafe("scruter_open") ?: intent?.getStringExtra("scruter_open")
        val kind = when {
            notified || intent?.hasExtra("google.message_id") == true || intent?.hasExtra("gcm.notification.title") == true -> "notification"
            widget == "widget" || intent?.action == "android.appwidget.action.APPWIDGET_UPDATE" -> "widget"
            widget == "shortcut" || intent?.hasExtra("android.intent.extra.shortcut.ID") == true -> "shortcut"
            data != null && intent.action == Intent.ACTION_VIEW && data.scheme != teamScheme -> "link"
            intent == null || intent.action == Intent.ACTION_MAIN || intent.action == null -> "icon"
            else -> "other"
        }
        o.put("k", kind)
        if (kind == "link" && data != null) o.put("u", link(data))
        val r = referrer?.toString()
        if (r != null && r != "android-app://$packageName") Text.clean(r, 200)?.let { o.put("r", it) }
        return o
    }

    /**
     * A segment that is not a word of the app's: an e-mail address, a number, a UUID, an opaque token (docs/MOBILE.md
     * §3.13; the same rule as the server's and iOS's, with the same table in their tests).
     */
    fun personal(segment: String): Boolean {
        if (segment.isEmpty()) return false
        if (segment.length > 64 || segment.contains('@')) return true
        val digits = segment.count { it in '0'..'9' }
        if (digits == segment.length || digits >= 6) return true
        val hex = segment.filter { it != '-' }
        if (hex.length == 32 && hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return true
        var run = 0
        var runHasDigit = false
        for (c in segment) {
            val digit = c in '0'..'9'
            if (digit || c in 'a'..'z' || c in 'A'..'Z') {
                run++
                runHasDigit = runHasDigit || digit
                if (run >= 32 || (run >= 16 && runHasDigit)) return true
            } else {
                run = 0
                runHasDigit = false
            }
        }
        return false
    }

    /** A decoded path with its personal segments replaced. */
    fun maskedPath(path: String): String = path.split('/').joinToString("/") { if (personal(it)) MASKED else it }

    /** scheme://host/path?utm_*=…, ≤ 2 000 characters, the path without its personal segments. */
    fun link(uri: Uri): String {
        val b = StringBuilder()
        // A custom scheme's host is the app's first word, not a server: `app://jane@x.com`.
        val web = uri.scheme?.lowercase() == "http" || uri.scheme?.lowercase() == "https"
        val host = uri.host?.let { if (!web && personal(it)) "id" else it }
        b.append(uri.scheme ?: "").append("://").append(host ?: "").append(uri.path?.let(::maskedPath) ?: "")
        val utm = try {
            uri.queryParameterNames.filter { it.startsWith("utm_") }
        } catch (e: UnsupportedOperationException) {
            emptyList()
        }
        var sep = '?'
        for (k in utm) {
            val v = uri.getQueryParameter(k) ?: continue
            b.append(sep).append(k).append('=').append(Uri.encode(v))
            sep = '&'
        }
        return Text.cut(b.toString(), 2000)
    }

    private const val MASKED = ":id"

    private fun Uri.getQueryParameterSafe(k: String): String? = try {
        if (isHierarchical) getQueryParameter(k) else null
    } catch (e: Exception) {
        null
    }

    fun referrerOf(a: Activity): Uri? = try {
        a.referrer
    } catch (e: Exception) {
        null
    }
}
