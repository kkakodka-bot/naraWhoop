package com.frwhoop.scoring.signals

import com.frwhoop.scoring.db.PostgresClient
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

class ModelWorkQueue(private val db: PostgresClient, val leaseSeconds: Int = 120) {
    init { require(leaseSeconds in 10..600) }
    data class Item(val jobId: UUID, val userId: UUID, val deviceId: UUID, val day: String,
                    val inputRevision: Long, val timezoneId: String, val modelId: String,
                    val activationRevision: Long, val leaseToken: UUID)

    fun activate(model: PhysiologyShadowRunner.Model): Long = db.withConnection { c ->
        c.prepareStatement("select public.physiology_activate_model(?,?)").use { p ->
            p.setString(1, model.activation.toString()); p.setString(2, checkpointHash(model))
            p.executeQuery().use { r -> check(r.next()); r.getLong(1) }
        }
    }

    fun claim(model: PhysiologyShadowRunner.Model): Item? = db.withConnection { c ->
        c.prepareStatement("select * from public.physiology_claim_model(?,?,?)").use { p ->
            p.setString(1, model.id); p.setString(2, activationHash(model)); p.setInt(3, leaseSeconds)
            p.executeQuery().use { r -> if (!r.next()) null else Item(r.getObject("job_id", UUID::class.java),
                r.getObject("user_id", UUID::class.java), r.getObject("device_id", UUID::class.java), r.getDate("day").toString(),
                r.getLong("input_revision"), r.getString("timezone_id"), r.getString("model_id"),
                r.getLong("activation_revision"), r.getObject("lease_token", UUID::class.java)) }
        }
    }

    fun renew(item: Item): Boolean = db.withConnection { c ->
        c.prepareStatement("select public.physiology_renew_model(?,?,?)").use { p ->
            p.setObject(1, item.jobId); p.setObject(2, item.leaseToken); p.setInt(3, leaseSeconds)
            p.executeQuery().use { r -> r.next() && r.getBoolean(1) }
        }
    }

    fun finish(item: Item, output: JSONObject? = null, failure: String? = null): Boolean = db.withConnection { c ->
        c.prepareStatement("select public.physiology_finish_model(?,?,?::jsonb,?)").use { p ->
            p.setObject(1, item.jobId); p.setObject(2, item.leaseToken); p.setString(3, output?.toString())
            p.setString(4, failure?.take(500))
            p.executeQuery().use { r -> r.next() && r.getBoolean(1) }
        }
    }

    companion object {
        fun activationHash(model: PhysiologyShadowRunner.Model): String = sha256(model.activation.toString())
        fun checkpointHash(model: PhysiologyShadowRunner.Model): String =
            model.activation.optJSONObject("assets")?.optJSONObject("weights")?.optString("sha256")
                ?.takeIf { it.matches(Regex("[0-9a-f]{64}")) } ?: sha256("no-checkpoint:${model.id}")
        private fun sha256(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
}
