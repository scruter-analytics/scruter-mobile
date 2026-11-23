package net.scruter.internal

import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import net.scruter.R
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Team phones (docs/MOBILE.md §3.12): a phone added by QR code (any build: test builds are release builds) or a debug
 * build started with the app's debug key. A team phone's sessions are flagged `tm = 1` (never counted) and it takes
 * the screen images of Screen analysis: once per screen, version, platform and form factor, retaken in a new version
 * or when the console asks. A user's phone is never one: no key, no QR code, no image.
 */
internal class Team(private val engine: Engine) {
    @Volatile
    var active = false
        private set

    @Volatile
    private var token: String? = null
    private val lock = Any()
    private var captured: Set<String> = emptySet()
    private var retake: Set<String> = emptySet()
    private var maxBytes = 2_000_000
    private var maxHeight = 10_000
    private var configAt = 0L
    private var configTtl = 600_000L
    private val takenThisRun = HashSet<String>()

    @Volatile
    private var imagesOff = false

    // ------------------------------------------------------------------------------------------------ registration

    fun start() {
        val store = engine.store ?: return
        token = store.get(K_TOKEN)?.let { SecureToken.open(it) }
        active = token != null
        val key = engine.options.debugKey
        if (!active && key != null) {
            if (!engine.env.debuggable) {
                Log.d("debug key ignored: this is not a debug build")
            } else if (!KEY.matches(key)) {
                Log.d("debug key ignored: not a scr_dbg_ key")
            } else {
                register(JSONObject().put("debug_key", key), "debug", fromLink = false)
            }
        }
        if (active) fetchConfig()
    }

    /** The registration code of `scruter-<app id>://team?t=scr_qr_…` (the console's QR code), if it is one. */
    fun codeOf(uri: Uri): String? {
        val t = try {
            uri.getQueryParameter("t")
        } catch (e: Exception) {
            null
        }
        return t?.takeIf { uri.host == "team" && QR.matches(it) }
    }

    /** After the person holding the phone said yes: a link alone never makes it a team phone. */
    fun registerWithLink(uri: Uri) {
        if (engine.store == null) return
        val t = codeOf(uri)
        if (t == null) {
            Log.d("team link ignored: not a registration code")
            return
        }
        register(JSONObject().put("token", t), engine.env.buildKind, fromLink = true)
    }

    private fun register(auth: JSONObject, buildKind: String, fromLink: Boolean) {
        val env = engine.env
        val body = auth.put("app", engine.options.appId).put("platform", "android").put("model", env.model)
            .put("os", env.os).put("form", env.form).put("app_version", env.versionName).put("build_kind", buildKind)
        val res = Net.send("POST", "${engine.options.apiEndpoint}/m/v1/team/register",
            body.toString().toByteArray(Charsets.UTF_8), "application/json")
        if (res.ok) {
            val o = try {
                JSONObject(res.body)
            } catch (e: Exception) {
                null
            }
            val t = o?.optString("device_token")?.takeIf { DEVICE.matches(it) }
            if (t != null) {
                save(t)
                Log.d("this phone is a team phone (${o.optString("name")})")
                if (fromLink) toast(R.string.scruter_team_added)
                engine.markTeamPhone()
                fetchConfig()
                return
            }
        }
        Log.d("team registration refused (${res.code})")
        if (fromLink) toast(if (res.code == -1 || res.code >= 500 || res.code == 429) R.string.scruter_team_unreachable else R.string.scruter_team_expired)
    }

    private fun save(t: String) {
        token = t
        active = true
        val sealed = SecureToken.seal(t)
        engine.store?.put(K_TOKEN, sealed)
    }

    /** Revoked (`401`), opted out: the phone leaves team mode and forgets its token. */
    fun forget() {
        token = null
        active = false
        engine.store?.put(K_TOKEN, null)
        SecureToken.delete()
    }

