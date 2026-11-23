package net.scruter.budget

import android.app.Application
import android.view.View

object Measure {
    fun start(app: Application) {
        app.packageName
    }

    fun use(view: View) {
        view.id
    }
}
