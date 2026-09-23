import XCTest
@testable import WhoopStore

final class ServerCanonicalCompatibilityTests: XCTestCase {
    private let owner = "10000000-0000-4000-8000-000000000001"
    private let source = "10000000-0000-4000-8000-000000000002"
    private let device = "10000000-0000-4000-8000-000000000003"
    private let project = "https://compatibility-test.supabase.co"
    private let day = "2026-09-21"
    private let algorithm = "frwhoop-physiology-2"
    private let manifest = String(repeating: "a", count: 64)
    private let featureManifest = String(repeating: "b", count: 64)
    private let resultRevision = "sha256:" + String(repeating: "c", count: 64)

    private func document() -> [String: Any] {
        let start = 1_789_948_800
        let night: [String: Any] = [
            "id": "20000000-0000-4000-8000-000000000001", "user_id": owner, "device_id": device,
            "algorithm_version": algorithm, "start_at": "2026-09-21T00:00:00Z",
            "end_at": "2026-09-21T01:00:00Z", "is_nap": false, "measurement_available": true,
            "asleep_min": 0, "in_bed_min": 60, "awake_min": 0, "light_min": 0,
            "deep_min": 0, "rem_min": 0, "efficiency": 0, "hrv_rmssd_ms": 0,
            "resting_hr_bpm": 0, "resp_rate_bpm": 14.2,
            "stages": [["start": start, "end": start + 30, "stage": "light", "state": "sleep"]],
        ]
        let override: [String: Any] = [
            "id": "20000000-0000-4000-8000-000000000002", "device_id": device,
            "original_start": start, "original_end": start + 3_600, "start": start,
            "end": start + 3_600, "tombstone": false, "revision": 1,
        ]
        let measurement: [String: Any] = [
            "measurement_schema_version": 1, "feature": "hrv", "user_id": owner, "device_id": device,
            "start": start, "end": start + 300, "metric": "rmssd", "unit": "ms", "input_revision": "42",
            "observed_rmssd_ms": 0, "measurement_valid": true, "reason": NSNull(), "context": "quiet_rest",
            "baseline_eligible": true, "source": "whoop5", "modality": "ppg_prv",
            "algorithm_version": "rmssd-5m-v2", "observed_time_fraction": 1,
        ]
        let respirationSummary: [String: Any] = [
            "median_bpm": 14.2, "mean_bpm": 14.2, "distribution_bpm": [14.2],
            "accepted_seconds": 1_800, "coverage": 0.75, "accepted_windows": 3, "total_windows": 3,
            "context": "main_sleep", "method_version": "resp-spectrum-acf-2",
            "calibration_status": "not_reference_validated", "quality_policy_version": "resp-quality-2",
            "coverage_by_third": [0.2, 0.3, 0.25], "rejection_reasons": [], "evidence_strength": 0.8,
        ]
        let fullDayEpochs: [[String: Any]] = [[
            "start": start, "end": start + 30, "stage": "unknown", "state": "state_unknown",
        ]]
        let compatibility: [String: Any] = [
            "sleep_onset_at": NSNull(), "wake_onset_at": NSNull(), "sleep_unstaged_min": 0,
            "state_unknown_min": NSNull(), "off_body_min": 0, "main_sleep_group_id": NSNull(),
            "opportunity_kind": "estimated_sleep_opportunity", "full_day_sleep_epochs": fullDayEpochs,
        ]
        var daily = compatibility
        daily.merge([
            "hrv_rmssd_ms": 0, "hrv_sdnn_ms": 0, "resting_hr_bpm": 0,
            "sleep_total_min": 0, "sleep_in_bed_min": 60, "sleep_awake_min": 0,
            "sleep_light_min": 0, "sleep_deep_min": 0, "sleep_rem_min": 0,
            "sleep_efficiency": 0, "disturbances": 0, "resp_rate_bpm": 14.2,
            "recovery": 0, "strain": 0, "spo2_pct": 97, "skin_temp_c": 0,
            "skin_temp_dev_c": 0, "rest": 88, "overnight_hr_bpm": 55,
            "hrv_summary": ["median_ms": 0], "heart_rate_windows": [],
            "respiration_summary": respirationSummary,
        ], uniquingKeysWith: { _, new in new })

        var families: [String: [String: Any]] = [:]
        for (name, metrics) in ServerCanonicalResults.familyMetrics {
            families[name] = [
                "owner": "server", "metrics": metrics.sorted(), "status": "unqualified",
                "reason": "reference_required", "result_revision": NSNull(), "input_revision": NSNull(),
                "algorithm_version": "vps-only-1", "configuration_version": "vps-only-1",
                "manifest_hash": NSNull(), "feature_manifest_hash": NSNull(), "canonical_qualification": NSNull(),
                "project": project, "owner_id": owner, "source_id": source, "device_id": device,
                "window": day, "timezone_id": "UTC", "computed_at": NSNull(), "observed_through": NSNull(),
                "freshness": "unavailable",
                "values": Dictionary(uniqueKeysWithValues: metrics.map { ($0, NSNull() as Any) }),
                "details": [String: Any](),
            ]
        }
        func authorize(_ name: String, status: String = "available", values: [String: Any], details: [String: Any]) {
            var family = families[name]!
            var allValues = family["values"] as! [String: Any]
            allValues.merge(values, uniquingKeysWith: { _, new in new })
            family["status"] = status
            family["reason"] = status == "available" ? NSNull() : "qualified_closed_window_required"
            family["result_revision"] = resultRevision; family["input_revision"] = 42
            family["algorithm_version"] = algorithm; family["configuration_version"] = "config-1"
            family["manifest_hash"] = manifest; family["feature_manifest_hash"] = featureManifest
            family["canonical_qualification"] = "signed_reference_approval"
            family["computed_at"] = "2026-09-21T02:00:00Z"; family["observed_through"] = "2026-09-21T01:00:00Z"
            family["freshness"] = "current"; family["values"] = allValues; family["details"] = details
            families[name] = family
        }
        authorize("night_hrv", values: ["hrv_rmssd_ms": 0, "hrv_sdnn_ms": 0, "resting_hr_bpm": 0],
            details: ["summary": ["median_ms": 0], "heart_rate_windows": []])
        authorize("current_hrv", status: "insufficient_quality", values: [:], details: ["measurements": [measurement]])
        authorize("sleep", values: [
            "sleep_total_min": 0, "sleep_in_bed_min": 60, "sleep_awake_min": 0,
            "sleep_light_min": 0, "sleep_deep_min": 0, "sleep_rem_min": 0,
            "sleep_efficiency": 0, "disturbances": 0, "sleep_sessions": [night],
        ], details: ["nights": [night], "sleep_overrides": [override], "daily_compatibility": compatibility])
        authorize("respiration", values: ["resp_rate_bpm": 14.2], details: ["summary": respirationSummary])
        authorize("recovery", values: ["recovery": 0], details: [:])
        authorize("strain_energy", values: ["strain": 0], details: [:])
        authorize("oxygen", values: ["spo2_pct": 97], details: [:])
        authorize("temperature", values: ["skin_temp_c": 0, "skin_temp_dev_c": 0], details: [:])

        let feature: [String: Any] = [
            "status": "available", "device_id": device, "algorithm_version": algorithm, "input_revision": 42,
            "manifest_hash": manifest, "feature_manifest_hash": featureManifest,
            "canonical_qualification": "signed_reference_approval", "computed_at": "2026-09-21T02:00:00Z",
            "observed_through": "2026-09-21T01:00:00Z", "supports_boundary_overrides": true,
        ]
        let compute: [String: Any] = [
            "mode": "final_hosted", "policy_version": "vps-only-1", "project": project,
            "owner_id": owner, "source_id": source, "device_id": device, "day": day, "families": families,
        ]
        return ["server_scoring": [
            "schema_version": 2, "contract_revision": 2, "user_id": owner, "day": day,
            "algorithm_version": "per_feature", "features": ["hrv": feature, "sleep": feature, "respiration": feature],
            "daily": daily, "nights": [night], "measurements": [measurement, ["feature": "respiration", "value": 99]],
            "sleep_overrides": [override], "computed_at": "2026-09-21T02:00:00Z", "stale": false,
            "compute": compute,
        ]]
    }

