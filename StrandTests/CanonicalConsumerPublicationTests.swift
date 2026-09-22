import XCTest
import WhoopStore
import StrandDesign
import WhoopProtocol
import ZIPFoundation
@testable import Strand

@MainActor
final class CanonicalConsumerPublicationTests: XCTestCase {
    private struct HistoricalSidecar: Decodable {
        let provenance: String
        let source: String
        let metricSeries: [MetricPoint]
    }

    private func result(revision: String = "compute:17", inputRevision: Int64 = 17, status: String = "available",
                        sleep: Any = NSNull(), hrv: Any = NSNull(), vitals: [String: Double] = [:],
                        freshness: String = "current", insight: String? = nil) throws -> ServerCanonicalResults {
        let owner = "11111111-1111-4111-8111-111111111111"
        let source = "22222222-2222-4222-8222-222222222222"
        let device = "33333333-3333-4333-8333-333333333333"
        let project = "https://example.supabase.co", day = "2026-09-21"
        var families: [String: Any] = [:]
        for (name, metrics) in ServerCanonicalResults.familyMetrics {
            var values = Dictionary(uniqueKeysWithValues: metrics.map { ($0, NSNull() as Any) })
            if name == "recovery", status == "available" { values["recovery"] = 0 }
            if name == "night_hrv", status == "available" { values["hrv_sdnn_ms"] = hrv }
            if name == "sleep", status == "available" { values["sleep_sessions"] = sleep }
            if name == "insights", status == "available", let insight { values["insights"] = insight }
            if status == "available" {
                for (metric, value) in vitals where metrics.contains(metric) { values[metric] = value }
            }
            families[name] = ["owner": "server", "metrics": metrics.sorted(), "status": status,
                "reason": status == "available" ? NSNull() : "qualification_pending",
                "result_revision": revision, "input_revision": inputRevision,
                "algorithm_version": "frwhoop-server-1", "configuration_version": "config-1",
                "manifest_hash": String(repeating: "a", count: 64), "canonical_qualification": "retained_legacy",
                "project": project, "owner_id": owner, "source_id": source, "device_id": device,
                "window": day, "computed_at": "2026-09-21T01:00:00Z",
                "observed_through": "2026-09-21T00:00:00Z", "timezone_id": "UTC",
                "freshness": freshness, "values": values, "details": [:]]
        }
        let payload: [String: Any] = ["mode": "final_hosted", "policy_version": "vps-only-1",
            "project": project, "owner_id": owner, "source_id": source, "device_id": device,
            "day": day, "families": families]
        let decoded = try JSONDecoder().decode(ServerCanonicalResults.self,
            from: JSONSerialization.data(withJSONObject: payload))
        try decoded.validate(owner: owner, day: day, project: project, source: source, device: device)
        return decoded
    }

    private func state(_ result: ServerCanonicalResults, phase: ServerScoreDayState.Phase? = nil,
                       cached: Bool = false) -> ServerScoreViewState {
        var state = ServerScoreViewState(generation: nil, revision: 1, currentDay: result.day, timezone: "UTC",
            configured: true, authenticated: true, capabilities: [], activated: [],
            days: phase.map { [result.day: ServerScoreDayState(snapshot: nil, phase: $0, fetchedAt: nil,
                cached: cached, pending: false, requestedInputRevision: nil, archiveStatus: nil)] } ?? [:])
        state.canonicalDays = [result.day: result]
        return state
    }

    private func directory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let url = root.appendingPathComponent("canonical-adapters-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func archiveEntry(_ name: String, at url: URL) throws -> Data {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive[name])
        var bytes = Data()
        _ = try archive.extract(entry) { bytes.append($0) }
        return bytes
    }

    private func observedSleep() -> [String: Any] {
        ["id": "44444444-4444-4444-8444-444444444444",
         "start_at": "2026-09-20T23:58:00Z", "end_at": "2026-09-21T00:00:00Z", "is_nap": false,
         "stages": [
            ["start": 1_789_948_680, "end": 1_789_948_710, "stage": "light", "state": "sleep"],
            ["start": 1_789_948_710, "end": 1_789_948_740, "stage": "unknown", "state": "state_unknown"],
            ["start": 1_789_948_740, "end": 1_789_948_800, "stage": "rem", "state": "sleep"]]]
    }

