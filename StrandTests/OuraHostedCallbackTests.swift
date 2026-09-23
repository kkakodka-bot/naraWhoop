import XCTest
import OuraProtocol
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class OuraHostedCallbackTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    private func source(persist: @escaping (Streams) -> Void,
                        sleep: @escaping (CachedSleepSession) -> Void = { _ in }) -> OuraLiveSource {
        let driver = OuraDriver(ringGen: .gen3, authKey: nil)
        XCTAssertTrue(driver.adoptSyncTimeAnchor(ringTimestamp: 0x0001_0002, unixSeconds: 1_750_000_000))
        let source = OuraLiveSource(live: LiveState(), deviceId: "", ringGen: .gen3,
            authKey: { nil }, persist: persist, persistSleepSession: sleep, startCentral: false)
        source.prepareNotificationTestDriver(driver)
        return source
    }

    func testActualBankedIBICallbackRetainsSixObservedIntervalsWithoutPhoneHR() {
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            var rows: [Streams] = []
            let source = source { rows.append($0) }
            // Existing protocol golden fixture: six original IBI amplitude observations.
            source.ingestNotification(bytes("601202000100807b77757a78e4ddccd4e8d79d33"))
            source.flushNotificationTestBuffer()
            XCTAssertEqual(rows.flatMap(\.rr).count, 6)
            XCTAssertTrue(rows.flatMap(\.hr).isEmpty)
            XCTAssertEqual(PhoneComputeRuntime.counters().executions.values.reduce(0, +), 0)
        }
    }

    func testActualLiveIBICallbackRetainsWireIntervalsWithoutPhoneHR() {
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            var rows: [Streams] = []
            let source = source { rows.append($0) }
            // Anchor record then two existing secure push fixtures; each carries IBI=1025ms.
            source.ingestNotification(bytes("420d0200010000d2dd639001000002"))
            for _ in 0..<2 { source.ingestNotification(bytes("2f0f28020002000001040000000000007f")) }
            source.flushNotificationTestBuffer()
            XCTAssertEqual(rows.flatMap(\.rr).map(\.rrMs), [1025, 1025])
            XCTAssertTrue(rows.flatMap(\.hr).isEmpty)
            XCTAssertEqual(PhoneComputeRuntime.counters().executions.values.reduce(0, +), 0)
        }
    }

    func testActualPhaseCallbackRetainsStageObservationsWithoutPhoneSleepSummary() {
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            var rows: [Streams] = []
            var sessions: [CachedSleepSession] = []
            let source = source(persist: { rows.append($0) }, sleep: { sessions.append($0) })
            source.ingestNotification(bytes("4e0602000100006c"))
            source.stop()
            XCTAssertFalse(rows.flatMap(\.events).filter { $0.kind == OuraStreamMapping.sleepPhaseEventKind }.isEmpty)
            XCTAssertTrue(sessions.isEmpty)
            XCTAssertEqual(PhoneComputeRuntime.counters().executions.values.reduce(0, +), 0)
        }
    }
    func testPublicProducersFailClosedButWireDecoderAndReferenceMathRemainAvailable() {
        let body = [UInt8](bytes("020002000001040000000000007f"))
        let observations = [OuraIBI(ringTimestamp: 1, ibiMs: 1000)]
        PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            XCTAssertNil(OuraDecoders.decodeLiveHRPush(body, ringTimestamp: 1))
            XCTAssertEqual(OuraDecoders.decodeLiveIBIPush(body, ringTimestamp: 1)?.ibiMs, 1025)
            XCTAssertEqual(OuraDriver(ringGen: .gen3, authKey: nil).ingestLiveHRPush(body: body).count, 1)
            XCTAssertTrue(OuraIbiHr.perRecordMedianHR(observations).isEmpty)
            XCTAssertNil(OuraSleepSessionMapping.session(fromCodes: [(1, .light), (31, .awake)]))
            XCTAssertTrue(PhoneComputeRuntime.counters().executions.isEmpty)
        }
        PhoneComputeRuntime.$testMode.withValue(.reference) {
            XCTAssertEqual(OuraDecoders.decodeLiveHRPush(body, ringTimestamp: 1)?.bpm, 59)
            XCTAssertEqual(OuraIbiHr.perRecordMedianHR(observations).first?.bpm, 60)
            XCTAssertEqual(OuraSleepSessionMapping.session(fromCodes: [(1, .light), (31, .awake)])?.efficiency, 0.5)
        }
    }

}
