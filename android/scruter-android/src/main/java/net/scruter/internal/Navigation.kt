package net.scruter.internal

import android.os.Bundle
import androidx.navigation.NavController
import androidx.navigation.NavDestination
import net.scruter.Scruter
import java.util.WeakHashMap

/**
 * Navigation Compose destinations (docs/MOBILE.md §3.3): the route pattern, never the argument values. A type-safe
 * route (`com.example.Product/{id}`) loses its package; optional arguments (`?sort={sort}`) are dropped. A destination
 * without route gives its label.
 */
internal object Navigation {
    private val tracked = WeakHashMap<NavController, Boolean>()

    fun track(nav: NavController) {
        if (!Scruter.isStarted()) return
        synchronized(tracked) {
            if (tracked.containsKey(nav)) return
            tracked[nav] = true
        }
        // Back: the new entry is the one that was just below the previous one.
        var below: String? = null
        nav.addOnDestinationChangedListener { controller: NavController, destination: NavDestination, _: Bundle? ->
            val back = below != null && controller.currentBackStackEntry?.id == below
            below = controller.previousBackStackEntry?.id
            Scruter.ui()?.navigation(name(destination.route, destination.label?.toString()), back)
        }
    }

    fun name(route: String?, label: String?): String? {
        if (route != null) {
            var r = route.substringBefore('?')
            val slash = r.indexOf('/')
            val head = if (slash < 0) r else r.substring(0, slash)
            if (head.contains('.')) r = head.substring(head.lastIndexOf('.') + 1) + (if (slash < 0) "" else r.substring(slash))
            Text.clean(r, 120)?.let { return it }
        }
        return Text.clean(label, 120)
    }
}
