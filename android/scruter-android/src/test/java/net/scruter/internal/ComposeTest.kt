package net.scruter.internal

import androidx.activity.ComponentActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import net.scruter.Scruter
import net.scruter.compose.ScruterScreen
import net.scruter.compose.scruterId
import net.scruter.compose.scruterMask
import net.scruter.compose.trackNavigation
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Jetpack Compose: identity from semantics, masks, lazy lists, Navigation Compose screens (docs/MOBILE.md §3.3–§3.5). */
@RunWith(RobolectricTestRunner::class)
class ComposeTest {
    @get:Rule
    val rule = createAndroidComposeRule<ComponentActivity>()
    private var server: FakeServer? = null

    @After
    fun tearDown() {
        Sdk.stop()
        server?.close()
    }

    @Test
    fun identityFromSemantics() {
        rule.setContent {
            Column {
                Button(onClick = {}, modifier = Modifier.scruterId("buy")) { Text("Buy") }
                Text("Price: 49 €")
                var t by remember { mutableStateOf("") }
                TextField(value = t, onValueChange = { t = it })
                Checkbox(checked = false, onCheckedChange = {})
                Box(Modifier.size(40.dp).scruterMask()) { Text("Morgan Smith") }
                LazyColumn(Modifier.height(300.dp).testTag("products")) {
                    items(100) { i -> Text("Product $i", Modifier.clickable { }) }
                }
            }
        }
        rule.waitForIdle()
        val tree = ViewNodes.build(rule.activity.window.decorView)
        val buy = tree.nodes.first { it.part == "#buy" }
        assertEquals("button", buy.kind)
        assertTrue(buy.interactive)
        assertEquals(Pair("#buy", 0), tree.identity(buy))
        val field = tree.nodes.first { it.kind == "input" }
        assertTrue(field.masked)
        assertEquals("TextField", field.part)
        assertEquals("Checkbox", tree.nodes.first { it.kind == "choice" }.part)
        val masked = tree.nodes.first { it.masked && it.kind != "input" }
        assertTrue("nothing inside a masked element", masked.children.isEmpty())
        val cells = tree.nodes.filter { it.parent?.part == "#products" }
        assertTrue(cells.size > 3)
        assertEquals("cell", cells[2].kind)
        assertEquals(Pair("#products/Node[cell]", 2), tree.identity(cells[2]))
        // A tap on the label inside the button targets the button.
        val label = buy.children.firstOrNull() ?: buy
        assertEquals(buy, tree.target(tree.hit(label.left + 1, label.top + 1)!!))
        assertNull("a masked element's content is never a target", tree.target(masked).takeIf { it !== masked })
        assertFalse(tree.nodes.any { it.parent === masked })
    }

    @Test
    fun navigationComposeScreens() {
        val s = FakeServer().also { server = it }
        Scruter.startWith(Sdk.app, Options("ATMONA02", null, true, false, s.url, s.url, "android/test"), rule.activity)
        val e = Scruter.engine()!!
        Sdk.worker(e)
        var go: (String) -> Unit = {}
        rule.setContent {
            val nav = Scruter.trackNavigation(rememberNavController())
            go = { nav.navigate(it) }
            NavHost(nav, startDestination = "home") {
                composable("home") { Text("Home") }
                composable("product/{id}") { Text("Product") }
                composable("cart") {
                    ScruterScreen("Shopping cart")
                    Text("Shopping cart")
                }
            }
        }
        rule.waitForIdle()
        Sdk.idle(200)
        rule.runOnUiThread { go("product/42") }
        rule.waitForIdle()
        Sdk.idle(200)
        rule.runOnUiThread { go("cart") }
        rule.waitForIdle()
        Sdk.idle(200)
        Sdk.worker(e)
        e.post { e.flush("test") }
        Sdk.worker(e)
        val names = ArrayList<String>()
        while (true) {
            val r = s.requests.poll() ?: break
            if (r.path != "/m/v1/batch") continue
            val ev = r.json().optJSONArray("e") ?: continue
            for (i in 0 until ev.length()) if (ev.getJSONObject(i).getString("k") == "screen") names.add(ev.getJSONObject(i).getString("n"))
        }
        assertEquals(listOf("home", "product/{id}", "Shopping cart"), names.filter { it != "Component" })
        assertFalse("never the argument values", names.any { it.contains("42") })
    }
}
