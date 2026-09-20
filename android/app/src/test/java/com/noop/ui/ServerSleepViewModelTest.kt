package com.noop.ui

import com.noop.push.*
import org.junit.Assert.*
import org.junit.Test

class ServerSleepViewModelTest {
    private fun cache(available: Boolean = true, type: String = "nap") = ServerScoreDayCache(
        day = "2026-09-18", algorithmVersion = "frwhoop-physiology-2", daily = null,
        nights = listOf(ServerScoreNightCache("night", "2026-09-18T14:00:00Z", "2026-09-18T14:01:30Z", true,
            asleepMin = 0.0, episodeType = type, mainSleepGroupId = "canonical-group", measurementAvailable = available)),
        computedAt = null, stale = false, fetchedAtMs = 0,
        features = mapOf("sleep" to ServerScoreFeatureCache("fresh", null, "device", "sleep-v2", null, null, null, null, null, null, null)))
    @Test fun canonicalStatesDoNotBecomeLightSleep() {
        assertEquals("unknown", serverSleepState("light", "state_unknown"))
        assertEquals("sleep_unstaged", serverSleepState("unknown", "sleep_unstaged"))
        assertEquals("off_body", serverSleepState("light", "off_body"))
        assertEquals("deep", serverSleepState("deep", "sleep"))
    }
    @Test fun eventTimeZonesSurviveCodecAndDoNotUseTheCurrentPhoneZone() {
        val body="""{"server_scoring":{"schema_version":2,"user_id":"owner","day":"2026-09-18",
            "algorithm_version":"frwhoop-physiology-2","features":{"sleep":{"status":"available",
            "device_id":"device","algorithm_version":"frwhoop-physiology-2"}},"nights":[{"id":"night",
            "device_id":"device","start_at":"2026-09-18T14:00:00Z","end_at":"2026-09-18T14:01:30Z",
            "start_timezone_id":"America/Los_Angeles","end_timezone_id":"America/New_York","stages":[]}]}}"""
        val parsed=ServerScoreClient.parseSnapshot(body,"2026-09-18","owner")
        val restored=ServerScoreClient.parseSnapshot(parsed.rawSnapshotJSON!!,parsed.day,parsed.ownerId)
        val episode=serverSleepEpisodes(restored,restored.day).single()
        assertEquals("America/Los_Angeles",episode.startTimezoneId)
        assertEquals("America/New_York",episode.endTimezoneId)
        assertTrue(episode.clockLabel.contains("07:00 -07:00 (America/Los_Angeles)"))
        assertTrue(episode.clockLabel.contains("10:01 -04:00 (America/New_York)"))
        assertTrue(ServerSleepEpisode.eventClock(episode.start,null).contains("UTC; event zone unavailable"))
        assertTrue(ServerSleepEpisode.eventClock(episode.start,"invalid-zone").contains("UTC; event zone unavailable"))
    }
    @Test fun missingEpochsNeverCreateTimelineAndCanonicalNapSurvives() {
        val value = cache()
        val episode = serverSleepEpisodes(value, value.day).single()
        assertTrue(episode.bands.isEmpty())
        assertEquals("nap", episode.episodeType)
        assertEquals("canonical-group", episode.groupId)
        assertEquals("No server epochs available", episode.reason)
        assertEquals(0.0, episode.asleepMin!!, 0.0)
        assertTrue(serverSleepEpisodes(value, "2026-09-17").isEmpty())
    }
    @Test fun unavailableIsNotZeroAndAfternoonMainRemainsMain() {
        val value = cache(false, "main_sleep")
        val episode = serverSleepEpisodes(value, value.day).single()
        assertNull(episode.asleepMin)
        assertEquals("main_sleep", episode.episodeType)
    }
    @Test fun opportunityLabelsNeverClaimUnconfirmedBedOccupancy() {
        for (kind in listOf(null, "estimated_sleep_opportunity", "user_reported_sleep_opportunity", "unrecognized")) {
            val base = cache()
            val value = base.copy(nights = listOf(base.nights.single().copy(opportunityKind = kind)))
            val episode = serverSleepEpisodes(value, value.day).single()
            assertEquals(kind, episode.opportunityKind)
            assertEquals(if (kind == "user_reported_sleep_opportunity") "Reported sleep opportunity" else
                "Estimated sleep opportunity", episode.opportunityLabel)
            assertFalse(episode.opportunityLabel.lowercase().contains("in bed"))
        }
    }
    @Test fun epochTimesAndMissingGapRemainUnmodified() {
        val start = java.time.Instant.parse("2026-09-18T14:00:00Z").epochSecond
        fun band(a: Long, b: Long, state: String) = ServerScoreStageCache(a, b, "unknown", state,
            null, null, null, null, null, null, null, null, null, null)
        val base = cache()
        val value = base.copy(nights = listOf(base.nights.single().copy(stages = listOf(
            band(start, start + 30, "sleep_unstaged"), band(start + 60, start + 90, "off_body")))))
        val episode = serverSleepEpisodes(value, value.day).single()
        assertEquals(listOf("sleep_unstaged", "off_body"), episode.bands.map { it.state })
        assertEquals(listOf(start, start + 60), episode.bands.map { it.start })
        assertEquals(60L, episode.bands.sumOf { it.end - it.start })
        assertEquals(90L, episode.end - episode.start)
    }

