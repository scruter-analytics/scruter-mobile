package net.scruter.internal

import android.view.View
import net.scruter.bridge.BridgeElement
import net.scruter.bridge.ElementInspector

/** What a wrapper SDK installed (docs/MOBILE.md §20). */
internal object BridgeState {
    @Volatile
    @JvmField
    var inspector: ElementInspector? = null

    val active: Boolean get() = inspector != null

    fun inspect(v: View): BridgeElement? = inspector?.inspect(v)
}
