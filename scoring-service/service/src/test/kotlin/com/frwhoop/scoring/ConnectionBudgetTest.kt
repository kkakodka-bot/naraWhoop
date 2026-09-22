package com.frwhoop.scoring

import com.frwhoop.scoring.db.ConnectionBudget
import org.junit.Assert.*
import org.junit.Test

class ConnectionBudgetTest {
    @Test fun budgetsEveryReplicaAndReservedConnections() {
        assertEquals(4, ConnectionBudget(4,6,40,16).poolSize)
        for (budget in listOf({ ConnectionBudget(4,7,40,16) }, { ConnectionBudget(3,1,20,8) },
            { ConnectionBudget(32,128,100,8) }, { ConnectionBudget.fromEnvironment(mapOf("SCORING_DB_POOL_SIZE" to "invalid")) })) {
            assertThrows(IllegalArgumentException::class.java) { budget() }
        }
    }
    @Test fun automaticReplicaIdentitiesAreDistinctAndStillVerifyPackagedSource() {
        val revision="a".repeat(40)
        val config=ScoringConfig("postgresql://localhost/fixture","fixture","http://localhost","fixture",
            workerInstanceId="auto",workerSourceRevision=revision)
        assertNotEquals(config.workerIdentity { revision }.workerInstanceId,config.workerIdentity { revision }.workerInstanceId)
        assertThrows(IllegalArgumentException::class.java) { config.workerIdentity { "b".repeat(40) } }
    }
}