    private func legacyDocument(marker: [String: Any]? = nil) throws -> [String: Any] {
        func rewrite(_ value: Any, key: String? = nil) -> Any {
            if let value = value as? [String: Any] { return value.mapValues { $0 }.reduce(into: [String: Any]()) { $0[$1.key] = rewrite($1.value, key: $1.key) } }
            if let value = value as? [Any] { return value.map { rewrite($0) } }
            if key == "algorithm_version", value as? String == algorithm { return "frwhoop-server-1" }
            if key == "canonical_qualification", value as? String == "signed_reference_approval" { return "retained_legacy" }
            if ["resting_hr_bpm", "overnight_hr_bpm"].contains(key ?? "") { return 53 }
            if ["hrv_rmssd_ms", "hrv_sdnn_ms"].contains(key ?? "") { return 37 }
            if ["sleep_total_min", "asleep_min"].contains(key ?? "") { return 42 }
            return value
        }
        var root = rewrite(document()) as! [String: Any]
        if let marker {
            root = editFamily(root, "sleep") { family in
                var details = family["details"] as! [String: Any]
                details["input_eligibility"] = marker; family["details"] = details
            }
        }
        return root
    }

    func testLegacyUnqualifiedBeatResultsAreWithheldAtEveryReadWhileHeartRateSurvives() throws {
        let cache = try decode(legacyDocument())
        XCTAssertNil(cache.daily?.hrvRmssdMs)
        XCTAssertNil(cache.daily?.respRateBpm)
        XCTAssertNil(cache.daily?.recovery)
        XCTAssertNil(cache.daily?.sleepTotalMin)
        XCTAssertEqual(cache.daily?.restingHrBpm, 53)
        XCTAssertEqual(cache.daily?.sleepInBedMin, 60)
        XCTAssertEqual(cache.nights.first?.restingHrBpm, 53)
        XCTAssertEqual(cache.nights.first?.inBedMin, 60)
        XCTAssertEqual(cache.nights.first?.startAt, "2026-09-21T00:00:00Z")
        XCTAssertNil(cache.nights.first?.asleepMin)
        XCTAssertNil(cache.nights.first?.hrvRmssdMs)
        XCTAssertEqual(cache.nights.first?.measurementAvailable, false)
        XCTAssertTrue(cache.nights.first?.stages.isEmpty == true)
        XCTAssertTrue(cache.fullDaySleepEpochs?.isEmpty == true)
        let hrv = try XCTUnwrap(cache.canonicalResults?.families["night_hrv"])
        XCTAssertNil(hrv.number("hrv_rmssd_ms"))
        XCTAssertEqual(hrv.number("resting_hr_bpm"), 53)
        XCTAssertEqual(hrv.details["summary"], .null)
        guard case .object(let missing) = hrv.details["metric_availability"] else { return XCTFail("missing metric disposition") }
        XCTAssertEqual(missing["hrv_rmssd_ms"], .object(["status": .string("unqualified"), "reason": .string("beat_timing_unverified")]))
        XCTAssertNil(missing["resting_hr_bpm"])
        XCTAssertEqual(cache.canonicalResults?.families["respiration"]?.status, "unqualified")
        XCTAssertEqual(cache.canonicalResults?.families["recovery"]?.reason, "beat_timing_unverified")
        XCTAssertTrue(ServerHrvSeries.from(cache, day: day).windows.isEmpty)
        XCTAssertNil(ServerRespirationSummary.project(cache, day: day)?.breathsPerMinute)
    }

