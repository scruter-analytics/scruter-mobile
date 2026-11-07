@file:JvmName("ScruterCompose")

package net.scruter.compose

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics
import androidx.navigation.NavController
import net.scruter.Scruter
import net.scruter.internal.Navigation

/** Scruter's semantics keys: read by the SDK only, never by accessibility services. */
internal object ScruterSemantics {
    val Mask = SemanticsPropertyKey<Unit>("ScruterMask")
    val Ignore = SemanticsPropertyKey<Unit>("ScruterIgnore")
    val Id = SemanticsPropertyKey<String>("ScruterId")
    val Form = SemanticsPropertyKey<String>("ScruterForm")
}

/**
 * Masks this element in the team phones' screen images (docs/MOBILE.md §3.11): an opaque rectangle on the phone,
 * again on the server, and no label in the element tree. Text fields are always masked.
 */
public fun Modifier.scruterMask(): Modifier = this.semantics { this[ScruterSemantics.Mask] = Unit }

/** Taps inside this element are not collected and it is left out of the screen images' element tree. */
public fun Modifier.scruterIgnore(): Modifier = this.semantics { this[ScruterSemantics.Ignore] = Unit }

/** A stable identifier for this element (docs/MOBILE.md §3.5), written `#addToCart` in Screen analysis. */
public fun Modifier.scruterId(id: String): Modifier = this.semantics { this[ScruterSemantics.Id] = id }

/** The fields inside this element form "[name]" in Forms (docs/MOBILE.md §3.9). */
public fun Modifier.scruterForm(name: String): Modifier = this.semantics { this[ScruterSemantics.Form] = name }

/**
 * Counts a screen view of [name] each time this composable enters the composition (docs/MOBILE.md §3.3): put it at
 * the top of a screen's composable when it is not a Navigation Compose destination.
 */
@Composable
public fun ScruterScreen(name: String) {
    DisposableEffect(name) {
        Scruter.screen(name)
        onDispose { }
    }
}

/**
 * Counts Navigation Compose destinations as screens (docs/MOBILE.md §3.3): the name is the route pattern
 * (`product/{id}`, never the argument values), else the destination's label. Wrap the controller:
 * `val nav = Scruter.trackNavigation(rememberNavController())`; recompositions do nothing more.
 */
public fun <T : NavController> Scruter.trackNavigation(navController: T): T {
    Navigation.track(navController)
    return navController
}
