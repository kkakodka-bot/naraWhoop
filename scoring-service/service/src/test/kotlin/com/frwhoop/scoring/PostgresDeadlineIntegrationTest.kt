package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringInputGate
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.SocketTimeoutException
import java.sql.SQLException
import java.time.Duration
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Real pgJDBC socket deadlines and Hikari recovery, never an assumption from config strings. */
class PostgresDeadlineIntegrationTest {
    private fun databaseUrl(): String {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        return url
    }

    @Test fun defaultPoolAppliesFiniteDriverReadTimeout() {
        PostgresClient(databaseUrl()).use { db ->
            assertEquals("10", db.dataSource.dataSourceProperties.getProperty("connectTimeout"))
            assertEquals("5", db.dataSource.dataSourceProperties.getProperty("cancelSignalTimeout"))
            db.withConnection { connection ->
                // JDBC exposes the actual connection socket timeout in milliseconds.
                assertEquals(60_000, connection.networkTimeout)
                connection.createStatement().use { statement ->
                    statement.executeQuery("select 42").use { rows -> assertTrue(rows.next()); assertEquals(42, rows.getInt(1)) }
                }
            }
        }
    }

    @Test fun stalledReadAfterSeparateInputGateExpiresClosesConnectionAndPoolRecovers() {
        // Explicit operator URL options take precedence over default datasource properties.
        // One second exercises the real timeout path without a sixty-second test delay.
        PostgresClient(databaseUrl() + "?socketTimeout=1").use { db ->
            val user = UUID.randomUUID(); val device = UUID.randomUUID()
            db.withConnection { connection -> connection.createStatement().use { statement ->
                statement.execute("insert into auth.users values('$user')")
                statement.execute("insert into profiles(id,timezone) values('$user','UTC')")
                statement.execute("insert into devices(id,user_id) values('$device','$user')")
            } }
            var stalledBackend = 0
            try {
                val gated = ScoringInputGate(db, maximumDuration = Duration.ofMillis(150)).withGate(user, device) { guard ->
                    val started = System.nanoTime()
                    val error = assertThrows(SQLException::class.java) {
                        db.withConnection { connection ->
                            assertEquals(1_000, connection.networkTimeout)
                            connection.createStatement().use { statement ->
                                statement.executeQuery("select pg_backend_pid()").use { rows -> rows.next(); stalledBackend = rows.getInt(1) }
                                statement.executeQuery("select pg_sleep(20)").use { }
                            }
                        }
                    }
                    val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
                    assertTrue("read must time out before the twenty-second server query returns: ${elapsed}ms", elapsed in 500..7_000)
                    assertTrue(error.sqlState.orEmpty().startsWith("08"))
                    assertTrue(generateSequence<Throwable>(error) { it.cause }.any { it is SocketTimeoutException })
                    assertFalse("input gate expires independently of the stalled read", guard.active)
                    db.withConnection { connection -> connection.createStatement().use { statement ->
                        statement.executeQuery("select pg_backend_pid(),42").use { rows ->
                            assertTrue(rows.next())
                            assertNotEquals(stalledBackend, rows.getInt(1))
                            assertEquals(42, rows.getInt(2))
                        }
                    } }
                    true
                }
                assertEquals(true, gated)
                assertEquals(0, db.dataSource.hikariPoolMXBean.activeConnections)
            } finally {
                // Closing a client socket is not a promise of immediate server-side query
                // cancellation. Clean up only this disposable test backend if still asleep.
                if (stalledBackend != 0) db.withConnection { connection ->
                    connection.prepareStatement("select pg_cancel_backend(?)").use { statement ->
                        statement.setInt(1, stalledBackend); statement.execute()
                    }
                }
            }
        }
    }
}
