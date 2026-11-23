package net.scruter.internal

import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import org.json.JSONObject

/**
 * Google Play Install Referrer (docs/MOBILE.md §3.13): read once on the first launch, retried at the next two launches
 * when the service is unavailable, sent once as `ins` with the raw referrer string (the server keeps its utm_* values;
 * click ids are dropped there). The click and install timestamps the API also returns are never read into a payload.
 */
internal object Referrer {
    private const val K_STATE = "referrer_state" // absent, "1", "2" (tries so far), "done"
    private const val K_PENDING = "referrer_pending" // the `ins` object waiting for a session

    fun start(engine: Engine) {
        val store = engine.store ?: return
        val state = store.get(K_STATE)
        if (state == "done") return
        val tries = state?.toIntOrNull() ?: 0
        val source = if (engine.env.installer == "com.android.vending") "google_play" else "other"
        val client = try {
            InstallReferrerClient.newBuilder(engine.context).build()
        } catch (e: Throwable) {
            finish(engine, JSONObject().put("src", source))
            return
        }
        try {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(code: Int) {
                    engine.post {
                        when (code) {
                            InstallReferrerClient.InstallReferrerResponse.OK -> {
                                val ref = try {
                                    client.installReferrer.installReferrer
                                } catch (e: Exception) {
                                    null
                                }
                                val ins = JSONObject().put("src", if (ref != null) "google_play" else source)
                                Text.clean(ref, 2000)?.let { ins.put("ref", it) }
                                finish(engine, ins)
                            }
                            InstallReferrerClient.InstallReferrerResponse.SERVICE_UNAVAILABLE,
                            InstallReferrerClient.InstallReferrerResponse.SERVICE_DISCONNECTED,
                            -> retryLater(engine, tries, source)
                            else -> finish(engine, JSONObject().put("src", source))
                        }
                        try {
                            client.endConnection()
                        } catch (e: Exception) {
                            Log.d("install referrer: ${e.javaClass.simpleName}")
                        }
                    }
                }

                override fun onInstallReferrerServiceDisconnected() {}
            })
        } catch (e: Exception) {
            retryLater(engine, tries, source)
        }
    }

    fun skip(engine: Engine) {
        engine.store?.put(K_STATE, "done")
    }

    private fun retryLater(engine: Engine, tries: Int, source: String) {
        val store = engine.store ?: return
        if (tries + 1 >= 3) finish(engine, JSONObject().put("src", source)) else store.put(K_STATE, (tries + 1).toString())
    }

    private fun finish(engine: Engine, ins: JSONObject) {
        val store = engine.store ?: return
        store.put(K_STATE, "done")
        store.put(K_PENDING, ins.toString())
        Log.d("install source: ${ins.optString("src")}")
        engine.currentId()?.let { engine.session(it) }?.let { attach(engine, it) }
    }

    /** Gives the waiting `ins` to [rec] (sent with its states until the server acknowledges one). */
    fun attach(engine: Engine, rec: SessionRec) {
        val store = engine.store ?: return
        val pending = store.get(K_PENDING) ?: return
        rec.ins = JSONObject(pending)
        store.put(K_PENDING, null)
        engine.save(rec)
    }
}
