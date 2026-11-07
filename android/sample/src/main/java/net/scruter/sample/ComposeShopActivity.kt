package net.scruter.sample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import net.scruter.Scruter
import net.scruter.compose.ScruterScreen
import net.scruter.compose.scruterForm
import net.scruter.compose.scruterId
import net.scruter.compose.scruterMask
import net.scruter.compose.trackNavigation

/** Navigation Compose: `product/{id}` is counted as a pattern; the cart names itself with `ScruterScreen`. */
class ComposeShopActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                val nav = Scruter.trackNavigation(rememberNavController())
                NavHost(nav, startDestination = "shop", modifier = Modifier.fillMaxSize()) {
                    composable("shop") {
                        LazyColumn(Modifier.fillMaxSize().testTag("products")) {
                            items(200) { i ->
                                Text(
                                    stringResource(R.string.product, i),
                                    Modifier.fillMaxWidth().clickable { nav.navigate("product/$i") }.padding(16.dp).testTag("product"),
                                )
                            }
                        }
                    }
                    composable("product/{id}") {
                        Column(Modifier.padding(16.dp)) {
                            Text(stringResource(R.string.customer), Modifier.scruterMask())
                            Button(
                                onClick = {
                                    Scruter.track("Add to cart", mapOf("color" to "blue"))
                                    nav.navigate("cart")
                                },
                                modifier = Modifier.scruterId("addToCart"),
                            ) { Text(stringResource(R.string.add_to_cart)) }
                        }
                    }
                    composable("cart") {
                        ScruterScreen("Cart")
                        Column(Modifier.padding(16.dp).scruterForm("Voucher")) {
                            var code by rememberSaveable { mutableStateOf("") }
                            OutlinedTextField(code, { code = it }, Modifier.scruterId("voucher"))
                        }
                    }
                }
            }
        }
    }
}