    private fun toast(res: Int) {
        val ctx = engine.context
        Handler(Looper.getMainLooper()).post {
            try {
                Toast.makeText(ctx, ctx.getString(res), Toast.LENGTH_LONG).show()
            } catch (e: Exception) {
                Log.d("toast: ${e.javaClass.simpleName}")
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ configuration

    fun configChanged() {
        if (active && engine.config.teamImages) fetchConfig()
    }

    private fun fetchConfig() {
        val t = token ?: return
        val env = engine.env
        val url = "${engine.options.apiEndpoint}/m/v1/team/config?av=${Uri.encode(env.versionName)}&p=android&f=${env.form}"
        val res = Net.send("GET", url, headers = mapOf("Authorization" to "Bearer $t"))
        when {
            res.ok -> try {
                val o = JSONObject(res.body)
                synchronized(lock) {
                    captured = strings(o, "captured")
                    retake = strings(o, "retake")
                    maxBytes = o.optInt("max_bytes", 2_000_000).coerceIn(100_000, 2_000_000)
                    maxHeight = o.optInt("max_height", 10_000).coerceIn(1_000, 10_000)
                    configTtl = o.optInt("ttl", 600).coerceIn(60, 86_400) * 1000L
                    configAt = System.currentTimeMillis()
                }
            } catch (e: Exception) {
                Log.d("team configuration unreadable")
            }
            res.code == 401 -> forget()
            res.code == 403 -> imagesOff = true
        }
    }

    private fun strings(o: JSONObject, key: String): Set<String> {
        val a = o.optJSONArray(key) ?: return emptySet()
        val out = HashSet<String>()
        for (i in 0 until a.length()) out.add(a.optString(i))
        return out
    }

    // ------------------------------------------------------------------------------------------------ images

    /** Main thread: a screen appeared. Captures it when the server has no image of it for this version. */
    fun onScreen(name: String) {
        val limits = wanted(name) ?: return
        val ui = net.scruter.Scruter.ui() ?: return
        Capture(ui, name, limits[0], limits[1]) { jpeg, tree, width, height, scale ->
            engine.post { upload(name, jpeg, tree, width, height, scale) }
        }.schedule()
    }

    /**
     * Whether the screen [name] is to be captured now (at most once per process run): the limits `[bytes, height]`,
     * or null. Never true on a user's phone: only a team phone is [active].
     */
    fun wanted(name: String): IntArray? {
        if (!active || imagesOff || !engine.config.teamImages) return null
        val need: Boolean
        val limits: IntArray
        synchronized(lock) {
            need = (name in retake || name !in captured) && name !in takenThisRun
            limits = intArrayOf(maxBytes, maxHeight)
            if (need) takenThisRun.add(name)
        }
        if (System.currentTimeMillis() - configAt > configTtl) engine.post { fetchConfig() }
        return if (need) limits else null
    }

    fun upload(name: String, jpeg: ByteArray, tree: JSONObject, width: Int, height: Int, scale: Float) {
        val t = token ?: return
        val env = engine.env
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.ROOT)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        val meta = JSONObject().put("screen", name).put("app_version", env.versionName).put("platform", "android")
            .put("form", env.form).put("width", width).put("height", height).put("scale", scale.toDouble())
            .put("taken_at", fmt.format(Date())).put("model", env.model).put("os", env.os)
        val body = Net.Multipart()
            .part("meta", null, "application/json", meta.toString().toByteArray(Charsets.UTF_8))
            .part("image", "screen.jpg", "image/jpeg", jpeg)
            .part("tree", null, "application/json", tree.toString().toByteArray(Charsets.UTF_8))
        val res = Net.send("POST", "${engine.options.apiEndpoint}/m/v1/team/screens", body.build(), body.contentType,
            mapOf("Authorization" to "Bearer $t"))
        when {
            res.ok -> {
                Log.d("screen image of \"$name\" sent (${jpeg.size / 1024} KB, ${tree.getJSONArray("nodes").length()} elements)")
                synchronized(lock) {
                    captured = captured + name
                    retake = retake - name
                }
            }
            res.code == 401 -> forget()
            res.code == 403 -> imagesOff = true
            else -> {
                Log.d("screen image of \"$name\" not sent (${res.code})")
                synchronized(lock) { takenThisRun.remove(name) }
            }
        }
    }

    companion object {
        const val K_TOKEN = "team_token"
        val QR = Regex("^scr_qr_[A-Za-z0-9_-]{32}$")
        val KEY = Regex("^scr_dbg_[A-Za-z0-9_-]{43}$")
        val DEVICE = Regex("^scr_tp_[A-Za-z0-9_-]{43}$")
    }
}
