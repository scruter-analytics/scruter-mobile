package net.scruter.budget.cmp

import android.app.Activity
import android.app.Application

object Measure {
    fun start(app: Application) {
        app.packageName
    }

    fun use(activity: Activity) {
        activity.title
    }
}
