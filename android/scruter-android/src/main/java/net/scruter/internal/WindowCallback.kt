package net.scruter.internal

import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Window
import java.lang.ref.WeakReference

/**
 * Wraps an activity window's callback to see touches and keys before the app (taps, engagement, back): it observes
 * and always delegates, so the app and the other wrappers (AppCompat, other SDKs) behave as before.
 */
internal class WindowCallback(
    private val ui: Ui,
    window: Window,
    val delegate: Window.Callback,
) : Window.Callback by delegate {
    private val window = WeakReference(window)

    override fun dispatchTouchEvent(event: MotionEvent?): Boolean {
        if (event != null) {
            try {
                window.get()?.let { ui.touch(it, event) }
            } catch (e: Throwable) {
                Log.w("touch", e)
            }
        }
        return delegate.dispatchTouchEvent(event)
    }

    override fun dispatchKeyEvent(event: KeyEvent?): Boolean {
        if (event != null) {
            try {
                ui.key(event)
            } catch (e: Throwable) {
                Log.w("key", e)
            }
        }
        return delegate.dispatchKeyEvent(event)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        ui.windowFocusChanged()
        delegate.onWindowFocusChanged(hasFocus)
    }
}
