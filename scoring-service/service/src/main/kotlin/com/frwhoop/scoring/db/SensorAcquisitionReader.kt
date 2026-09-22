package com.frwhoop.scoring.db

import com.frwhoop.scoring.signals.SensorAcquisitionProof
import java.sql.Connection
import java.util.UUID

object SensorAcquisitionReader {
    data class Evidence(val receipts: List<SensorAcquisitionProof.Receipt>, val reason: String? = null)
    fun objectIds(evidence: Evidence): Set<UUID> = evidence.receipts.asSequence().filter { it.kind in setOf("ppg","imu") }
        .flatMap { receipt -> runCatching {
            val records=org.json.JSONObject(receipt.bytes.toString(Charsets.UTF_8)).getJSONArray("records")
            require(records.length()<=300)
            (0 until records.length()).map { UUID.fromString(records.getJSONObject(it).getString("object_id")) }.distinct().also { require(it.size<=8) }
        }.getOrDefault(emptyList()).asSequence() }.distinct().take(2048).toSet()
    fun load(connection: Connection, user: UUID, device: UUID, start: Long, end: Long): Evidence {
        var truncated = false
        val receipts = mutableListOf<SensorAcquisitionProof.Receipt>()
        connection.prepareStatement("""
            with sizes as (
              select user_id,device_id,kind,scope_start_s,scope_end_s,contract_sha256,
                sum(octet_length(contract_bytes)) over(order by scope_start_s desc,kind,contract_sha256) as bytes_through,
                row_number() over(order by scope_start_s desc,kind,contract_sha256) as ordinal,
                sum(octet_length(contract_bytes)) over() as total_bytes,count(*) over() as total_rows
              from public.sensor_acquisition_contracts
              where user_id=? and device_id=? and scope_start_s<? and scope_end_s>? and revoked_at is null
            ) select s.kind,s.scope_start_s,s.scope_end_s,s.contract_sha256,c.contract_bytes,
                (s.total_bytes>8388608 or s.total_rows>1024) as truncated
              from sizes s join public.sensor_acquisition_contracts c using(user_id,device_id,kind,scope_start_s,contract_sha256)
              where s.bytes_through<=8388608 and s.ordinal<=1024 order by s.scope_start_s desc,s.kind,s.contract_sha256
        """.trimIndent()).use { q ->
            q.fetchSize = 1
            q.setObject(1,user); q.setObject(2,device); q.setLong(3,end); q.setLong(4,start)
            q.executeQuery().use { rows -> while (rows.next()) {
                val data = rows.getBytes("contract_bytes"); truncated = rows.getBoolean("truncated")
                receipts += SensorAcquisitionProof.Receipt(rows.getString("kind"), rows.getLong("scope_start_s"),
                    rows.getLong("scope_end_s"),rows.getString("contract_sha256"),data)
            } }
        }
        return Evidence(receipts,if(truncated) "acquisition_proof_budget_exceeded" else null)
    }
}
