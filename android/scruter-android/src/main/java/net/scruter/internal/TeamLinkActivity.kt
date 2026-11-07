package net.scruter.internal

import android.app.Activity
import android.os.Bundle
import net.scruter.Scruter

/**
 * Opens on `scruter-<app id>://team?t=…`, the QR code of App settings › Team phones (docs/MOBILE.md
 * §3.12): hands the link to the SDK, then opens the app. No UI of its own.
 */
public class TeamLinkActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.let { Scruter.handle(it) }
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(it)
        }
        finish()
    }
}