    @Test fun legacyDatabaseRowThroughCodecPreservesBaselineStagesAndTotals() {
        val start = java.time.Instant.parse("2026-09-18T14:00:00Z").epochSecond
        val body = """
        {"server_scoring":{"schema_version":2,"user_id":"owner","day":"2026-09-18","algorithm_version":"per_feature",
        "features":{"sleep":{"status":"fresh","device_id":"device","algorithm_version":"frwhoop-server-1",
        "required_revision":4,"processing_status":"pending","timezone_id":"UTC","timezone_ids":["UTC","America/Los_Angeles"]}},
        "nights":[{"id":"night","device_id":"device","algorithm_version":"frwhoop-server-1","start_at":"2026-09-18T14:00:00Z",
        "end_at":"2026-09-18T14:01:30Z","is_nap":true,"asleep_min":1,"in_bed_min":1.5,
        "stages":[{"start":$start,"end":${start+30},"stage":"wake"},{"start":${start+30},"end":${start+60},"stage":"deep"},
        {"start":${start+60},"end":${start+90},"stage":"rem"}]}]}}
        """.trimIndent()
        val value = ServerScoreClient.parseSnapshot(body, "2026-09-18", "owner", 1000)
        val episode = serverSleepEpisodes(value, value.day).single()
        assertEquals(listOf("wake", "deep", "rem"), episode.bands.map { it.state })
        assertEquals(1.0, episode.asleepMin!!, 0.0)
        assertEquals("nap", episode.episodeType)
        assertEquals("State coverage: unavailable", value.nights.single().stateCoverageDescription)
        assertTrue(value.nights.single().stages.all { it.evidenceCoverage == null && it.sleepProbability == null && it.reason == "legacy_quality_unavailable" })
        assertTrue(value.sleepMetadataLines.contains("Legacy baseline · quality and evidence coverage unavailable"))
        assertTrue(value.sleepMetadataLines.contains("Fetched: 1970-01-01T00:00:01Z"))
        assertTrue(value.sleepMetadataLines.contains("Observed through: unavailable"))
        assertTrue(value.sleepMetadataLines.contains("Processing: pending · archive: unavailable"))
        assertTrue(value.sleepMetadataLines.contains("Time zones: UTC · America/Los_Angeles"))
        val v2 = ServerScoreClient.parseSnapshot(body.replace("frwhoop-server-1", "frwhoop-physiology-2"), value.day, "owner")
        val unknown = serverSleepEpisodes(v2, v2.day).single()
        assertNull(unknown.asleepMin)
        assertEquals(listOf("unknown", "unknown", "unknown"), unknown.bands.map { it.state })
        val explicit = ServerScoreClient.parseSnapshot(body.replace("\"stage\":\"deep\"", "\"stage\":\"deep\",\"state\":\"state_unknown\"")
            .replace("\"asleep_min\":1", "\"asleep_min\":1,\"measurement_available\":false"), value.day, "owner")
        assertNull(serverSleepEpisodes(explicit, explicit.day).single().asleepMin)
        assertEquals("unknown", serverSleepEpisodes(explicit, explicit.day).single().bands[1].state)
    }
}
