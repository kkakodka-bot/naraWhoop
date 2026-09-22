package com.noop.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import kotlinx.coroutines.delay

/** Polls the durable request, never a phone estimator. Navigation does not erase its receipt. */
@Composable
fun CanonicalSessionReadout(vm: AppViewModel, requestId: String?) {
    var result by remember(requestId) { mutableStateOf(requestId?.let(vm.serverScores.computeRequests::result)) }
    var state by remember(requestId) { mutableStateOf("queued") }
    LaunchedEffect(requestId) {
        if (requestId == null) return@LaunchedEffect
        while (true) {
            vm.serverScores.computeRequests.drain()
            result = vm.serverScores.computeRequests.result(requestId)
            state = vm.serverScores.computeRequests.response(requestId)?.optString("state", "processing") ?: "queued"
            if (result != null) break
            delay(5_000)
        }
    }
    Column {
        Text(result?.reason ?: result?.status ?: if (requestId == null) "awaiting_account_and_device" else state)
        result?.let { family ->
            family.metrics.forEach { Text("$it: ${family.value(it)?.toString() ?: "unavailable"}") }
            Text("Result: ${family.resultRevision ?: "pending publication"}")
        }
    }
}