    func testExactImmutableRRExcludedMarkerPermitsSleepOnlyAndInvalidMarkersDoNot() throws {
        let marker = ["policy_version": "legacy-rr-excluded-1", "rr_input": "excluded"]
        let cache = try decode(legacyDocument(marker: marker))
        XCTAssertEqual(cache.daily?.sleepTotalMin, 42)
        XCTAssertEqual(cache.nights.first?.asleepMin, 42)
        XCTAssertEqual(cache.nights.first?.stages.count, 1)
        XCTAssertEqual(cache.fullDaySleepEpochs?.count, 1)
        XCTAssertNil(cache.daily?.hrvRmssdMs)
        XCTAssertNil(cache.daily?.respRateBpm)
        XCTAssertNil(cache.daily?.recovery)
        XCTAssertNil(cache.nights.first?.hrvRmssdMs)
        for invalid: [String: Any] in [
            ["policy_version": "legacy-rr-excluded-1", "rr_input": "included"],
            ["policy_version": "other", "rr_input": "excluded"],
            ["policy_version": "legacy-rr-excluded-1", "rr_input": "excluded", "invented_qualification": true]
        ] {
            XCTAssertNil(try decode(legacyDocument(marker: invalid)).daily?.sleepTotalMin)
        }
    }

    func testDirectCanonicalDecoderCannotRestoreLegacyValuesOrNestedDetails() throws {
        let root = try legacyDocument(), score = root["server_scoring"] as! [String: Any]
        let canonical = try JSONDecoder().decode(ServerCanonicalResults.self,
            from: JSONSerialization.data(withJSONObject: score["compute"]!))
        try canonical.validate(owner: owner, day: day)
        XCTAssertEqual(canonical.families["night_hrv"]?.number("resting_hr_bpm"), 53)
        XCTAssertNil(canonical.families["night_hrv"]?.number("hrv_rmssd_ms"))
        XCTAssertEqual(canonical.families["current_hrv"]?.details["measurements"], .array([]))
        guard case .array(let nights) = canonical.families["sleep"]?.values["sleep_sessions"],
              case .object(let night) = nights.first else { return XCTFail("missing retained episode") }
        XCTAssertEqual(night["asleep_min"], .null)
        XCTAssertEqual(night["hrv_rmssd_ms"], .null)
        XCTAssertEqual(night["resting_hr_bpm"], .number(53))
        XCTAssertEqual(night["stages"], .array([]))
        XCTAssertEqual(night["measurement_unavailable_reason"], .string("beat_timing_unverified"))
    }

