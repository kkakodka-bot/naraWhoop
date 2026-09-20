package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.push.ServerHrvSeries
import com.noop.push.ServerScoringSettings
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.launch

/** Availability copy never changes measurement eligibility or snapshot freshness. */
internal fun physiologyReasonResource(reason: String): Int? = when (reason) {
    "newer_input_pending" -> R.string.physiology_reason_newer_input_pending
    "no_observations" -> R.string.physiology_reason_no_observations
    "timing_coverage_unverified" -> R.string.physiology_reason_timing_coverage
    "timing_unverified" -> R.string.physiology_reason_timing_unverified
    "continuity_unverified" -> R.string.physiology_reason_continuity
    "no_quality_eligible_windows" -> R.string.physiology_reason_no_eligible_windows
    "sleep_context_unavailable" -> R.string.physiology_reason_sleep_context
    "window_missing" -> R.string.physiology_reason_window_missing
    else -> null
}

/** The server five-minute series is not the local daily history below it. */
@Composable
internal fun ServerHrvSeriesCard(vm: AppViewModel) {
    var offset by remember { mutableIntStateOf(0) }
    val day = LocalDate.now().minusDays(offset.toLong()).toString()
    val context = LocalContext.current
    val ready = ServerScoringSettings.ready(context)
    val signedIn by vm.serverScores.signedIn.collectAsStateWithLifecycle()
    val fetched by vm.serverScores.lastFetchedAtMs.collectAsStateWithLifecycle()
    val error by vm.serverScores.lastError.collectAsStateWithLifecycle()
    val cache = fetched.let { if (ready && signedIn) vm.serverScores.overlay(day) else null }
    val series = remember(cache, day) { ServerHrvSeries.from(cache, day) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(day, ready, signedIn) { if (ready && signedIn) vm.serverScores.refreshDay(day) }
    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(uiString(R.string.physiology_hrv_title), style = NoopType.subhead)
            Text(uiString(R.string.physiology_hrv_caption), style = NoopType.footnote)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = { offset++ }) { Text(uiString(R.string.physiology_hrv_previous)) }
                Text(day, style = NoopType.footnote)
                TextButton(onClick = { offset = maxOf(0, offset - 1) }, enabled = offset > 0) {
                    Text(uiString(R.string.physiology_hrv_next))
                }
            }
            TextButton(onClick = { scope.launch { vm.serverScores.refreshDay(day) } }, enabled = ready && signedIn) {
                Text(uiString(R.string.physiology_hrv_refresh))
            }
            when {
                !ready -> Text(uiString(R.string.physiology_hrv_configure), style = NoopType.footnote)
                !signedIn -> Text(uiString(R.string.physiology_hrv_sign_in), style = NoopType.footnote)
                else -> {
                    val status = series.featureStatus ?: "unavailable"
                    Text(uiString(R.string.physiology_hrv_status, if (series.stale && status != "stale") uiString(R.string.server_sleep_stale, status) else status), style = NoopType.footnote)
                    Text(uiString(R.string.physiology_hrv_device, series.deviceId ?: "—"), style = NoopType.footnote)
                    Text(uiString(R.string.physiology_hrv_model, series.algorithmVersion ?: "—"), style = NoopType.footnote)
                    Text(uiString(R.string.physiology_hrv_observed, series.observedThrough ?: "—"), style = NoopType.footnote)
                    series.featureReason?.let { reason ->
                        physiologyReasonResource(reason)?.let { Text(uiString(it), style = NoopType.footnote) }
                        Text(reason, style = NoopType.footnote)
                    }
                    error?.let { Text(it, style = NoopType.footnote, color = Palette.statusCritical) }
                    if (series.windows.isEmpty()) {
                        Text(uiString(R.string.physiology_hrv_empty), style = NoopType.footnote)
                    } else {
                        LazyColumn(Modifier.heightIn(max = 420.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            items(series.windows, key = { it.start }) { window ->
                                HrvWindowRow(window)
                                HorizontalDivider()
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HrvWindowRow(window: ServerHrvSeries.Window) {
    val clock = remember { DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm", Locale.ROOT).withZone(ZoneOffset.UTC) }
    fun decimal(value: Double) = String.format(Locale.getDefault(), "%.1f", value)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(uiString(R.string.physiology_hrv_utc_range, clock.format(Instant.ofEpochSecond(window.start)), clock.format(Instant.ofEpochSecond(window.end))), style = NoopType.footnote)
        Text(window.rmssdMs?.let { uiString(R.string.physiology_hrv_milliseconds, decimal(it)) } ?: uiString(R.string.physiology_hrv_unavailable), style = NoopType.subhead)
        Text(uiString(R.string.physiology_hrv_context, window.context), style = NoopType.footnote)
        Text(uiString(R.string.physiology_hrv_source, window.source ?: "—", window.modality ?: "—"), style = NoopType.footnote)
        Text(uiString(R.string.physiology_hrv_model, window.methodVersion ?: "—"), style = NoopType.footnote)
        Text(uiString(R.string.physiology_hrv_coverage, window.observedTimeFraction?.let { uiString(R.string.physiology_hrv_percent, decimal(it * 100)) } ?: "—"), style = NoopType.footnote)
        Text(uiString(R.string.physiology_hrv_baseline,
            uiString(if (window.baselineEligible) R.string.physiology_hrv_eligible else R.string.physiology_hrv_excluded),
            window.baselineEffectiveSampleCount?.toString() ?: "—"), style = NoopType.footnote)
        window.baselineRobustZ?.let { Text(uiString(R.string.physiology_hrv_deviation, decimal(it)), style = NoopType.footnote) }
        window.reason?.let { reason ->
            physiologyReasonResource(reason)?.let { Text(uiString(it), style = NoopType.footnote) }
            Text(reason, style = NoopType.footnote)
        }
        window.baselineReason?.takeIf { it != window.reason }?.let { Text(it, style = NoopType.footnote) }
    }
}
