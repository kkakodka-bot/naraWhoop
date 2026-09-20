package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.push.ServerRespirationSummary
import com.noop.push.ServerScoringSettings
import java.time.LocalDate
import java.util.Locale

/** Selected server result remains separate from the older local daily trend. */
@Composable
fun ServerRespirationSummaryCard(vm: AppViewModel) {
    var offset by remember { mutableIntStateOf(0) }
    val day = LocalDate.now().minusDays(offset.toLong()).toString()
    val context = LocalContext.current
    val ready = ServerScoringSettings.ready(context)
    val signedIn by vm.serverScores.signedIn.collectAsStateWithLifecycle()
    val fetched by vm.serverScores.lastFetchedAtMs.collectAsStateWithLifecycle()
    val error by vm.serverScores.lastError.collectAsStateWithLifecycle()
    val cache = fetched.let { if (ready && signedIn) vm.serverScores.overlay(day) else null }
    val feature = cache?.features?.get("respiration")
    val summary = remember(cache, day) { ServerRespirationSummary.project(cache, day) }
    LaunchedEffect(day, ready, signedIn) { vm.serverScores.refreshDay(day) }
    fun decimal(value: Double?) = value?.let { String.format(Locale.getDefault(), "%.1f", it) } ?: "—"
    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(uiString(R.string.server_resp_title), style = NoopType.subhead)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = { offset++ }) { Text(uiString(R.string.l10n_strand_components_previous_day_e2b6b0a1)) }
                Text(day, style = NoopType.footnote)
                TextButton(onClick = { offset = maxOf(0, offset - 1) }, enabled = offset > 0) {
                    Text(uiString(R.string.l10n_strand_components_next_day_38f859dd))
                }
            }
            when {
                !ready -> Text(uiString(R.string.server_resp_configure), style = NoopType.footnote)
                !signedIn -> Text(uiString(R.string.server_resp_sign_in), style = NoopType.footnote)
                else -> {
                    Text(uiString(R.string.server_resp_value, decimal(summary?.breathsPerMinute)), style = NoopType.subhead)
                    Text(uiString(R.string.server_resp_state, feature?.status ?: "unavailable", feature?.processingStatus ?: "unavailable"), style = NoopType.footnote)
                    Text(uiString(R.string.server_resp_source, feature?.deviceId ?: "—", feature?.algorithmVersion ?: "—"), style = NoopType.footnote)
                    Text(uiString(R.string.server_resp_observed, feature?.observedThrough ?: "—"), style = NoopType.footnote)
                    Text(uiString(R.string.server_resp_computed, feature?.computedAt ?: "—"), style = NoopType.footnote)
                    if (summary != null) {
                        if (summary.legacy) {
                            Text(uiString(R.string.server_resp_legacy), style = NoopType.footnote)
                        } else {
                            Text(uiString(R.string.server_resp_primary), style = NoopType.footnote)
                            Text(uiString(R.string.server_resp_mean, decimal(if (summary.breathsPerMinute == null) null else summary.mean)), style = NoopType.footnote)
                            Text(uiString(R.string.server_resp_coverage, decimal(summary.acceptedSeconds?.div(60)), decimal(summary.coverage?.times(100))), style = NoopType.footnote)
                            Text(uiString(R.string.server_resp_windows, summary.acceptedWindows?.toString() ?: "—", summary.totalWindows?.toString() ?: "—"), style = NoopType.footnote)
                            if (summary.breathsPerMinute != null && summary.distribution.isNotEmpty()) {
                                Text(uiString(R.string.server_resp_range, decimal(summary.distribution.first()), decimal(summary.distribution.last())), style = NoopType.footnote)
                            }
                            Text(uiString(R.string.server_resp_method, summary.method ?: "—", summary.calibrationStatus ?: "—"), style = NoopType.footnote)
                        }
                    }
                    (summary?.reason ?: feature?.reason)?.let { reason ->
                        physiologyReasonResource(reason)?.let { Text(uiString(it), style = NoopType.footnote) }
                        Text(reason, style = NoopType.footnote)
                    }
                    summary?.measurementReason?.takeIf { it != (summary.reason ?: feature?.reason) }?.let { reason ->
                        physiologyReasonResource(reason)?.let { Text(uiString(it), style = NoopType.footnote) }
                        Text(reason, style = NoopType.footnote)
                    }
                    error?.let { Text(it, style = NoopType.footnote, color = Palette.statusCritical) }
                    Text(uiString(R.string.server_resp_separate), style = NoopType.footnote, color = Palette.textSecondary)
                }
            }
        }
    }
}