    func testActualWhoopStoreOfflineOldPayloadWithAndWithoutRawSnapshotKeepsEligibleScopedResults() async throws {
        let store = try await WhoopStore.inMemory()
        let persistence = ServerScoreCacheStore(db: store.registryWriter)
        let document = try legacyDocument()
        let decoded = try decode(document)
        let original = String(data: try JSONSerialization.data(withJSONObject: document), encoding: .utf8)!
        for retainRaw in [false, true] {
            var night = ServerScoreNightCache(id: "old", startAt: "2026-09-21T00:00:00Z", endAt: "2026-09-21T01:00:00Z",
                isNap: false, asleepMin: 42, inBedMin: 60, hrvRmssdMs: 37, restingHrBpm: 53)
            night.measurementAvailable = true
            var old = ServerScoreDayCache(day: day, algorithmVersion: "frwhoop-server-1",
                daily: ServerScoreDailyCache(recovery: 84, hrvRmssdMs: 37, restingHrBpm: 53,
                    sleepTotalMin: 42, sleepInBedMin: 60, respRateBpm: 14.2), nights: [night],
                computedAt: decoded.computedAt, stale: true, fetchedAt: Date())
            old.ownerId = owner; old.features = decoded.features
            let score = document["server_scoring"] as! [String: Any]
            old.canonicalResults = try JSONDecoder().decode(ServerCanonicalResults.self,
                from: JSONSerialization.data(withJSONObject: score["compute"]!))
            old.rawSnapshotJSON = retainRaw ? original : nil
            // Codable retains the pre-repair bytes: read eligibility must not depend on a rewrite.
            let stored = String(data: try JSONEncoder().encode(old), encoding: .utf8)!
            XCTAssertTrue(stored.contains("\"hrvRmssdMs\":37"))
            try persistence.upsert(old)
            let loaded = try XCTUnwrap(persistence.load(ownerId: owner, day: day, scopeKey: old.scopeKey, deviceId: device))
            XCTAssertNil(loaded.daily?.hrvRmssdMs)
            XCTAssertNil(loaded.daily?.respRateBpm)
            XCTAssertNil(loaded.daily?.recovery)
            XCTAssertNil(loaded.daily?.sleepTotalMin)
            XCTAssertEqual(loaded.daily?.restingHrBpm, 53)
            XCTAssertEqual(loaded.daily?.sleepInBedMin, 60)
            XCTAssertNil(loaded.nights.first?.hrvRmssdMs)
            XCTAssertNil(loaded.nights.first?.asleepMin)
            XCTAssertEqual(loaded.nights.first?.restingHrBpm, 53)
            XCTAssertNil(try persistence.load(ownerId: source, day: day))
            XCTAssertNil(try persistence.load(ownerId: owner, day: day, deviceId: source))
        }
    }

    func testSameHashEligibilityRefreshDoesNotBlockReadRepairOrPermitRetainedValueMutation() throws {
        let document = try legacyDocument()
        let fresh = try decode(document)
        let score = document["server_scoring"] as! [String: Any]
        var old = fresh
        old.canonicalResults = try JSONDecoder().decode(ServerCanonicalResults.self,
            from: JSONSerialization.data(withJSONObject: score["compute"]!))
        XCTAssertTrue(ServerComputeRevisionFence.admits(previous: old, next: fresh),
            "The immutable result hash remains unchanged by a read eligibility policy")
        for (family, key) in [("night_hrv", "resting_hr_bpm"), ("sleep", "sleep_in_bed_min")] {
            let changed = editFamily(document, family) { row in
                var values = row["values"] as! [String: Any]; values[key] = 99; row["values"] = values
            }
            var next = fresh
            let score = changed["server_scoring"] as! [String: Any]
            next.canonicalResults = try JSONDecoder().decode(ServerCanonicalResults.self,
                from: JSONSerialization.data(withJSONObject: score["compute"]!))
            XCTAssertFalse(ServerComputeRevisionFence.admits(previous: old, next: next), key)
        }
        let marked = try decode(legacyDocument(marker: ["policy_version": "legacy-rr-excluded-1", "rr_input": "excluded"]))
        XCTAssertFalse(ServerComputeRevisionFence.admits(previous: old, next: marked),
            "An input receipt cannot change under the same immutable hash")
        let qualified = try decode(self.document())
        let changedV2 = editFamily(self.document(), "night_hrv") { row in
            var values = row["values"] as! [String: Any]; values["hrv_rmssd_ms"] = 99; row["values"] = values
        }
        var qualifiedMutation = qualified
        let changedScore = changedV2["server_scoring"] as! [String: Any]
        qualifiedMutation.canonicalResults = try JSONDecoder().decode(ServerCanonicalResults.self,
            from: JSONSerialization.data(withJSONObject: changedScore["compute"]!))
        XCTAssertFalse(ServerComputeRevisionFence.admits(previous: qualified, next: qualifiedMutation))
    }

