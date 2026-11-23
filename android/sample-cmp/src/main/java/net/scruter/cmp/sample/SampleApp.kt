package net.scruter.cmp.sample

import android.app.Application
import net.scruter.cmp.ConsentChoice
import net.scruter.cmp.ScruterCMP

class SampleApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // 1. The start line: reads the stored choice at once, fetches the configuration in the background, and shows
        //    the sheet over the first screen when a decision is needed.
        ScruterCMP.debug = BuildConfig.DEBUG
        ScruterCMP.start(this, "ATMONA02", endpoint = BuildConfig.CMP_ENDPOINT)

        // 2. The app's SDKs follow the visitor's choice: once a choice exists, then on every change.
        ScruterCMP.whenReady(::applyConsent)
        ScruterCMP.onChange(::applyConsent)
    }

    private fun applyConsent(choice: ConsentChoice) {
        Analytics.setEnabled(choice.isGranted("analytics"))
        Ads.configure(personalized = choice.isGranted("advertising"))
    }
}
