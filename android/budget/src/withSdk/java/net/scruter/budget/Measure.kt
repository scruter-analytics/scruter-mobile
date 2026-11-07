package net.scruter.budget

import android.app.Application
import android.content.Intent
import android.view.View
import net.scruter.FieldError
import net.scruter.Scruter
import net.scruter.scruterForm
import net.scruter.scruterId
import net.scruter.scruterIgnore
import net.scruter.scruterMask

/** The whole public API of a Views app: nothing is left for R8 to remove. */
object Measure {
    fun start(app: Application) {
        Scruter.start(app, appId = "ATMONA02")
    }

    fun use(view: View) {
        view.scruterMask = true
        view.scruterIgnore = false
        view.scruterId = "buy"
        view.scruterForm = "Delivery"
        Scruter.screen("Cart")
        Scruter.track("Add to cart", mapOf("color" to "blue"), 49.0, "EUR")
        Scruter.fieldError("postalCode", FieldError.FORMAT)
        Scruter.formSent("Delivery")
        Scruter.openedFromNotification()
        Scruter.handle(Intent())
        if (view.isSelected) Scruter.optOut() else Scruter.optIn()
        Scruter.ignoreThisDevice(Scruter.isOptedOut || Scruter.isDeviceIgnored)
    }
}
