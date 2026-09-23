import XCTest
import SwiftUI
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandDesign
@testable import Strand

@MainActor
final class CanonicalPhysiologySurfaceTests: XCTestCase {
    private func result(status: String = "available", value: Any = 0,
                        revision: Any = "compute:17", authorization: String = "frwhoop-server-1", details: [String: Any] = [:]) throws -> ServerCanonicalFamilyResult {
        let json: [String: Any] = [
            "owner": "server", "metrics": ["resting_hr_bpm"], "status": status,
            "result_revision": revision, "input_revision": 17,
            "algorithm_version": authorization, "configuration_version": "config-1",
            "manifest_hash": String(repeating: "a", count: 64), "canonical_qualification": "retained_legacy",
            "project": "https://example.supabase.co", "owner_id": UUID().uuidString,
            "source_id": UUID().uuidString, "device_id": UUID().uuidString,
            "window": "2026-09-21", "computed_at": "2026-09-21T00:00:00Z",
            "freshness": "current", "values": ["resting_hr_bpm": value], "details": details
        ]
        return try JSONDecoder().decode(ServerCanonicalFamilyResult.self,
                                        from: JSONSerialization.data(withJSONObject: json))
    }

    func testCanonicalFormatterPreservesValidZeroAndOwnedNull() throws {
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(), metric: "resting_hr_bpm"), "0")
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(value: NSNull()), metric: "resting_hr_bpm"), "—")
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(), metric: "hrv_rmssd_ms"), "—")
    }

    func testMissingRevokedAndUnauthorizedValuesCannotRenderEvenIfPayloadContainsNumber() throws {
        for status in ["unsupported", "insufficient_input", "insufficient_quality", "unqualified", "processing", "failed", "unavailable", "revoked"] {
            XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(status: status, value: 99), metric: "resting_hr_bpm"), "—", status)
        }
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(revision: NSNull()), metric: "resting_hr_bpm"), "—")
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(authorization: "shadow-algorithm"), metric: "resting_hr_bpm"), "—")
    }

    func testMetricMissingnessDoesNotHideTheReasonInsideAPIDetails() throws {
        let missing = try result(value: NSNull(), details: ["metric_availability": [
            "resting_hr_bpm": ["status": "insufficient_input", "reason": "observed_hr_required"]]])
        XCTAssertEqual(CanonicalPhysiologySection.display(result: missing, metric: "resting_hr_bpm"), "—")
        XCTAssertEqual(CanonicalPhysiologySection.missingReason(result: missing, metric: "resting_hr_bpm"), "observed hr required")
        XCTAssertNil(CanonicalPhysiologySection.missingReason(result: missing, metric: "hrv_rmssd_ms"))
        XCTAssertNil(CanonicalPhysiologySection.missingReason(result: try result(value: 60), metric: "resting_hr_bpm"))
        let contradictory = try result(value: 60, details: ["metric_availability": [
            "resting_hr_bpm": ["status": "insufficient_input", "reason": "observed_hr_required"]]])
        XCTAssertNil(CanonicalPhysiologySection.missingReason(result: contradictory, metric: "resting_hr_bpm"))
    }

    func testFinalHostedEntrypointsDoNotOpenRawStoreOrRunPhysiology() async {
        await PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            let repo = Repository(deviceId: "surface-test", openStore: {
                XCTFail("A blocked analytical surface must not open its raw store")
                throw CocoaError(.fileReadNoSuchFile)
            })
            let hub = InsightsHubViewModel()
            await hub.load(repo: repo)
            hub.rankFor(.recovery)
            XCTAssertNil(StressModel(days: [], stored: []))
            XCTAssertNil(repo.hydrationGoalML(profileSex: "female"))
            let counters = PhoneComputeRuntime.counters()
            XCTAssertTrue(counters.executions.isEmpty, "\(counters.executions)")
            for producer in ["InsightsHub.load", "InsightsHub.rank", "StressModel.init", "Repository.hydrationGoal"] {
                XCTAssertEqual(counters.denied[producer], 1, producer)
            }
        }
    }

    func testFinalHostedLegacySleepAdapterCannotReconstructOrReturnLocalModel() {
        let session = CachedSleepSession(startTs: 1, endTs: 28_801, efficiency: 0.9,
            restingHr: 55, avgHrv: 40, stagesJSON: nil)
        let empty: SleepModel.Metric = (nil, nil, [])
        let local = SleepModel(night: Night(session: session, stages: Stages(awake: 10, light: 300, deep: 60, rem: 110)),
            intervals: [], isPersistedHypnogram: false, isStubNight: false,
            performance: empty, efficiency: empty, consistency: empty, hoursVsNeeded: empty,
            restorative: empty, respiratory: empty, sleepDebt: empty,
            typicalTotalMin: 480, typicalDeepMin: 60, typicalRemMin: 110, typicalLightMin: 300,
            trendPoints: [], sleepDebtLedger: SleepDebtLedger(balanceMin: -60, nights: [], needMin: 480))
        PhoneComputeRuntime.$testMode.withValue(.reference) {
            XCTAssertNotNil(ServerScoreSleepPresentation.model(day: "2026-09-21", state: .empty, local: local))
        }
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            XCTAssertNil(ServerScoreSleepPresentation.model(day: "2026-09-21", state: .empty, local: local))
            XCTAssertNil(ServerScoreSleepPresentation.model(day: "2026-09-21", state: .empty, local: nil))
            let counters = PhoneComputeRuntime.counters()
            XCTAssertTrue(counters.executions.isEmpty, "\(counters.executions)")
            XCTAssertEqual(counters.denied["legacy_sleep_presentation_composite"], 2)
        }
    }

    #if os(macOS)
    func testFinalHostedEmbeddedCardsRenderWithoutReconstructingPhysiology() {
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            let repo = Repository(deviceId: "surface-test")
            let content = VStack {
                TrainingLoadCard(days: [])
                WeeklyDigestCard()
                FusedRecordView(record: FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0))
            }.environmentObject(repo).frame(width: 500, height: 1200)
            XCTAssertNotNil(ImageRenderer(content: content).nsImage)
            XCTAssertTrue(PhoneComputeRuntime.counters().executions.isEmpty)
        }
    }
    #endif
}
