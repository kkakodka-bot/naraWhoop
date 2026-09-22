import XCTest
import SwiftUI
import WhoopStore
import WhoopProtocol
@testable import Strand

@MainActor
final class CanonicalPhysiologySurfaceTests: XCTestCase {
    private func result(status: String = "available", value: Any = 0,
                        revision: Any = "immutable-17", authorization: String = "frwhoop-server-1") throws -> ServerCanonicalFamilyResult {
        let json: [String: Any] = [
            "owner": "server", "metrics": ["recovery"], "status": status,
            "result_revision": revision, "input_revision": 17,
            "algorithm_version": authorization, "configuration_version": "config-1",
            "project": "https://example.supabase.co", "owner_id": UUID().uuidString,
            "source_id": UUID().uuidString, "device_id": UUID().uuidString,
            "window": "2026-09-21", "computed_at": "2026-09-21T00:00:00Z",
            "freshness": "current", "values": ["recovery": value], "details": [:]
        ]
        return try JSONDecoder().decode(ServerCanonicalFamilyResult.self,
                                        from: JSONSerialization.data(withJSONObject: json))
    }

    func testCanonicalFormatterPreservesValidZeroAndOwnedNull() throws {
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(), metric: "recovery"), "0")
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(value: NSNull()), metric: "recovery"), "—")
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(), metric: "hrv_rmssd_ms"), "—")
    }

    func testMissingRevokedAndUnauthorizedValuesCannotRenderEvenIfPayloadContainsNumber() throws {
        for status in ["unsupported", "insufficient_input", "insufficient_quality", "unqualified", "processing", "failed", "unavailable", "revoked"] {
            XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(status: status, value: 99), metric: "recovery"), "—", status)
        }
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(revision: NSNull()), metric: "recovery"), "—")
        XCTAssertEqual(CanonicalPhysiologySection.display(result: try result(authorization: "shadow-algorithm"), metric: "recovery"), "—")
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