    private func productionDecoderEnvelope() -> [String: Any] {
        let owner = "11111111-1111-4111-8111-111111111111"
        let source = "22222222-2222-4222-8222-222222222222"
        let device = "33333333-3333-4333-8333-333333333333"
        let project = "https://example.supabase.co", day = "2026-09-21"
        let computedAt = "2026-09-21T01:00:00Z", manifest = String(repeating: "a", count: 64)
        var night = observedSleep()
        night["user_id"] = owner; night["device_id"] = device; night["algorithm_version"] = "frwhoop-server-1"
        let compatibility: [String: Any] = [
            "sleep_onset_at": NSNull(), "wake_onset_at": NSNull(), "sleep_unstaged_min": 0,
            "state_unknown_min": NSNull(), "off_body_min": 0, "main_sleep_group_id": NSNull(),
            "opportunity_kind": "estimated_sleep_opportunity", "full_day_sleep_epochs": [Any](),
        ]
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
        func authorize(_ name: String, values: [String: Any], details: [String: Any]) {
            var family = families[name]!, complete = family["values"] as! [String: Any]
            complete.merge(values, uniquingKeysWith: { _, next in next })
            family["status"] = "available"; family["reason"] = NSNull()
            family["result_revision"] = "compute:17"; family["input_revision"] = 17
            family["algorithm_version"] = "frwhoop-server-1"; family["configuration_version"] = "config-1"
            family["manifest_hash"] = manifest; family["canonical_qualification"] = "retained_legacy"
            family["computed_at"] = computedAt; family["observed_through"] = "2026-09-21T00:00:00Z"
            family["freshness"] = "current"; family["values"] = complete; family["details"] = details
            families[name] = family
        }
        authorize("recovery", values: ["recovery": 0], details: [:])
        authorize("sleep", values: [
            "sleep_total_min": 1.5, "sleep_in_bed_min": 2, "sleep_awake_min": 0,
            "sleep_light_min": 0.5, "sleep_deep_min": 0, "sleep_rem_min": 1,
            "sleep_efficiency": 75, "disturbances": 0, "sleep_sessions": [night],
        ], details: ["nights": [night], "sleep_overrides": [Any](), "daily_compatibility": compatibility])
        let feature: [String: Any] = [
            "status": "available", "device_id": device, "algorithm_version": "frwhoop-server-1",
            "input_revision": 17, "manifest_hash": manifest, "canonical_qualification": "retained_legacy",
            "computed_at": computedAt, "observed_through": "2026-09-21T00:00:00Z",
        ]
        var daily = compatibility
        daily.merge([
            "recovery": 0, "sleep_total_min": 1.5, "sleep_in_bed_min": 2, "sleep_awake_min": 0,
            "sleep_light_min": 0.5, "sleep_deep_min": 0, "sleep_rem_min": 1,
            "sleep_efficiency": 0.75, "disturbances": 0,
        ], uniquingKeysWith: { _, next in next })
        let compute: [String: Any] = [
            "mode": "final_hosted", "policy_version": "vps-only-1", "project": project,
            "owner_id": owner, "source_id": source, "device_id": device, "day": day, "families": families,
        ]
        return ["server_scoring": [
            "schema_version": 2, "contract_revision": 2, "user_id": owner, "day": day,
            "algorithm_version": "per_feature", "features": [
                "hrv": feature, "sleep": feature,
                "respiration": ["status": "unavailable", "reason": "awaiting_result"],
            ], "daily": daily, "nights": [night], "measurements": [Any](), "sleep_overrides": [Any](),
            "computed_at": computedAt, "stale": false, "compute": compute,
        ]]
    }

