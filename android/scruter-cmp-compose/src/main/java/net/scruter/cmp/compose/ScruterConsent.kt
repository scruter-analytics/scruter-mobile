package net.scruter.cmp.compose

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import net.scruter.cmp.ConsentChoice
import net.scruter.cmp.ScruterCMP

/**
 * Shows the consent sheet over the activity that hosts [content] whenever a decision is needed (docs/CMP-MOBILE.md
 * §3.2), for an app started with `Presentation.MANUAL`: wrap the screen that comes first after an onboarding.
 *
 * ```kotlin
 * setContent { ScruterConsentHost { AppNavHost() } }
 * ```
 */
@Composable
public fun ScruterConsentHost(content: @Composable () -> Unit) {
    val activity = LocalContext.current.activity()
    @Suppress("DEPRECATION")
    val owner = LocalLifecycleOwner.current
    DisposableEffect(activity, owner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && activity != null) ScruterCMP.showIfNeeded(activity)
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    content()
}

/** The visitor's choice as Compose state: null until a valid choice exists, then every change. */
@Composable
public fun rememberConsentChoice(): State<ConsentChoice?> {
    val state = remember { mutableStateOf(ScruterCMP.choice) }
    DisposableEffect(Unit) {
        val ready = ScruterCMP.whenReady { state.value = it }
        val change = ScruterCMP.onChange { state.value = it }
        onDispose {
            ready.cancel()
            change.cancel()
        }
    }
    return state
}

/**
 * The visitor's choices as a `Flow` (docs/CMP-MOBILE.md §3.4): the current valid choice first when there is one, then
 * every change (a decision, the preferences, a withdrawal). Collected on any dispatcher; the values come from the main
 * thread.
 */
public fun ScruterCMP.choices(): Flow<ConsentChoice> = callbackFlow {
    val ready = whenReady { trySend(it) }
    val change = onChange { trySend(it) }
    awaitClose {
        ready.cancel()
        change.cancel()
    }
}.distinctUntilChanged { a, b -> a.consentId == b.consentId && a.decidedAt == b.decidedAt && a.purposes == b.purposes }

private fun Context.activity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}
