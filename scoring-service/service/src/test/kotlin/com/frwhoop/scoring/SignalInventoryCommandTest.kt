package com.frwhoop.scoring

import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class SignalInventoryCommandTest {
    private val environment = mapOf("INVENTORY_USER_ID" to UUID.randomUUID().toString(),
        "INVENTORY_DEVICE_ID" to UUID.randomUUID().toString(), "INVENTORY_DAY" to "2026-09-18")

    @Test fun explicitOwnerDeviceAndDateAreRequiredWithoutScoringSecrets() {
        val value = SignalInventoryCommand.request(environment)
        assertEquals(environment["INVENTORY_USER_ID"], value.user.toString())
        assertEquals(environment["INVENTORY_DEVICE_ID"], value.device.toString())
        assertEquals("2026-09-18", value.day)
        assertNull(value.window)
        for (key in environment.keys) assertThrows(IllegalStateException::class.java) {
            SignalInventoryCommand.request(environment - key)
        }
    }

    @Test fun optionalNightWindowRetainsHalfOpenWholeSecondBounds() {
        val value = SignalInventoryCommand.request(environment + mapOf("INVENTORY_START" to "2026-09-17T22:00:00Z", "INVENTORY_END" to "2026-09-18T07:00:00Z"))
        assertEquals(9 * 3600L, value.window!!.second - value.window.first)
    }

    @Test fun PartialFractionalOrReversedBoundsCannotBeSilentlyCoerced() {
        for (extra in listOf(mapOf("INVENTORY_START" to "2026-09-17T22:00:00Z"),
            mapOf("INVENTORY_START" to "2026-09-17T22:00:00.001Z", "INVENTORY_END" to "2026-09-18T07:00:00Z"),
            mapOf("INVENTORY_START" to "2026-09-18T22:00:00Z", "INVENTORY_END" to "2026-09-18T07:00:00Z"))) {
            assertThrows(IllegalArgumentException::class.java) { SignalInventoryCommand.request(environment + extra) }
        }
    }

    @Test fun unknownOrCombinedCommandsFailBeforeScoringInitialization() {
        for (arguments in listOf(arrayOf("--inventory-signal"), arrayOf("--inventory-signals", "--replay-day"))) {
            assertThrows(IllegalArgumentException::class.java) { main(arguments) }
        }
    }
}
