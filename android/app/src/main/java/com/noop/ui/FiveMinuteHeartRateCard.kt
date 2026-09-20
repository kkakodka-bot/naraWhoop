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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.noop.R
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.HeartRateWindows
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private data class HeartRateWindowLoad(
    val deviceId: String,
    val windows: List<HeartRateWindows.Measurement>,
    val failed: Boolean = false,
)

/** A single device's completed windows, separate from the cached nightly resting-HR statistic. */
@Composable
fun FiveMinuteHeartRateCard(vm: AppViewModel) {
    val deviceId by vm.activeStrapIdFlow.collectAsStateWithLifecycle()
    val lastSyncAt by remember(vm) {
        vm.live.map { it.lastSyncAt }.distinctUntilChanged()
    }.collectAsStateWithLifecycle(initialValue = null)
    var refresh by remember { mutableIntStateOf(0) }
    var expanded by remember(deviceId) { mutableStateOf(false) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle, deviceId) {
        if (deviceId == null) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            refresh++
            while (isActive) {
                delay(300_000L - Math.floorMod(System.currentTimeMillis(), 300_000L))
                refresh++
            }
        }
    }
    val loaded by produceState<HeartRateWindowLoad?>(null, deviceId, lastSyncAt, refresh) {
        value = null
        val owner = deviceId ?: return@produceState
        try {
            value = withContext(Dispatchers.Default) {
                val end = (System.currentTimeMillis() / 1000 / 300) * 300
                val start = end - 86_400
                val hr = vm.repo.hrSamplesForDevice(owner, start, end - 1, limit = 100_000)
                val gravity = vm.repo.gravitySamplesForDevice(owner, start, end - 1, limit = 100_000)
                val events = vm.repo.wearEventsForWindow(owner, start, end)
                val excluded = AnalyticsEngine.offWristIntervals(events, end)
                HeartRateWindowLoad(owner, HeartRateWindows.windows(start, end, hr, gravity, excluded))
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            value = HeartRateWindowLoad(owner, emptyList(), failed = true)
        }
    }
    // produceState retains its previous value until the replacement task starts on a device switch.
    val scoped = loaded?.takeIf { it.deviceId == deviceId }
    val timeFormat = remember { DateTimeFormatter.ofPattern("MMM d, HH:mm", Locale.getDefault()) }
    fun timestamp(seconds: Long) = Instant.ofEpochSecond(seconds).atZone(ZoneId.systemDefault()).format(timeFormat)
    fun bpm(value: Double?) = value?.let { String.format(Locale.getDefault(), "%.1f", it) } ?: "—"

    NoopCard(tint = Palette.metricRose) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(uiString(R.string.five_minute_hr_title), style = NoopType.subhead)
                TextButton(onClick = { refresh++ }) { Text(uiString(R.string.five_minute_hr_refresh)) }
            }
            when {
                deviceId == null -> Text(uiString(R.string.five_minute_hr_select_device), style = NoopType.footnote)
                scoped == null -> Text(uiString(R.string.five_minute_hr_loading), style = NoopType.footnote)
                scoped.failed -> Text(uiString(R.string.five_minute_hr_read_failed), style = NoopType.footnote)
                else -> {
                    val windows = scoped.windows
                    Text(uiString(R.string.five_minute_hr_counts,
                        windows.count { it.meanBpm != null }, windows.count { it.lowMotionBpm != null }),
                        style = NoopType.footnote)
                    Text(uiString(R.string.five_minute_hr_source, scoped.deviceId),
                        style = NoopType.footnote, color = Palette.textSecondary)
                    Text(uiString(R.string.five_minute_hr_baseline_separate),
                        style = NoopType.footnote, color = Palette.textSecondary)
                    if (windows.none { it.meanBpm != null }) {
                        Text(uiString(R.string.five_minute_hr_insufficient), style = NoopType.footnote)
                    }
                    for (window in if (expanded) windows.asReversed() else windows.takeLast(12).asReversed()) {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text("${timestamp(window.start)}–${timestamp(window.end)}", style = NoopType.footnote)
                            Text(uiString(R.string.five_minute_hr_values, bpm(window.meanBpm), bpm(window.lowMotionBpm)),
                                style = NoopType.footnote)
                            Text(uiString(R.string.five_minute_hr_coverage,
                                (window.sampleFraction * 100).toInt(), (window.lowMotionSampleFraction * 100).toInt()),
                                style = NoopType.footnote, color = Palette.textSecondary)
                            listOfNotNull(window.reason, window.lowMotionReason).distinct().takeIf { it.isNotEmpty() }?.let {
                                Text(it.joinToString(" · ") { reason -> reason.replace('_', ' ') },
                                    style = NoopType.footnote, color = Palette.textSecondary)
                            }
                        }
                    }
                    if (windows.size > 12) {
                        TextButton(onClick = { expanded = !expanded }) {
                            Text(if (expanded) uiString(R.string.five_minute_hr_show_recent)
                                 else uiString(R.string.five_minute_hr_show_all, windows.size))
                        }
                    }
                }
            }
        }
    }
}
