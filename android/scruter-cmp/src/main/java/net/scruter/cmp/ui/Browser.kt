package net.scruter.cmp.ui

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import net.scruter.cmp.internal.Log

/**
 * Links of the sheet (the privacy policy, « Certifié par Scruter ») in the system browser: a Custom Tab when the
 * browser offers one, without the AndroidX Browser library. The Custom Tabs protocol is a plain `ACTION_VIEW` with a
 * session extra (a null binder means « no session »); a browser without Custom Tabs ignores it and opens the page.
 */
internal object Browser {
    /** The public CMP page of scruter.net, tagged for the apps' referral (docs/CMP-MOBILE.md M15). */
    const val CERTIFIED_URL = "https://scruter.net/cmp?utm_source=cmp_app&utm_medium=referral&utm_campaign=certified_by_scruter"

    fun open(activity: Activity, url: String, toolbarColor: Int) {
        val uri = Uri.parse(url)
        if (uri.scheme != "https" && uri.scheme != "http") return
        val i = Intent(Intent.ACTION_VIEW, uri)
        val extras = Bundle()
        extras.putBinder("android.support.customtabs.extra.SESSION", null)
        i.putExtras(extras)
        i.putExtra("android.support.customtabs.extra.TOOLBAR_COLOR", toolbarColor)
        i.putExtra("androidx.browser.customtabs.extra.SHARE_STATE", 1)
        try {
            activity.startActivity(i)
        } catch (e: ActivityNotFoundException) {
            Log.w("no browser to open $url")
        }
    }
}
