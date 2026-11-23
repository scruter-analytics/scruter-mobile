package net.scruter.sample

import android.app.Application
import android.util.Log
import net.scruter.Scruter

class SampleApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val t = System.nanoTime()
        Scruter.start(
            this,
            appId = "ATMONA02",
            debug = BuildConfig.DEBUG || BuildConfig.SELF_CHECK,
            endpoint = BuildConfig.ENDPOINT,
            apiEndpoint = BuildConfig.API_ENDPOINT,
        )
        if (BuildConfig.SELF_CHECK) Log.i("ScruterSample", "start: ${(System.nanoTime() - t) / 1000} µs")
    }
}
