package net.scruter.cmp.sample

import android.util.Log

/**
 * Stand-ins for an analytics SDK and an ad SDK, so that the example runs without them. Each function says what the
 * real SDK's call is (sdk/android/CMP.md, « Gating the app's SDKs »).
 */
object Analytics {
    @Volatile
    var enabled = false
        private set

    fun setEnabled(on: Boolean) {
        // Firebase: Firebase.analytics.setAnalyticsCollectionEnabled(on), and setConsent(...) from
        // ScruterCMP.consentModeSignals() (Consent Mode v2).
        enabled = on
        Log.i("Sample", "analytics ${if (on) "on" else "off"}")
    }
}

object Ads {
    @Volatile
    var started = false
        private set

    @Volatile
    var personalized = false
        private set

    fun configure(personalized: Boolean) {
        // Google Mobile Ads: MobileAds.initialize(context) once, then every AdRequest with the extra "npa" = "1" while
        // advertising is not granted (non-personalised ads).
        started = true
        this.personalized = personalized
        Log.i("Sample", "ads: ${if (personalized) "personalised" else "non-personalised"}")
    }
}
