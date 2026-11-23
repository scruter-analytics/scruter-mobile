package net.scruter.cmp.sample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import net.scruter.cmp.Purpose
import net.scruter.cmp.ScruterCMP
import net.scruter.cmp.compose.ScruterConsentHost
import net.scruter.cmp.compose.rememberConsentChoice

/** The Compose screen: the same settings entry, the choice as Compose state. */
class ComposeActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                // With Presentation.MANUAL, ScruterConsentHost shows the sheet over this screen when needed.
                ScruterConsentHost { PrivacyScreen() }
            }
        }
    }
}

@Composable
private fun PrivacyScreen() {
    val choice by rememberConsentChoice()
    val activity = LocalContext.current as ComponentActivity
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(R.string.compose_title), style = MaterialTheme.typography.headlineSmall)
            val analytics = choice?.isGranted(Purpose.ANALYTICS) == true
            Text(
                if (choice == null) stringResource(R.string.no_choice)
                else stringResource(R.string.analytics_state, stringResource(if (analytics) R.string.on else R.string.off)),
                Modifier.testTag("compose-status"),
            )
            Button(onClick = { ScruterCMP.showPreferences(activity) }) {
                Text(stringResource(R.string.privacy_choices))
            }
        }
    }
}
