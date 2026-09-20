package com.noop.ble

import com.noop.protocol.DeviceFamily
import com.noop.push.SelfHostedPushSettingsTest
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RawHistoryArchiveIdentityTest {
    private val scope = RawHistoryArchive.ArchiveScope("owner-a", "source-a", "whoop-SERIAL", "AA:BB:CC:DD:EE:FF")
    private val hex = "aa50000c2f1900006800007dff2a6a20430900433103007e026502ba026c022eff70f996f879fad6fd8300d6017e0267027201be00290258030e05c507f00c030ead11cb15791500d2553c9003000000d6393716"
    private fun frame() = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test fun unownedGlobalArchiveCannotInsertIntoEnrolledStore() = runBlocking {
        val dir = Files.createTempDirectory("raw-archive-scope").toFile()
        try {
            val legacy = dir.resolve(RawHistoryArchive.REJECTED_ARCHIVE_FILE)
            legacy.writeText("""{"capturedAtMs":1,"trim":2,"family":"whoop4","frameHex":"$hex"}""")
            val original = legacy.readBytes()
            val archive = RawHistoryArchive(dir, SelfHostedPushSettingsTest.FakePushPrefs(), { scope })
            var inserts = 0
            assertEquals(0, archive.replayIfNeeded(scope.device, "v1") { _, _ -> inserts++; 1 })
            assertEquals(0, inserts)
            assertTrue(archive.readAll().isEmpty())
            assertArrayEquals(original, legacy.readBytes())
        } finally { dir.deleteRecursively() }
    }

    @Test fun onlySameOwnerInstallationAndPhysicalDeviceCanReplaySerializedFrames() = runBlocking {
        val dir = Files.createTempDirectory("raw-archive-scope").toFile()
        try {
            var current: RawHistoryArchive.ArchiveScope? = scope
            val archive = RawHistoryArchive(dir, SelfHostedPushSettingsTest.FakePushPrefs(), { current })
            assertTrue(archive.append(listOf(frame()), 2, DeviceFamily.WHOOP4).written)
            for (other in listOf(scope.copy(owner = "owner-b"), scope.copy(source = "source-b"),
                scope.copy(device = "whoop-OTHER"), scope.copy(physicalDevice = "11:22:33:44:55:66"))) {
                current = other
                assertTrue(archive.readAll().isEmpty())
                assertEquals(0, archive.replayIfNeeded(other.device, "v1") { _, _ -> error("cross-scope insert") })
            }
            current = scope
            assertArrayEquals(frame(), archive.readAll().single().first)
            var target: String? = null
            val count = archive.replayIfNeeded(scope.device, "v1") { decoded, device -> target = device; decoded.gravity.size }
            assertTrue(count > 0)
            assertEquals(scope.device, target)
            assertEquals(0, archive.replayIfNeeded(scope.device, "v1") { _, _ -> error("already replayed") })
            current = null
            assertTrue(runCatching { archive.append(listOf(frame()), 3, DeviceFamily.WHOOP4) }.isFailure)
        } finally { dir.deleteRecursively() }
    }
    @Test fun changedDestinationDuringReplayCannotInsertOrAdvanceItsMarker() = runBlocking {
        val dir = Files.createTempDirectory("raw-archive-race").toFile()
        try {
            var lookups = 0
            var changing = false
            val archive = RawHistoryArchive(dir, SelfHostedPushSettingsTest.FakePushPrefs(), {
                if (changing && ++lookups > 1) scope.copy(device = "whoop-OTHER") else scope
            })
            archive.append(listOf(frame()), 2, DeviceFamily.WHOOP4)
            changing = true
            assertEquals(0, archive.replayIfNeeded(scope.device, "v1") { _, _ -> error("stale destination") })
            changing = false
            assertTrue(archive.replayIfNeeded(scope.device, "v1") { decoded, _ -> decoded.gravity.size } > 0)
        } finally { dir.deleteRecursively() }
    }

}
