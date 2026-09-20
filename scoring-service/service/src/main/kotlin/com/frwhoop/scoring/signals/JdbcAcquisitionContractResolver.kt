package com.frwhoop.scoring.signals

import javax.sql.DataSource

/** Read-only access to operator-issued immutable acquisition receipts, never qualifications inferred from NPB1. */
class JdbcAcquisitionContractResolver(private val dataSource: DataSource) : VerifiedModelJobAssembler.ContractResolver {
    override fun resolve(model: PhysiologyShadowRunner.Model, request: PhysiologyShadowRunner.Request): VerifiedModelJobAssembler.Receipt? {
        val revision = request.inputRevision.toLongOrNull() ?: return null
        val checkpoint = ModelWorkQueue.checkpointHash(model)
        return dataSource.connection.use { connection ->
            connection.prepareStatement("""
                SELECT contract_sha256, contract_bytes FROM public.physiology_model_acquisition_contracts
                WHERE user_id=? AND device_id=? AND input_revision=? AND scope_start_s=? AND scope_end_s=?
                  AND model_id=? AND checkpoint_sha256=? AND preprocess_version=? AND quality_policy_version=?
            """.trimIndent()).use { statement ->
                statement.queryTimeout = 10
                statement.setObject(1, request.userId); statement.setObject(2, request.deviceId)
                statement.setLong(3, revision); statement.setLong(4, request.start); statement.setLong(5, request.end)
                statement.setString(6, model.id); statement.setString(7, checkpoint)
                statement.setString(8, model.activation.getString("preprocess_version"))
                statement.setString(9, model.activation.getString("quality_policy_version"))
                statement.executeQuery().use { rows ->
                    if (!rows.next()) null else VerifiedModelJobAssembler.Receipt(rows.getBytes("contract_bytes"), rows.getString("contract_sha256"))
                }
            }
        }
    }
}
