package net.scruter.internal

import android.app.Activity
import android.view.View
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import net.scruter.ScruterScreen

/**
 * Automatic screens of AndroidX fragments (docs/MOBILE.md §3.3): a fragment resumed and visible, its name from
 * `@ScruterScreen` or its class; a `DialogFragment` only when named; a fragment that hosts the current one (a
 * `NavHostFragment`, any container with a primary navigation fragment) is not a screen.
 */
internal object Fragments {
    fun probe(): Any = FragmentActivity::class.java

    fun register(activity: Activity, ui: Ui) {
        if (activity !is FragmentActivity) return
        activity.supportFragmentManager.registerFragmentLifecycleCallbacks(object : FragmentManager.FragmentLifecycleCallbacks() {
            override fun onFragmentResumed(fm: FragmentManager, f: Fragment) {
                // Not Fragment.isVisible: at the first resume the window is not attached yet.
                if (!f.isAdded || f.isHidden || f.view?.visibility != View.VISIBLE) return
                if (f.childFragmentManager.primaryNavigationFragment != null) return
                val named = f.javaClass.getAnnotation(ScruterScreen::class.java)?.value
                if (f is DialogFragment && named == null) return
                var depth = 1
                var p = f.parentFragment
                while (p != null) {
                    depth++
                    p = p.parentFragment
                }
                ui.candidate(activity, named ?: Text.screenNameOf(f.javaClass), depth, f.javaClass.name)
            }
        }, true)
    }
}
