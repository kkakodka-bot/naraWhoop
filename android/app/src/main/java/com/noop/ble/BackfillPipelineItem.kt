package com.noop.ble

import com.noop.protocol.DeviceFamily
import kotlinx.coroutines.CompletableDeferred

/** One ordered item in the historical-offload serial pipeline (frames + session control). */
internal sealed interface BackfillPipelineItem {
    data class Frame(val data: ByteArray) : BackfillPipelineItem
    data class Begin(
        val family: DeviceFamily,
        val continuedAfterRows: Boolean,
        val ack: CompletableDeferred<Unit>,
    ) : BackfillPipelineItem
    data class Timeout(val ack: CompletableDeferred<Unit>) : BackfillPipelineItem
}