    func testLegacyMaskingPreservesAuthorizationRejectionAndRevocationReason() throws {
        for (key, value): (String, Any) in [("canonical_qualification", NSNull()),
            ("manifest_hash", NSNull()), ("manifest_hash", "invalid")] {
            let malformed = editFamily(try legacyDocument(), "recovery") { $0[key] = value }
            XCTAssertThrowsError(try decode(malformed), key)
        }
        let revoked = editFamily(try legacyDocument(), "recovery") {
            $0["status"] = "revoked"; $0["reason"] = "approval_revoked"
        }
        let family = try XCTUnwrap(try decode(revoked).canonicalResults?.families["recovery"])
        XCTAssertEqual(family.status, "revoked")
        XCTAssertEqual(family.reason, "approval_revoked")
        XCTAssertNil(family.number("recovery"))
    }

    func testConstructedMixedFamilyCacheKeepsQualifiedSleepWhileWithholdingLegacyNestedHRV() throws {
        let qualified = try decode(document()), legacy = try decode(legacyDocument())
        var night = ServerScoreNightCache(id: "mixed", startAt: "2026-09-21T00:00:00Z", endAt: "2026-09-21T01:00:00Z",
            isNap: false, asleepMin: 42, inBedMin: 60, hrvRmssdMs: 37, restingHrBpm: 53)
        night.respRateBpm = 14.2
        var mixed = ServerScoreDayCache(day: day, algorithmVersion: "per_feature",
            daily: ServerScoreDailyCache(recovery: 84, hrvRmssdMs: 37, restingHrBpm: 53,
                sleepTotalMin: 42, sleepInBedMin: 60, respRateBpm: 14.2), nights: [night],
            computedAt: qualified.computedAt, stale: false, fetchedAt: Date())
        mixed.ownerId = owner; mixed.features = qualified.features
        mixed.features["hrv"] = legacy.features["hrv"]
        XCTAssertNil(mixed.daily?.hrvRmssdMs)
        XCTAssertNil(mixed.daily?.recovery)
        XCTAssertNil(mixed.nights.first?.hrvRmssdMs)
        XCTAssertEqual(mixed.nights.first?.restingHrBpm, 53)
        XCTAssertEqual(mixed.nights.first?.respRateBpm, 14.2)
        XCTAssertEqual(mixed.nights.first?.asleepMin, 42)
        XCTAssertEqual(mixed.daily?.sleepTotalMin, 42)
        let unavailable = ServerVitalSelection.resolve(.hrv, serverEnabled: true, selectedDay: day,
            overlay: mixed, localValue: 99)
        XCTAssertNil(unavailable.value)
        XCTAssertEqual(unavailable.status, "beat_timing_unverified")
    }

    func testHelperFeatureMarkerIsAcceptedOnlyWhenNoCanonicalContractExists() throws {
        let document = try legacyDocument()
        var root = document, score = root["server_scoring"] as! [String: Any]
        var features = score["features"] as! [String: [String: Any]]
        features["sleep"]?["input_eligibility"] = ["policy_version": "legacy-rr-excluded-1", "rr_input": "excluded"]
        score["features"] = features; root["server_scoring"] = score
        XCTAssertNil(try decode(root).daily?.sleepTotalMin,
            "A feature-only receipt cannot override a canonical result that lacks the immutable receipt")
        score.removeValue(forKey: "compute"); root["server_scoring"] = score
        let helper = try decode(root)
        XCTAssertEqual(helper.daily?.sleepTotalMin, 42)
        XCTAssertEqual(helper.nights.first?.asleepMin, 42)
        XCTAssertNil(helper.daily?.hrvRmssdMs)
        XCTAssertNil(helper.nights.first?.hrvRmssdMs)
        features["sleep"]?["input_eligibility"] = ["policy_version": "wrong", "rr_input": "excluded"]
        score["features"] = features; root["server_scoring"] = score
        let unmarked = try decode(root)
        XCTAssertNil(unmarked.daily?.sleepTotalMin)
        XCTAssertTrue(unmarked.sleepMetadataLines.contains("Sleep staging unavailable: beat timing unverified"))
        XCTAssertFalse(unmarked.sleepMetadataLines.contains(where: { $0.hasPrefix("Full-day unknown:") }))
    }