    func testProductionDecoderFeedsOneSleepRevisionToWidgetWatchHealthAndExport() async throws {
        try await PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            let envelope = productionDecoderEnvelope()
            let cache = try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: envelope),
                day: "2026-09-21", ownerId: "11111111-1111-4111-8111-111111111111")
            let canonical = try XCTUnwrap(cache.canonicalResults)
            let selected = state(canonical, phase: .available)
            XCTAssertEqual(cache.nights.count, 1)
            XCTAssertEqual(cache.daily?.sleepEfficiency, 0.75)
            XCTAssertEqual(cache.fullDaySleepEpochs?.count, 0)

            let widget = CanonicalConsumerPublication.widgetSnapshot(state: selected,
                accountNamespace: "decoder-owner", heartRate: nil, batteryPct: nil, bonded: true)
            let watch = CanonicalConsumerPublication.watchSnapshot(state: selected,
                accountNamespace: "decoder-owner", heartRate: nil)
            XCTAssertEqual(widget.recovery, 0); XCTAssertEqual(watch.charge, 0)
            XCTAssertEqual(widget.canonicalLedger, watch.canonicalLedger)
            XCTAssertEqual(widget.canonicalLedger?.families["sleep"]?.resultRevision, "compute:17")

            let health = try CanonicalHealthWritebackPlan.replacements(state: selected, accountNamespace: "decoder-owner")
            let sleep = try XCTUnwrap(health.first {
                if case .sleep = $0.target { return true }
                return false
            })
            XCTAssertEqual(sleep.records.map(\.payload), [.sleep(.inBed), .sleep(.light), .sleep(.rem)])
            for record in sleep.records {
                let receipt = try JSONDecoder().decode(CanonicalConsumerLedger.Receipt.self,
                    from: Data(try XCTUnwrap(record.metadata["naraCanonicalResult"]).utf8))
                XCTAssertEqual(receipt.resultRevision, "compute:17")
                XCTAssertEqual(receipt, watch.canonicalLedger?.families["sleep"])
            }

            let directory = try directory()
            try CanonicalExport.writeShortcut(state: selected, directory: directory)
            let exported = try JSONDecoder().decode(CanonicalExport.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent("noop_server_results.json")))
            XCTAssertEqual(exported.windows.first?.currentResult, canonical)
            XCTAssertEqual(exported.windows.first?.ledger.families["sleep"]?.resultRevision, "compute:17")

            var tampered = envelope, score = tampered["server_scoring"] as! [String: Any]
            var nights = score["nights"] as! [[String: Any]]
            nights[0]["asleep_min"] = 99; score["nights"] = nights; tampered["server_scoring"] = score
            XCTAssertThrowsError(try ServerScoreCacheCodec.parseSnapshot(
                JSONSerialization.data(withJSONObject: tampered), day: "2026-09-21",
                ownerId: "11111111-1111-4111-8111-111111111111"))
            XCTAssertEqual(PhoneComputeRuntime.counters().executions.values.reduce(0, +), 0)
        }
    }

    func testActualProductionAdaptersPersistOneIdentityAndZeroInference() async throws {
        try await PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            let result = try result(sleep: [observedSleep()], hrv: 0), selected = state(result, phase: .available)
            let namespace = "canonical-owner", suite = "canonical-adapters." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            WidgetSnapshot.activateAccount(namespace: namespace, defaults: defaults)
            let widget = CanonicalConsumerPublication.widgetSnapshot(state: selected, accountNamespace: namespace,
                heartRate: 71, batteryPct: 50, bonded: true)
            widget.save(to: defaults)
            let loadedWidget = try XCTUnwrap(WidgetSnapshot.load(from: defaults))
            let watch = CanonicalConsumerPublication.watchSnapshot(state: selected, accountNamespace: namespace, heartRate: 71)
            watch.save(to: defaults)
            let loadedWatch = try XCTUnwrap(WatchScoreSnapshot.load(from: defaults))
            XCTAssertEqual(loadedWidget.canonicalLedger, loadedWatch.canonicalLedger)
            XCTAssertEqual(loadedWidget.recovery, 0); XCTAssertEqual(loadedWatch.charge, 0)
            XCTAssertNil(loadedWidget.hrv, "Owned RMSSD null is not reconstructed from SDNN")
            XCTAssertEqual(loadedWidget.bpm, 71); XCTAssertEqual(loadedWatch.hr, 71)

            let replacements = try CanonicalHealthWritebackPlan.replacements(state: selected, accountNamespace: namespace)
            var operations: [CanonicalHealthWritebackPlan.Operation] = []
            let boundary = HealthWritebackBoundary(guarded: true, validate: { true }, checkBoundary: {})
            try await CanonicalHealthWritebackPlan.publish(replacements, authorized: { _ in true }) { operation in
                try await boundary.perform { operations.append(operation) }
            }
            let saved = operations.flatMap { operation -> [CanonicalHealthWritebackPlan.Record] in
                if case .save(let records) = operation { return records }; return []
            }
            XCTAssertEqual(saved.count, 4, "One exact SDNN sample and in-bed/light/REM; unknown gap is not filled")
            XCTAssertTrue(saved.contains { $0.payload == .quantity(metric: "hrv_sdnn_ms", value: 0, unit: .milliseconds) })
            for sample in saved {
                let receipt = try JSONDecoder().decode(CanonicalConsumerLedger.Receipt.self,
                    from: Data(try XCTUnwrap(sample.metadata["naraCanonicalResult"]).utf8))
                XCTAssertEqual(receipt, loadedWatch.canonicalLedger?.families[receipt.family])
                XCTAssertEqual(receipt.resultRevision, "compute:17"); XCTAssertEqual(receipt.inputRevision, 17)
                XCTAssertEqual(sample.metadata["naraProject"], result.project)
                XCTAssertEqual(sample.metadata["naraOwner"], result.ownerID)
                XCTAssertEqual(sample.metadata["naraSource"], result.sourceID)
                XCTAssertEqual(sample.metadata["naraCanonicalDevice"], result.deviceID)
                XCTAssertEqual(sample.metadata["naraScoreDay"], result.day)
                XCTAssertEqual(sample.metadata["com.frwhoop.account-namespace"], namespace)
                XCTAssertTrue(sample.externalUUID.hasPrefix("account:\(namespace):"))
            }
            let directory = try directory(), legacy = directory.appendingPathComponent(ShortcutHealthExport.fileName)
            try Data("old,unrevisioned,automation".utf8).write(to: legacy)
            try CanonicalExport.writeShortcut(state: selected, directory: directory)
            XCTAssertTrue(try Data(contentsOf: legacy).isEmpty)
            let shortcut = try Data(contentsOf: directory.appendingPathComponent("noop_server_results.json"))
            let document = try JSONDecoder().decode(CanonicalExport.Document.self, from: shortcut)
            XCTAssertEqual(document.windows.first?.ledger, loadedWatch.canonicalLedger)
            XCTAssertEqual(document.windows.first?.currentResult, result)
            XCTAssertNil(document.windows.first?.historicalResult)
            let archive = directory.appendingPathComponent("canonical.zip")
            try CanonicalExport.writeArchive(state: selected, historicalEntries: [], to: archive)
            XCTAssertEqual(try archiveEntry("canonical_results.json", at: archive), shortcut)
            let csv = String(decoding: try archiveEntry("canonical_metrics.csv", at: archive), as: UTF8.self)
            XCTAssertEqual(csv, CsvExport.canonicalCSV(selected))
            XCTAssertTrue(csv.contains("\"17\",\"compute:17\""))
            XCTAssertTrue(csv.contains("\"recovery\",\"recovery\",\"0.0\""))
            XCTAssertEqual(PhoneComputeRuntime.counters().executions.values.reduce(0, +), 0)
        }
    }

    func testHostedArchiveRetainsEveryPersistedDirectSourceMetricSeries() async throws {
        try await PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            let store = try await WhoopStore.inMemory()
            let expected: [(String, MetricPoint)] = [
                ("apple-health", .init(day: "2026-09-20", key: "weight", value: 71.2)),
                ("xiaomi-band", .init(day: "2026-09-20", key: "steps", value: 0)),
                ("nutrition-csv", .init(day: "2026-09-20", key: "calories_in", value: 0)),
                ("noop-mood", .init(day: "2026-09-20", key: "mood", value: 4)),
            ]
            for (source, point) in expected {
                _ = try await store.upsertMetricSeries([point], deviceId: source)
            }
            let repo = Repository(deviceId: "my-whoop")
            repo.setStoreForTesting(store)
            let entries = try await CsvExport.canonicalHistoricalEntries(repo: repo, store: store)
            let sidecars = try entries.map { try JSONDecoder().decode(HistoricalSidecar.self, from: $0.data) }
            let bySource = Dictionary(uniqueKeysWithValues: sidecars.map { ($0.source, $0) })
            for (source, point) in expected {
                let sidecar = try XCTUnwrap(bySource[source], source)
                XCTAssertEqual(sidecar.provenance, "historical_persisted_source_not_canonical")
                XCTAssertEqual(sidecar.metricSeries, [point], source)
            }

            let archive = try directory().appendingPathComponent("direct-source-history.zip")
            try CanonicalExport.writeArchive(state: repo.serverPresentation,
                historicalEntries: entries, to: archive)
            for entry in entries {
                XCTAssertEqual(try archiveEntry(entry.name, at: archive), entry.data)
            }
            XCTAssertEqual(PhoneComputeRuntime.counters().executions.values.reduce(0, +), 0)
        }
    }

    func testFailedReadAndCachedOnlyExportsRetainHistoryWithoutCurrentValues() throws {
        let result = try result(hrv: 0)
        for phase in [ServerScoreDayState.Phase.failed, .offline, .pending, .available] {
            let selected = state(result, phase: phase, cached: true)
            let directory = try directory()
            try CanonicalExport.writeShortcut(state: selected, directory: directory)
            let document = try JSONDecoder().decode(CanonicalExport.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent("noop_server_results.json")))
            let window = try XCTUnwrap(document.windows.first)
            XCTAssertNil(window.currentResult)
            XCTAssertEqual(window.historicalResult, result, "Transport failure must not rewrite an immutable result")
            XCTAssertEqual(window.ledger.readState, phase.rawValue); XCTAssertEqual(window.ledger.cached, true)
            XCTAssertEqual(window.ledger.families["recovery"]?.resultRevision, "compute:17")
            XCTAssertTrue(CsvExport.canonicalCSV(selected).contains("\"recovery\",\"recovery\",\"\",\"available\""))
            XCTAssertTrue(try CanonicalHealthWritebackPlan.replacements(state: selected, accountNamespace: "owner").isEmpty)
            if phase == .failed || phase == .offline {
                XCTAssertNil(CanonicalConsumerPublication.widgetSnapshot(state: selected, accountNamespace: "owner",
                    heartRate: 70, batteryPct: nil, bonded: true).recovery)
                XCTAssertNil(CanonicalConsumerPublication.watchSnapshot(state: selected, accountNamespace: "owner", heartRate: 70).charge)
            }
        }
    }

    func testRevisionChangeWithEqualValuesReplacesPersistedConsumers() throws {
        let directory = try directory(), suite = "canonical-revision." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        WidgetSnapshot.activateAccount(namespace: "owner", defaults: defaults)
        for revision: Int64 in [17, 18] {
            let selected = state(try result(revision: "compute:\(revision)", inputRevision: revision), phase: .available)
            CanonicalConsumerPublication.widgetSnapshot(state: selected, accountNamespace: "owner",
                heartRate: nil, batteryPct: nil, bonded: false).save(to: defaults)
            CanonicalConsumerPublication.watchSnapshot(state: selected, accountNamespace: "owner", heartRate: nil).save(to: defaults)
            try CanonicalExport.writeShortcut(state: selected, directory: directory)
            let exported = try JSONDecoder().decode(CanonicalExport.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent("noop_server_results.json")))
            let receipt = try XCTUnwrap(exported.windows.first?.ledger.families["recovery"])
            XCTAssertEqual(receipt.inputRevision, revision); XCTAssertEqual(receipt.resultRevision, "compute:\(revision)")
            XCTAssertEqual(receipt, WidgetSnapshot.load(from: defaults)?.canonicalLedger?.families["recovery"])
            XCTAssertEqual(receipt, WatchScoreSnapshot.load(from: defaults)?.canonicalLedger?.families["recovery"])
            let health = try CanonicalHealthWritebackPlan.replacements(state: selected, accountNamespace: "owner")
            XCTAssertEqual(health.count, 5)
            XCTAssertTrue(health.allSatisfy { $0.records.isEmpty }, "A revision change cannot invent null Health values")
        }
    }

    func testHealthRecordsUseExactUnitsBoundsAndNewRevisionEvenWhenValuesAreEqual() throws {
        var previousTargets: [CanonicalHealthWritebackPlan.Target]?
        for revision: Int64 in [17, 18] {
            let selected = state(try result(revision: "compute:\(revision)", inputRevision: revision,
                sleep: [observedSleep()], vitals: ["resting_hr_bpm": 48, "hrv_sdnn_ms": 20,
                    "resp_rate_bpm": 14.5, "spo2_pct": 97]), phase: .available)
            let replacements = try CanonicalHealthWritebackPlan.replacements(state: selected, accountNamespace: "owner")
            if let previousTargets { XCTAssertEqual(replacements.map(\.target), previousTargets) }
            previousTargets = replacements.map(\.target)
            let records = replacements.flatMap(\.records)
            XCTAssertEqual(records.count, 7)
            let expected: [CanonicalHealthWritebackPlan.Payload] = [
                .quantity(metric: "resting_hr_bpm", value: 48, unit: .countPerMinute),
                .quantity(metric: "hrv_sdnn_ms", value: 20, unit: .milliseconds),
                .quantity(metric: "resp_rate_bpm", value: 14.5, unit: .countPerMinute),
                .quantity(metric: "spo2_pct", value: 0.97, unit: .fraction)]
            for payload in expected {
                let record = try XCTUnwrap(records.first { $0.payload == payload })
                XCTAssertEqual(record.start.timeIntervalSince1970, 1_789_948_800)
                XCTAssertEqual(record.end, record.start)
            }
            let light = try XCTUnwrap(records.first { $0.payload == .sleep(.light) })
            let rem = try XCTUnwrap(records.first { $0.payload == .sleep(.rem) })
            XCTAssertEqual(light.start.timeIntervalSince1970, 1_789_948_680)
            XCTAssertEqual(light.end.timeIntervalSince1970, 1_789_948_710)
            XCTAssertEqual(rem.start.timeIntervalSince1970, 1_789_948_740)
            XCTAssertEqual(rem.end.timeIntervalSince1970, 1_789_948_800)
            for record in records {
                let receipt = try JSONDecoder().decode(CanonicalConsumerLedger.Receipt.self,
                    from: Data(try XCTUnwrap(record.metadata["naraCanonicalResult"]).utf8))
                XCTAssertEqual(receipt.resultRevision, "compute:\(revision)")
                XCTAssertEqual(receipt.inputRevision, revision)
            }
        }
    }

    func testUnauthorizedHealthTargetDoesNotDeleteOrWrite() async throws {
        let selected = state(try result(hrv: 0), phase: .available)
        let replacements = try CanonicalHealthWritebackPlan.replacements(state: selected, accountNamespace: "owner")
        var admitted: [CanonicalHealthWritebackPlan.Target] = []
        try await CanonicalHealthWritebackPlan.publish(replacements, authorized: {
            admitted.append($0); return false
        }, perform: { _ in XCTFail("Permission denial must not reach Health side effects") })
        XCTAssertEqual(admitted, replacements.map(\.target))
    }

    func testRevokedAndNullHealthResultsDeleteWithoutReplacementAndNeverRecompute() async throws {
        for status in ["revoked", "available"] {
            let selected = state(try result(status: status), phase: .available)
            let replacements = try CanonicalHealthWritebackPlan.replacements(state: selected, accountNamespace: "owner")
            XCTAssertEqual(replacements.count, 5)
            var deletions = 0
            try await CanonicalHealthWritebackPlan.publish(replacements, authorized: { _ in true }) { operation in
                switch operation {
                case .delete: deletions += 1
                case .save: XCTFail("Owned null/revoked result must never save a replacement")
                }
            }
            XCTAssertEqual(deletions, 5)
            if status == "revoked" {
                XCTAssertNil(CanonicalConsumerPublication.widgetSnapshot(state: selected, accountNamespace: "owner",
                    heartRate: nil, batteryPct: nil, bonded: false).recovery)
                XCTAssertNil(CanonicalConsumerPublication.watchSnapshot(state: selected, accountNamespace: "owner", heartRate: nil).charge)
                XCTAssertTrue(CsvExport.canonicalCSV(selected).contains("\"recovery\",\"recovery\",\"\",\"revoked\""))
            }
        }
    }

    func testHealthRevocationDuringDeleteCannotSavePreparedCanonicalRecords() async throws {
        let result = try result(hrv: 0), selected = state(result, phase: .available)
        let replacement = try XCTUnwrap(CanonicalHealthWritebackPlan.replacements(state: selected, accountNamespace: "owner")
            .first { !$0.records.isEmpty })
        var currentState = selected, deletes = 0, saves = 0
        let boundary = HealthWritebackBoundary(guarded: true, validate: { true }, checkBoundary: {})
            .requiring { currentState == selected }
        do {
            try await CanonicalHealthWritebackPlan.publish([replacement], authorized: { _ in true }) { operation in
                try await boundary.perform {
                    switch operation {
                    case .delete: deletes += 1; currentState = self.state(result, phase: .failed, cached: true)
                    case .save: saves += 1
                    }
                }
            }
            XCTFail("Revocation must reject the pending save")
        } catch is CancellationError {} catch { throw error }
        XCTAssertEqual(deletes, 1); XCTAssertEqual(saves, 0)
        XCTAssertEqual(currentState.canonicalDays, selected.canonicalDays, "Same immutable revision does not authorize a failed transport read")
    }

    func testShortcutRetiresLegacyBeforeAtomicPublishAndRetainsPriorCompleteDocumentOnFailure() throws {
        enum Interrupted: Error { case publication }
        let directory = try directory(), first = state(try result(), phase: .available)
        try CanonicalExport.writeShortcut(state: first, directory: directory)
        let output = directory.appendingPathComponent("noop_server_results.json"), original = try Data(contentsOf: output)
        let legacy = directory.appendingPathComponent(ShortcutHealthExport.fileName)
        try Data("unrevisioned legacy physiology".utf8).write(to: legacy)
        let next = state(try result(revision: "compute:18", inputRevision: 18), phase: .available)
        XCTAssertThrowsError(try CanonicalExport.writeShortcut(state: next, directory: directory, beforePublish: {
            XCTAssertTrue(try Data(contentsOf: legacy).isEmpty)
            throw Interrupted.publication
        }))
        XCTAssertTrue(try Data(contentsOf: legacy).isEmpty)
        XCTAssertEqual(try Data(contentsOf: output), original)
        let blocked = try self.directory()
        try FileManager.default.createDirectory(at: blocked.appendingPathComponent(ShortcutHealthExport.fileName), withIntermediateDirectories: true)
        XCTAssertThrowsError(try CanonicalExport.writeShortcut(state: next, directory: blocked))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("noop_server_results.json").path))
    }

    func testSameRevisionReadFailureAtShortcutCommitCannotPublishPreparedValues() throws {
        let selected = state(try result(), phase: .available), directory = try directory()
        var current = selected
        XCTAssertThrowsError(try CanonicalExport.writeShortcut(state: selected, directory: directory,
            validate: { if current != selected { throw CancellationError() } }, beforePublish: {
                current = self.state(selected.canonicalDays[selected.currentDay]!, phase: .failed)
            }))
        XCTAssertEqual(current.canonicalDays, selected.canonicalDays)
        XCTAssertTrue(try Data(contentsOf: directory.appendingPathComponent(ShortcutHealthExport.fileName)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("noop_server_results.json").path))
    }

    func testArchiveProviderOpenCannotBypassReadStateAccountOrDeviceFence() throws {
        let selected = state(try result(), phase: .available), directory = try directory()
        let staged = directory.appendingPathComponent("prepared.zip")
        try CanonicalExport.writeArchive(state: selected, historicalEntries: [], to: staged)
        for change in ["read", "account", "device"] {
            var current = selected, account = "A", device = "A", closed = false
            let destination = directory.appendingPathComponent(change + ".zip")
            let previous = Data("previous complete export".utf8)
            try previous.write(to: destination)
            XCTAssertThrowsError(try CanonicalExport.installArchive(from: staged, to: destination, access: {
                switch change {
                case "read": current = self.state(selected.canonicalDays[selected.currentDay]!, phase: .failed)
                case "account": account = "B"
                default: device = "B"
                }
                return { closed = true }
            }, validate: {
                guard current == selected, account == "A", device == "A" else { throw CancellationError() }
            }))
            XCTAssertTrue(closed)
            XCTAssertEqual(try Data(contentsOf: destination), previous)
        }
    }

    func testArchiveInstallCommitsExactAdmittedPreparedPayload() throws {
        let selected = state(try result(), phase: .available), directory = try directory()
        let staged = directory.appendingPathComponent("prepared.zip"), installed = directory.appendingPathComponent("export.zip")
        try CanonicalExport.writeArchive(state: selected, historicalEntries: [], to: staged)
        var checks = 0, closed = false
        try CanonicalExport.installArchive(from: staged, to: installed, access: { { closed = true } },
            validate: { checks += 1 })
        XCTAssertEqual(checks, 2); XCTAssertTrue(closed)
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: staged))
        let document = try JSONDecoder().decode(CanonicalExport.Document.self,
            from: archiveEntry("canonical_results.json", at: installed))
        XCTAssertEqual(document.windows.first?.currentResult, selected.canonicalDays[selected.currentDay])
    }

    func testPublicationAndCSVRetainExactRevisionValidZeroAndOwnedNull() throws {
        let result = try result()
        let ledger = try XCTUnwrap(CanonicalConsumerPublication.ledger(result))
        XCTAssertEqual(ledger.families["recovery"]?.resultRevision, "compute:17")
        XCTAssertEqual(ledger.project, result.project)
        XCTAssertEqual(ledger.ownerID, result.ownerID)
        XCTAssertEqual(ledger.deviceID, result.deviceID)
        XCTAssertEqual(ledger.sourceID, result.sourceID)
        XCTAssertEqual(CanonicalConsumerPublication.value("recovery", in: result), 0)
        XCTAssertNil(CanonicalConsumerPublication.value("hrv_sdnn_ms", in: result))
        let csv = CsvExport.canonicalCSV(state(result))
        XCTAssertTrue(csv.contains("\"recovery\",\"recovery\",\"0.0\",\"available\""))
        XCTAssertTrue(csv.contains("\"night_hrv\",\"hrv_sdnn_ms\",\"\",\"available\""))
        XCTAssertTrue(csv.contains("\"17\",\"compute:17\",\"frwhoop-server-1\",\"config-1\""))
    }

    func testUnavailableOrExpiredFreshnessCannotReachUIWidgetWatchHealthOrCSV() throws {
        for freshness in ["expired", "unavailable"] {
            let canonical = try result(sleep: [observedSleep()], hrv: 0,
                vitals: ["resting_hr_bpm": 48], freshness: freshness, insight: "do not publish")
            let selected = state(canonical, phase: .available)
            let widget = CanonicalConsumerPublication.widgetSnapshot(state: selected,
                accountNamespace: "owner", heartRate: 71, batteryPct: 50, bonded: true)
            let watch = CanonicalConsumerPublication.watchSnapshot(state: selected,
                accountNamespace: "owner", heartRate: 71)
            XCTAssertNil(widget.recovery, freshness)
            XCTAssertNil(widget.hrv, freshness)
            XCTAssertNil(widget.restingHr, freshness)
            XCTAssertNil(widget.insights, freshness)
            XCTAssertNil(watch.charge, freshness)
            XCTAssertNil(watch.effort, freshness)
            XCTAssertNil(watch.rest, freshness)

            let health = try XCTUnwrap(CanonicalHealthWritebackPlan.days(state: selected).first)
            XCTAssertTrue(health.quantities.isEmpty, freshness)
            XCTAssertTrue(health.sleeps.isEmpty, freshness)
            let recovery = try XCTUnwrap(canonical.families["recovery"])
            XCTAssertEqual(CanonicalPhysiologySection.display(result: recovery, metric: "recovery"), "—", freshness)
            let csv = CsvExport.canonicalCSV(selected)
            XCTAssertTrue(csv.contains("\"recovery\",\"recovery\",\"\",\"available\""), freshness)
            XCTAssertFalse(csv.contains("\"recovery\",\"recovery\",\"0.0\",\"available\""), freshness)
        }
    }

    func testWidgetChangesOnRevisionEvenWhenValuesAreEqualAndRejectsOldCache() throws {
        let first = try result(), next = try result(revision: "compute:18")
        var a = WidgetSnapshot(recovery: 0, bpm: 70, batteryPct: 50, bonded: true, updated: Date(),
            finalHosted: true, canonicalLedger: CanonicalConsumerPublication.ledger(first))
        var b = a; b.canonicalLedger = CanonicalConsumerPublication.ledger(next)
        XCTAssertTrue(a.hasCanonicalAdmission)
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: a, to: b))
        a.finalHosted = nil
        XCTAssertFalse(a.hasCanonicalAdmission)
        b.canonicalLedger = CanonicalConsumerPublication.ledger(try result(status: "revoked"))
        XCTAssertFalse(b.hasCanonicalAdmission)
        b.recovery = nil
        XCTAssertTrue(b.hasCanonicalAdmission)
    }

    func testHealthUsesExactAuthorizedSleepAndNeverReconstructsOwnedNull() throws {
        let sleep: [String: Any] = ["id": "44444444-4444-4444-8444-444444444444",
            "start_at": "2026-09-20T22:00:00Z", "end_at": "2026-09-21T00:00:00Z",
            "is_nap": false, "stages": [], "asleep_min": 90, "efficiency": 0.75]
        let plan = try CanonicalHealthWritebackPlan.days(state: state(result(sleep: [sleep])))
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].sleeps.count, 1)
        XCTAssertTrue(plan[0].sleeps[0].stages.isEmpty, "No phone-generated asleep intervals")
        XCTAssertNil(plan[0].sleeps[0].hrvRmssdMs, "Sleep-only result must not embed HRV")
        XCTAssertNil(plan[0].sleeps[0].restingHrBpm)
        XCTAssertTrue(plan[0].quantities.isEmpty, "Do not reconstruct nightly HRV or respiration")
        let revoked = try CanonicalHealthWritebackPlan.days(state: state(result(status: "revoked")))
        XCTAssertEqual(revoked.count, 1, "Null states must retain replacement-day identity")
        XCTAssertTrue(revoked[0].quantities.isEmpty)
        XCTAssertTrue(revoked[0].sleeps.isEmpty)
        XCTAssertFalse(CanonicalHealthWritebackPlan.quantities.contains("skin_temp_c"))
    }

    func testHealthRejectsMalformedSessionsInsteadOfEmptyDefaults() throws {
        XCTAssertThrowsError(try CanonicalHealthWritebackPlan.days(state: state(result(sleep: [["id": "bad"]]))))
        let invalid: [String: Any] = ["id": "44444444-4444-4444-8444-444444444444",
            "start_at": "2026-09-21T00:00:00Z", "end_at": "2026-09-20T22:00:00Z",
            "is_nap": false, "stages": []]
        XCTAssertThrowsError(try CanonicalHealthWritebackPlan.days(state: state(result(sleep: [invalid]))))
    }

    func testReadFailureDoesNotRewriteRevisionOrRepublishCachedValueAsCurrent() throws {
        let result = try result(), failed = state(result, phase: .failed)
        let ledger = try XCTUnwrap(CanonicalConsumerPublication.ledger(result, state: failed))
        XCTAssertEqual(ledger.readState, "failed")
        XCTAssertEqual(ledger.families["recovery"]?.resultRevision, "compute:17")
        XCTAssertNil(CanonicalConsumerPublication.value("recovery", in: result, state: failed))
        XCTAssertTrue(try CanonicalHealthWritebackPlan.days(state: failed).isEmpty)
        var snapshot = WidgetSnapshot(recovery: 0, bpm: 70, batteryPct: 50, bonded: true, updated: Date(),
            finalHosted: true, canonicalLedger: ledger)
        XCTAssertFalse(snapshot.hasCanonicalAdmission)
        snapshot.recovery = nil
        XCTAssertTrue(snapshot.hasCanonicalAdmission)
    }

    func testCanonicalSleepUnknownGapsRemainUnknownAndCannotBecomeExportStages() throws {
        let start = 1_789_948_800, end = start + 120
        let formatter = ISO8601DateFormatter()
        let sleep: [String: Any] = ["id": "44444444-4444-4444-8444-444444444444",
            "start_at": formatter.string(from: Date(timeIntervalSince1970: Double(start))),
            "end_at": formatter.string(from: Date(timeIntervalSince1970: Double(end))), "is_nap": false,
            "stages": [
                ["start": start, "end": start + 30, "stage": "light", "state": "sleep"],
                ["start": start + 30, "end": start + 60, "stage": "unknown", "state": "state_unknown"],
                ["start": start + 60, "end": start + 90, "stage": "rem", "state": "state_unknown"],
                ["start": start + 90, "end": end, "stage": "unknown", "state": "sleep_unstaged"]]]
        let plan = try XCTUnwrap(CanonicalHealthWritebackPlan.days(state: state(result(sleep: [sleep]))).first)
        XCTAssertEqual(plan.sleeps[0].stages.count, 4)
        XCTAssertEqual(plan.sleeps[0].stages.compactMap(\.exportStage), ["light"])
        XCTAssertEqual(plan.sleeps[0].stages[1].start, Int64(start + 30))
        XCTAssertEqual(plan.sleeps[0].stages[1].end, Int64(start + 60))
    }

    func testActualDatabaseAccountRouteSleepOnlyEnvelopePassesProductionHealthDecoder() throws {
        // Exact synthetic DB/worker/Edge response captured by the production-route integration gate.
        // This replay does not claim a new live database run or physical HealthKit write.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "compute-account-sleep-only", withExtension: "json"))
        struct Envelope: Decodable {
            struct Scoring: Decodable { let compute: ServerCanonicalResults }
            let server_scoring: Scoring
        }
        let result = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)).server_scoring.compute
        try result.validate(owner: result.ownerID, day: result.day, project: result.project,
                            source: result.sourceID, device: result.deviceID)
        let plan = try XCTUnwrap(CanonicalHealthWritebackPlan.days(state: state(result)).first)
        XCTAssertEqual(plan.sleeps.count, 1)
        XCTAssertEqual(plan.sleeps[0].id, "55555555-5555-4555-8555-555555555555")
        XCTAssertEqual(plan.sleeps[0].asleepMin, 420)
        XCTAssertEqual(plan.sleeps[0].efficiency, 0.875)
        XCTAssertTrue(plan.sleeps[0].stages.isEmpty)
        XCTAssertNil(plan.sleeps[0].hrvRmssdMs)
        XCTAssertNil(plan.sleeps[0].restingHrBpm)
        XCTAssertTrue(plan.quantities.isEmpty)
    }
}
