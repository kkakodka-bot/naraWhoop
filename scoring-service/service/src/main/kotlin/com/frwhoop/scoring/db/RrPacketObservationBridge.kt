package com.frwhoop.scoring.db

import com.noop.analytics.PhysiologyQuality
import com.noop.data.RrInterval
import com.noop.protocol.DeviceFamily
import com.noop.protocol.RrPacketProvenance

/** Server-owned byte validation precedes any identity claim. Neither transport nor clocks are mixed. */
object RrPacketObservationBridge {
    fun verified(packet: RrPacketProvenance): RrPacketProvenance? =
        RrPacketProvenance.bytes(packet.rawHex)?.let { RrPacketProvenance.checked(it, packet.ts) }?.takeIf { it == packet }

    fun observations(packets: List<RrPacketProvenance>, legacy: List<RrInterval>, family: DeviceFamily,
                     userId: String, deviceId: String, firmware: String?): List<PhysiologyQuality.IntervalObservation>? {
        if (family != DeviceFamily.WHOOP5) return null
        val checked = packets.mapNotNull(::verified).distinctBy { it.packetId }
        // The device catalog describes current firmware, not firmware at historical capture.
        // The packet format does not carry that evidence; keep it unknown on both read paths.
        return PhysiologyQuality.packetOrLegacy(checked, legacy, deviceId, userId)
    }
}
