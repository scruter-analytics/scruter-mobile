package net.scruter.budget.cmp

import android.app.Activity
import android.app.Application
import net.scruter.cmp.Presentation
import net.scruter.cmp.Purpose
import net.scruter.cmp.ScruterCMP

/** The whole public API: nothing is left for R8 to remove. */
object Measure {
    fun start(app: Application) {
        ScruterCMP.start(app, "ATMONA02", Presentation.AUTOMATIC)
        ScruterCMP.whenReady { app.packageName }
        ScruterCMP.onChange { if (it.isGranted(Purpose.ANALYTICS)) app.packageName }
    }

    fun use(activity: Activity) {
        ScruterCMP.debug = ScruterCMP.isGranted(Purpose.ADVERTISING)
        ScruterCMP.setLanguage(ScruterCMP.consentId)
        activity.title = ScruterCMP.consentModeSignals().toString() + ScruterCMP.state + ScruterCMP.choice
        if (!ScruterCMP.showIfNeeded(activity)) ScruterCMP.showPreferences(activity)
        if (activity.isTaskRoot) ScruterCMP.debugReset() else ScruterCMP.forceShow = true
    }
}