    private func decode(_ document: [String: Any]) throws -> ServerScoreDayCache {
        try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: document), day: day, ownerId: owner)
    }

    private func editFamily(_ document: [String: Any], _ name: String,
                            _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var result = document, score = result["server_scoring"] as! [String: Any]
        var compute = score["compute"] as! [String: Any]
        var families = compute["families"] as! [String: [String: Any]]
        edit(&families[name]!)
        compute["families"] = families; score["compute"] = compute; result["server_scoring"] = score
        return result
    }

    func testCoherentFinalHostedProjectionFeedsEveryDirectCacheConsumerFromOneRevision() throws {
        let cache = try decode(document())
        XCTAssertEqual(cache.daily?.hrvRmssdMs, 0)
        XCTAssertEqual(cache.daily?.sleepEfficiency, 0)
        XCTAssertEqual(cache.daily?.recovery, 0)
        XCTAssertEqual(cache.daily?.skinTempC, 0)
        XCTAssertNil(cache.daily?.rest)
        XCTAssertEqual(cache.daily?.sleepUnstagedMin, 0)
        XCTAssertNil(cache.daily?.stateUnknownMin)
        XCTAssertEqual(cache.fullDaySleepEpochs?.count, 1)
        XCTAssertEqual(cache.nights.first?.asleepMin, 0)
        XCTAssertEqual(cache.sleepOverrides.count, 1)
        XCTAssertEqual(cache.computedAt, "2026-09-21T02:00:00Z")
        XCTAssertFalse(cache.stale)

        let hrv = ServerHrvSeries.from(cache, day: day)
        XCTAssertEqual(hrv.windows.first?.rmssdMs, 0)
        XCTAssertEqual(hrv.resultRevision, resultRevision)
        XCTAssertEqual(ServerRespirationSummary.project(cache, day: day)?.breathsPerMinute, 14.2)
        XCTAssertEqual(ServerSleepEpisode.episodes(cache, day: day).first?.asleepMin, 0)
        XCTAssertEqual(ServerVitalSelection.resolve(.charge, serverEnabled: true, selectedDay: day,
            overlay: cache, localValue: 99).value, 0)

        let root = try JSONSerialization.jsonObject(with: Data(cache.rawSnapshotJSON!.utf8)) as! [String: Any]
        let score = root["server_scoring"] as! [String: Any]
        let daily = score["daily"] as! [String: Any]
        XCTAssertNil(daily["rest"])
        XCTAssertNil(daily["overnight_hr_bpm"])
        XCTAssertTrue(daily["state_unknown_min"] is NSNull)
        XCTAssertEqual((score["measurements"] as! [Any]).count, 1)
    }

    func testRootMetadataIsSanitizedFromAdmittedFamiliesAndExpiredCompatibilityIsCleared() throws {
        for (key, value): (String, Any) in [
            ("computed_at", "2026-09-21T03:00:00Z"), ("stale", true),
        ] {
            var changed = document(), score = changed["server_scoring"] as! [String: Any]
            score[key] = value; changed["server_scoring"] = score
            let cache = try decode(changed)
            XCTAssertEqual(cache.computedAt, "2026-09-21T02:00:00Z", key)
            XCTAssertFalse(cache.stale, key)
            let root = try JSONSerialization.jsonObject(with: Data(cache.rawSnapshotJSON!.utf8)) as! [String: Any]
            let sanitized = root["server_scoring"] as! [String: Any]
            XCTAssertEqual(sanitized["computed_at"] as? String, "2026-09-21T02:00:00Z", key)
            XCTAssertEqual(sanitized["stale"] as? Bool, false, key)
        }

        let expired = editFamily(document(), "sleep") { family in
            family["expires_at"] = "2026-09-20T00:00:00Z"
            family["freshness"] = "expired"
        }
        let cache = try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: expired),
            day: day, ownerId: owner, fetchedAt: Date(timeIntervalSince1970: 1_789_948_800))
        XCTAssertNil(cache.daily?.sleepTotalMin)
        XCTAssertNil(cache.daily?.sleepUnstagedMin)
        XCTAssertNil(cache.fullDaySleepEpochs)
        XCTAssertTrue(cache.nights.isEmpty)
        XCTAssertTrue(cache.sleepOverrides.isEmpty)
        XCTAssertTrue(ServerSleepEpisode.episodes(cache, day: day).isEmpty)

        let unavailable = editFamily(document(), "sleep") { family in
            family["freshness"] = "unavailable"
        }
        let unavailableCache = try decode(unavailable)
        XCTAssertNil(unavailableCache.daily?.sleepTotalMin)
        XCTAssertTrue(unavailableCache.nights.isEmpty)
        XCTAssertTrue(ServerSleepEpisode.episodes(unavailableCache, day: day).isEmpty)
    }

    func testEveryDuplicatedScalarRejectsTopLevelOnlyMutationAndMissingIsNotNull() throws {
        let replacements: [String: Any] = [
            "hrv_rmssd_ms": 1, "hrv_sdnn_ms": 1, "resting_hr_bpm": 1,
            "sleep_total_min": 1, "sleep_in_bed_min": 61, "sleep_awake_min": 1,
            "sleep_light_min": 1, "sleep_deep_min": 1, "sleep_rem_min": 1,
            "sleep_efficiency": 0.5, "disturbances": 1, "resp_rate_bpm": 15,
            "recovery": 1, "strain": 1, "spo2_pct": 96, "skin_temp_c": 1, "skin_temp_dev_c": 1,
        ]
        for (key, value) in replacements {
            var changed = document(), score = changed["server_scoring"] as! [String: Any]
            var daily = score["daily"] as! [String: Any]
            daily[key] = value; score["daily"] = daily; changed["server_scoring"] = score
            XCTAssertThrowsError(try decode(changed), key)
        }
        for replacement: Any? in [nil, NSNull()] {
            var changed = document(), score = changed["server_scoring"] as! [String: Any]
            var daily = score["daily"] as! [String: Any]
            if let replacement { daily["hrv_rmssd_ms"] = replacement } else { daily.removeValue(forKey: "hrv_rmssd_ms") }
            score["daily"] = daily; changed["server_scoring"] = score
            XCTAssertThrowsError(try decode(changed))
        }
    }

    func testSleepCopiesRequireRecursiveEqualityAndDistinguishNullEmptyAndMissing() throws {
        var topMutation = document(), score = topMutation["server_scoring"] as! [String: Any]
        var nights = score["nights"] as! [[String: Any]]
        nights[0]["asleep_min"] = 1; score["nights"] = nights; topMutation["server_scoring"] = score
        XCTAssertThrowsError(try decode(topMutation))

        let familyMutations = ["values", "details"]
        for container in familyMutations {
            let changed = editFamily(document(), "sleep") { family in
                var values = family[container] as! [String: Any]
                let key = container == "values" ? "sleep_sessions" : "nights"
                var rows = values[key] as! [[String: Any]]
                rows[0]["asleep_min"] = 2; values[key] = rows; family[container] = values
            }
            XCTAssertThrowsError(try decode(changed), container)
        }

        var nullDocument = document(), nullScore = nullDocument["server_scoring"] as! [String: Any]
        nullScore["nights"] = NSNull(); nullDocument["server_scoring"] = nullScore
        nullDocument = editFamily(nullDocument, "sleep") { family in
            var values = family["values"] as! [String: Any], details = family["details"] as! [String: Any]
            values["sleep_sessions"] = NSNull(); details["nights"] = NSNull()
            family["values"] = values; family["details"] = details
        }
        let decodedNull = try decode(nullDocument)
        XCTAssertTrue(decodedNull.nights.isEmpty)
        XCTAssertEqual(decodedNull.canonicalResults?.families["sleep"]?.values["sleep_sessions"], .null)
        let nullRoot = try JSONSerialization.jsonObject(with: Data(decodedNull.rawSnapshotJSON!.utf8)) as! [String: Any]
        XCTAssertTrue((nullRoot["server_scoring"] as! [String: Any])["nights"] is NSNull)

        var emptyDocument = document(), emptyScore = emptyDocument["server_scoring"] as! [String: Any]
        emptyScore["nights"] = [Any](); emptyDocument["server_scoring"] = emptyScore
        emptyDocument = editFamily(emptyDocument, "sleep") { family in
            var values = family["values"] as! [String: Any], details = family["details"] as! [String: Any]
            values["sleep_sessions"] = [Any](); details["nights"] = [Any]()
            family["values"] = values; family["details"] = details
        }
        XCTAssertTrue(try decode(emptyDocument).nights.isEmpty)

        var mismatch = nullDocument, mismatchScore = mismatch["server_scoring"] as! [String: Any]
        mismatchScore["nights"] = [Any](); mismatch["server_scoring"] = mismatchScore
        XCTAssertThrowsError(try decode(mismatch))
        var missing = emptyDocument; var missingScore = missing["server_scoring"] as! [String: Any]
        missingScore.removeValue(forKey: "nights"); missing["server_scoring"] = missingScore
        XCTAssertThrowsError(try decode(missing))
    }

    func testSleepCompatibilityIsBoundOrClearedAndPreservesZeroNullAndEmptyEpochs() throws {
        var emptyEpochs = document(), score = emptyEpochs["server_scoring"] as! [String: Any]
        var daily = score["daily"] as! [String: Any]
        daily["full_day_sleep_epochs"] = [Any](); score["daily"] = daily; emptyEpochs["server_scoring"] = score
        emptyEpochs = editFamily(emptyEpochs, "sleep") { family in
            var details = family["details"] as! [String: Any]
            var compatibility = details["daily_compatibility"] as! [String: Any]
            compatibility["full_day_sleep_epochs"] = [Any](); details["daily_compatibility"] = compatibility
            family["details"] = details
        }
        let empty = try decode(emptyEpochs)
        XCTAssertEqual(empty.fullDaySleepEpochs?.count, 0)
        XCTAssertEqual(empty.daily?.sleepUnstagedMin, 0)
        XCTAssertNil(empty.daily?.stateUnknownMin)

        let absent = editFamily(document(), "sleep") { family in
            var details = family["details"] as! [String: Any]
            details.removeValue(forKey: "daily_compatibility"); family["details"] = details
        }
        let cleared = try decode(absent)
        XCTAssertNil(cleared.fullDaySleepEpochs)
        XCTAssertNil(cleared.daily?.sleepUnstagedMin)
        XCTAssertNil(cleared.daily?.opportunityKind)

        var rawMutation = document(), rawScore = rawMutation["server_scoring"] as! [String: Any]
        var rawDaily = rawScore["daily"] as! [String: Any]
        rawDaily["sleep_unstaged_min"] = 1; rawScore["daily"] = rawDaily; rawMutation["server_scoring"] = rawScore
        XCTAssertThrowsError(try decode(rawMutation))

        let incomplete = editFamily(document(), "sleep") { family in
            var details = family["details"] as! [String: Any]
            var compatibility = details["daily_compatibility"] as! [String: Any]
            compatibility.removeValue(forKey: "state_unknown_min")
            details["daily_compatibility"] = compatibility; family["details"] = details
        }
        XCTAssertThrowsError(try decode(incomplete))
    }

    func testCurrentHrvSeriesRequiresSelectedImmutableFamilyAndRejectsMeasurementMutation() throws {
        let selected = ServerHrvSeries.from(try decode(document()), day: day)
        XCTAssertEqual(selected.windows.first?.rmssdMs, 0)
        XCTAssertEqual(selected.resultRevision, resultRevision)

        var mutation = document(), score = mutation["server_scoring"] as! [String: Any]
        var rows = score["measurements"] as! [[String: Any]]
        rows[0]["observed_rmssd_ms"] = 1; score["measurements"] = rows; mutation["server_scoring"] = score
        XCTAssertThrowsError(try decode(mutation))

        let unqualified = editFamily(document(), "current_hrv") { family in
            family["status"] = "unqualified"; family["reason"] = "reference_required"
            family["algorithm_version"] = "vps-only-1"; family["manifest_hash"] = NSNull()
            family["feature_manifest_hash"] = NSNull(); family["canonical_qualification"] = NSNull()
        }
        let unqualifiedSeries = ServerHrvSeries.from(try decode(unqualified), day: day)
        XCTAssertTrue(unqualifiedSeries.windows.isEmpty)
        XCTAssertNil(unqualifiedSeries.resultRevision)

        let failed = editFamily(document(), "current_hrv") { family in
            family["status"] = "failed"; family["reason"] = "worker_failed"
        }
        let failedSeries = ServerHrvSeries.from(try decode(failed), day: day)
        XCTAssertTrue(failedSeries.windows.isEmpty)
        XCTAssertNil(failedSeries.resultRevision)

        let expired = editFamily(document(), "current_hrv") { family in
            family["expires_at"] = "2026-09-20T00:00:00Z"; family["freshness"] = "expired"
        }
        let expiredCache = try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: expired),
            day: day, ownerId: owner, fetchedAt: Date(timeIntervalSince1970: 1_789_948_800))
        let expiredSeries = ServerHrvSeries.from(expiredCache, day: day)
        XCTAssertTrue(expiredSeries.windows.isEmpty)
        XCTAssertNil(expiredSeries.resultRevision)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(expiredCache.measurementsJSON!.utf8)) as! [Any]).count, 0)

        var revisionMismatch = document(), mismatchScore = revisionMismatch["server_scoring"] as! [String: Any]
        var features = mismatchScore["features"] as! [String: [String: Any]]
        features["hrv"]?["input_revision"] = 43; mismatchScore["features"] = features
        revisionMismatch["server_scoring"] = mismatchScore
        XCTAssertThrowsError(try decode(revisionMismatch))
    }
}
