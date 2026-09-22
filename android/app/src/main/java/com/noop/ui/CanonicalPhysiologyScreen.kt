package com.noop.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.push.ServerComputeContract
import java.time.LocalDate

@Composable
fun CanonicalFamilyReadout(vm: AppViewModel, familyID: String) {
    val days by vm.serverScores.canonicalDays.collectAsStateWithLifecycle()
    val day = LocalDate.now().toString()
    val cache = days[day]
    val family = cache?.compute?.families?.get(familyID)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(familyID.replace('_', ' '))
        Text(family?.reason ?: family?.status ?: "awaiting_server_result")
        ServerComputeContract.familyMetrics[familyID].orEmpty().forEach { metric ->
            Text("${metric.replace('_', ' ')}: ${family?.value(metric)?.toString() ?: "unavailable"}")
        }
        Text("Result: ${family?.resultRevision ?: "pending publication"}")
        if (cache?.stale == true) Text("Cached result, stale")
    }
}

/** Revision-bearing rendering shared by former phone-analysis surfaces. No physiological summaries. */
@Composable
fun CanonicalPhysiologyScreen(vm: AppViewModel, title: String, families: Set<String>,
                              actions: Map<String, () -> Unit> = emptyMap()) {
    val days by vm.serverScores.canonicalDays.collectAsStateWithLifecycle()
    val error by vm.serverScores.lastError.collectAsStateWithLifecycle()
    val live by vm.live.collectAsStateWithLifecycle()
    var selected by remember { mutableStateOf(LocalDate.now()) }
    LaunchedEffect(selected) { vm.serverScores.refreshDay(selected.toString()) }
    val cache = days[selected.toString()]
    LazyScreenScaffold(title = title, subtitle = "Canonical server results") {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row {
                    TextButton(onClick = { selected = selected.minusDays(1) }) { Text("Previous") }
                    Text(selected.toString())
                    TextButton(onClick = { if (selected < LocalDate.now()) selected = selected.plusDays(1) }) { Text("Next") }
                }
                if (title == "Today") Text("Device heart rate: ${live.heartRate?.toString() ?: "unavailable"}")
                error?.let { Text(it) }
                actions.forEach { (label, action) -> TextButton(onClick = action) { Text(label) } }
                CanonicalExportButton(vm, androidx.compose.ui.platform.LocalContext.current)
            }
        }
        families.forEach { key ->
            item(key = "family:$key") {
                val family = cache?.compute?.families?.get(key)
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(key.replace('_', ' '))
                    Text(family?.reason ?: family?.status ?: "awaiting_server_result")
                    ServerComputeContract.familyMetrics[key].orEmpty().forEach { metric ->
                        Text("${metric.replace('_', ' ')}: ${family?.value(metric)?.toString() ?: "unavailable"}")
                    }
                    Text("Result: ${family?.resultRevision ?: "pending publication"}")
                    family?.observedThrough?.let { Text("Observed through: $it") }
                    family?.computedAt?.let { Text("Computed: $it") }
                    if (cache?.stale == true) Text("Cached result, stale")
                    if (family?.authorized == true && !family.expired()) {
                        val details = org.json.JSONObject(family.json).optJSONObject("details")
                        details?.keys()?.forEach { detail -> Text("$detail: ${details.opt(detail)}") }
                    }
                }
            }
        }
    }
}
