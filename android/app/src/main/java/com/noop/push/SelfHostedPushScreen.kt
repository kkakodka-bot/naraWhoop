package com.noop.push

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ui.NoopButton
import com.noop.ui.NoopButtonKind
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ScreenScaffold
import com.noop.ui.SettingsCard
import com.noop.ui.SettingsToggleRow
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * Fleet cloud-push status and controls. The destination (Supabase Edge Function) and bearer
 * token are baked into the build — there is no per-user endpoint to configure.
 */
@Composable
fun SelfHostedPushScreen() {
    val context = LocalContext.current
    val settings = remember { SelfHostedPushSettings.from(context) }
    var snapshot by remember { mutableStateOf(settings.snapshot()) }
    var enableRejected by remember { mutableStateOf(false) }

    // WorkManager runs outside this composition. Refresh while visible so progress and completion do
    // not require navigating away and back (and avoid retaining a UI listener in process globals).
    LaunchedEffect(settings) {
        while (currentCoroutineContext().isActive) {
            snapshot = settings.snapshot()
            delay(750)
        }
    }

    val active = snapshot.runState in setOf(
        SelfHostedPushSettings.RunState.QUEUED,
        SelfHostedPushSettings.RunState.RUNNING,
        SelfHostedPushSettings.RunState.CONTINUING,
        SelfHostedPushSettings.RunState.RETRYING,
    )

    ScreenScaffold(
        title = stringResource(R.string.push_title),
        subtitle = stringResource(R.string.push_subtitle),
    ) {
        SettingsCard(
            icon = Icons.Filled.CloudUpload,
            title = stringResource(R.string.push_destination_title),
            blurb = stringResource(R.string.push_disclosure),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                InstallationRetirementControl()
                Text(
                    stringResource(R.string.push_one_way_warning),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )

                snapshot.supportedStreams?.let { streams ->
                    Text(
                        stringResource(
                            R.string.push_capabilities_summary,
                            streams.size,
                            PushCapabilities.ALL.wireNames.size,
                        ),
                        style = NoopType.body,
                        color = if (streams.isEmpty()) Palette.statusWarning else Palette.textPrimary,
                    )
                    snapshot.capabilitiesCheckedAt?.let { checkedAt ->
                        val checked = DateFormat.getDateTimeInstance(
                            DateFormat.MEDIUM,
                            DateFormat.SHORT,
                        ).format(Date(checkedAt))
                        Text(
                            stringResource(R.string.push_capabilities_checked, checked),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    Text(
                        if (streams.isEmpty()) stringResource(R.string.push_capabilities_none)
                        else stringResource(R.string.push_capabilities_streams, streams.joinToString(" · ")),
                        style = NoopType.footnote,
                        color = if (streams.isEmpty()) Palette.statusWarning else Palette.textSecondary,
                    )
                }

                if (enableRejected) {
                    Text(
                        stringResource(R.string.push_config_required),
                        style = NoopType.footnote,
                        color = Palette.statusWarning,
                    )
                }

                SettingsToggleRow(
                    title = stringResource(R.string.push_wifi_only),
                    detail = stringResource(R.string.push_wifi_only_detail),
                    checked = snapshot.wifiOnly,
                    onCheckedChange = { requested ->
                        settings.setWifiOnly(requested)
                        SelfHostedPushScheduler.networkPolicyChanged(context)
                        snapshot = settings.snapshot()
                    },
                )
                SettingsToggleRow(
                    title = stringResource(R.string.push_binary_objects),
                    detail = stringResource(R.string.push_binary_objects_detail),
                    checked = snapshot.binaryObjectsEnabled,
                    onCheckedChange = { requested ->
                        settings.setBinaryObjectsEnabled(requested)
                        snapshot = settings.snapshot()
                    },
                )
                SettingsToggleRow(
                    title = stringResource(R.string.push_enabled),
                    detail = stringResource(R.string.push_enabled_detail),
                    checked = snapshot.enabled,
                    onCheckedChange = { requested ->
                        if (!requested) {
                            settings.setEnabled(false)
                            SelfHostedPushScheduler.cancel(context)
                            enableRejected = false
                        } else if (!settings.setEnabled(true)) {
                            enableRejected = true
                        } else {
                            enableRejected = false
                            SelfHostedPushScheduler.enqueueLaunchCatchUp(context)
                        }
                        snapshot = settings.snapshot()
                    },
                )
                NoopButton(
                    text = stringResource(R.string.push_export_now),
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = snapshot.ready,
                    onClick = {
                        SelfHostedPushScheduler.enqueueManualCatchUp(context)
                        snapshot = settings.snapshot()
                    },
                )
                Text(
                    stringResource(R.string.push_export_now_detail),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
        }

        SettingsCard(
            icon = Icons.Filled.CloudUpload,
            title = stringResource(R.string.push_status_title),
            blurb = stringResource(R.string.push_status_detail),
        ) {
            if (active) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = Palette.accent)
            }
            val state = when (snapshot.runState) {
                SelfHostedPushSettings.RunState.IDLE -> stringResource(R.string.push_state_idle)
                SelfHostedPushSettings.RunState.QUEUED -> stringResource(R.string.push_state_queued)
                SelfHostedPushSettings.RunState.RUNNING -> stringResource(R.string.push_state_running)
                SelfHostedPushSettings.RunState.CONTINUING -> stringResource(R.string.push_state_continuing)
                SelfHostedPushSettings.RunState.RETRYING -> stringResource(R.string.push_state_retrying)
                SelfHostedPushSettings.RunState.COMPLETE -> stringResource(R.string.push_state_complete)
                SelfHostedPushSettings.RunState.FAILED -> stringResource(R.string.push_state_failed)
            }
            Text(stringResource(R.string.push_current_state, state), style = NoopType.body, color = Palette.textPrimary)
            Text(
                stringResource(R.string.push_progress, snapshot.acceptedBatches, snapshot.acceptedRecords),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            snapshot.currentStream?.let { stream ->
                Text(
                    stringResource(R.string.push_current_stream, stream),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            val success = snapshot.lastSuccessAt?.let {
                DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it))
            } ?: stringResource(R.string.push_never)
            Text(stringResource(R.string.push_last_success, success), style = NoopType.body, color = Palette.textPrimary)
            snapshot.lastError?.let {
                Text(stringResource(R.string.push_last_error, it), style = NoopType.footnote, color = Palette.statusWarning)
            }
        }
    }
}
