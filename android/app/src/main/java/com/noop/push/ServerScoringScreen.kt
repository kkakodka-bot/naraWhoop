package com.noop.push

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.ui.NoopButton
import com.noop.ui.NoopButtonKind
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ScreenScaffold
import com.noop.ui.SettingsCard
import com.noop.ui.SettingsToggleRow
import kotlinx.coroutines.launch

/** Settings > Advanced controls the same owner-fenced repository used by the physiology views. */
@Composable
fun ServerScoringScreen(scores: ServerScoreRepository) {
    val context = LocalContext.current
    val enabled by scores.enabled.collectAsStateWithLifecycle()
    val signedIn by scores.signedIn.collectAsStateWithLifecycle()
    val error by scores.lastError.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val configured = SelfHostedPushSettings.from(context).configuredEndpoint() != null
    ScreenScaffold(title = stringResource(R.string.server_scoring_title),
        subtitle = stringResource(R.string.server_scoring_description)) {
        SettingsCard(icon = Icons.Filled.CloudSync, title = stringResource(R.string.server_scoring_title),
            blurb = stringResource(R.string.server_scoring_description)) {
            SettingsToggleRow(title = stringResource(R.string.server_scoring_use_server),
                detail = stringResource(R.string.server_scoring_mode_detail), checked = enabled,
                onCheckedChange = { value ->
                    scores.setEnabled(value)
                    if (value) scope.launch { scores.refreshVisibleDays() }
                })
        }
        SettingsCard(icon = Icons.Outlined.AccountCircle, title = "Your enrollment",
            blurb = "Uploads and server results use the same personal account on this phone.") {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(if (signedIn) "This phone is enrolled." else "A fresh enrollment code is required.", style = NoopType.body)
                if (!configured) Text("Cloud configuration is unavailable in this build.", color = Palette.statusWarning)
                if (signedIn) NoopButton(text = "Remove enrollment", kind = NoopButtonKind.Tertiary, fullWidth = true,
                    onClick = {
                        scores.signOut()
                        (context.applicationContext as? com.noop.NoopApplication)?.ble?.disconnect()
                    })
                Text("Removing enrollment stops cloud access. Retained data stays bound to this account; use a separate installation for another person.", style = NoopType.footnote)
                error?.let { Text(it, style = NoopType.footnote, color = Palette.statusCritical) }
            }
        }
    }
}
