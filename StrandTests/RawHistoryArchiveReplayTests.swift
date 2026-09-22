import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore
import GRDB

/// `RawHistoryArchive.replay` re-decodes the durable reject archive through the CURRENT decoder and
/// inserts whatever now decodes — the only path by which already-acked banked history backfills after
/// a newly-landed layout (e.g. WHOOP 4.0 v25). These are three REAL v25 records a pre-v25 build had
/// archived as undecodable; under the current decoder each yields a gravity sample.
final class RawHistoryArchiveReplayTests: XCTestCase {

    func testOwnedReplayNeverImportsGlobalOrOtherDeviceArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = RawHistoryArchive(directory: root.appendingPathComponent("com.noopapp.noop"))
        let frame = bytes("aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44")
        guard case .written = legacy.archive([frame], trim: 70476, family: .whoop4) else { return XCTFail("fixture write") }
        let before = try Data(contentsOf: legacy.fileURL)
        let owner = "11111111-1111-4111-8111-111111111111"
        let source = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let owned = try RawHistoryArchive.owned(ownerId: owner, sourceId: source, deviceId: "strapA",
            physicalDeviceId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", applicationSupport: root)
        let other = try RawHistoryArchive.owned(ownerId: owner, sourceId: source, deviceId: "strapB",
            physicalDeviceId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", applicationSupport: root)
        let replacement = try RawHistoryArchive.owned(ownerId: owner, sourceId: source, deviceId: "strapA",
            physicalDeviceId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", applicationSupport: root)
        let store = try await WhoopStore.inMemory()
        let empty = try await owned.replay(into: store, deviceId: "strapA")
        XCTAssertEqual(empty, 0)
        guard case .written = owned.archive([frame], trim: 70476, family: .whoop4) else { return XCTFail("owned write") }
        XCTAssertEqual(other.readAll().count, 0)
        XCTAssertEqual(replacement.readAll().count, 0)
        do {
            _ = try await owned.replay(into: store, deviceId: "strapB")
            XCTFail("Cannot replay one strap into another")
        } catch CloudCaptureScope.ScopeError.ownerMismatch { }
        let count = try await owned.replay(into: store, deviceId: "strapA")
        XCTAssertEqual(count, 1)
        let devices = try await store.registryWriter.read { try String.fetchAll($0, sql: "SELECT DISTINCT deviceId FROM gravitySample") }
        XCTAssertEqual(devices, ["strapA"])
        XCTAssertEqual(try Data(contentsOf: legacy.fileURL), before)
    }

    /// Minimal BackfillStoreWriting that only records how many gravity samples were handed to insert.
    private final class CaptureStore: BackfillStoreWriting {
        private(set) var insertedGravity = 0
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            insertedGravity += streams.gravity.count
            return (0, 0, 0, 0, 0, 0, 0, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    /// A store whose insert always fails — stands in for a transient DB error during replay. (#152)
    private final class ThrowingStore: BackfillStoreWriting {
        struct Boom: Error {}
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) { throw Boom() }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    func testReplayDecodesArchivedV25IntoGravityRows() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let archive = RawHistoryArchive(directory: dir)
        // Real WHOOP 4.0 v25 records (84 B each, 1 Hz) — undecodable on pre-v25 builds.
        let frames = [
            "aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44",
            "aa50000c2f190014390000150d2b6a487001003ab301008dfd6afdaffda9fdaffd68fddbfb0dfc09fd77fe89fe62febffec9fe91ff0bff81ff5fff3e00d600790078ff3dff4bff801d553c5005010000d7c016b3",
            "aa50000c2f190015390000160d2b6a586b01006d8f0100a3ff94ffc4ffbcffbeff22004a009400cb0048005d006b004400d700130115013301f20088001d0031ffd9fe5eff75ff0048933c50050001008bdf2c2c",
        ].map(bytes)

        // Archive durably, then confirm read-back + replay recover gravity.
        if case .failed = archive.archive(frames, trim: 70476, family: .whoop4) {
            return XCTFail("archive write should not fail")
        }
        XCTAssertEqual(archive.readAll().count, 3, "every archived line should read back")

        let store = CaptureStore()
        let rows = try await archive.replay(into: store, deviceId: "test")
        XCTAssertEqual(rows, 3, "all three v25 records should retro-decode to a gravity sample")
        XCTAssertEqual(store.insertedGravity, 3, "decoded gravity should be forwarded to the store")
    }

    func testReplayOnEmptyArchiveIsNoOp() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-replay-empty-\(UUID().uuidString)", isDirectory: true)
        let archive = RawHistoryArchive(directory: dir)
        XCTAssertEqual(archive.readAll().count, 0)
        let rows = try await archive.replay(into: CaptureStore(), deviceId: "test")
        XCTAssertEqual(rows, 0)
    }

    func testHostedReplayPreservesExistingDerivedHeartRateAndAddsRawPpg() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RawHistoryArchive(directory: directory)
        let v26 = "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff405fb33c50080101006cb67c17"
        let base = 1_780_917_232
        // Synthetic pulse samples in captured framing; no hardware timing or accuracy claim.
        let frames = (0..<12).map { second -> [UInt8] in
            var frame = bytes(v26)
            for (offset, value) in [(11, 25_444_781 + second), (15, base + second)] {
                for byte in 0..<4 { frame[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
            }
            for sample in 0..<24 {
                let phase = Double(second * 24 + sample) / 24.0
                let value = Int(1000 * sin(2 * Double.pi * (70.0 / 60.0) * phase))
                frame[27 + sample * 2] = UInt8(truncatingIfNeeded: value)
                frame[28 + sample * 2] = UInt8(truncatingIfNeeded: value >> 8)
            }
            let end = frame.count - 4
            let checksum = crc32(Array(frame[8..<end]))
            for byte in 0..<4 { frame[end + byte] = UInt8(truncatingIfNeeded: checksum >> (byte * 8)) }
            return frame
        }
        let offline = extractHistoricalStreams(frames.map { parseFrame($0, family: .whoop5) },
                                               deviceClockRef: 0, wallClockRef: 0)
        XCTAssertFalse(offline.ppgHr.isEmpty)
        let store = try await WhoopStore.inMemory()
        let legacy = PpgHrSample(ts: base + 5, bpm: 85, conf: 0.42)
        _ = try await store.insert(Streams(ppgHr: [legacy]), deviceId: "test")
        guard case .written = archive.archive(frames, trim: 1, family: .whoop5) else {
            return XCTFail("fixture archive must be durable")
        }

        _ = try await archive.replay(into: store, deviceId: "test")
        _ = try await archive.replay(into: store, deviceId: "test")
        let derived = try await store.ppgHrSamples(deviceId: "test", from: base, to: base + 12)
        let raw = try await store.ppgWaveformSamples(deviceId: "test", from: base, to: base + 12)
        XCTAssertEqual(derived, [legacy], "replay must neither replace old derived HR nor add new estimates")
        XCTAssertEqual(raw, offline.ppgWaveform, "raw values and record identities must survive idempotent replay")
    }

    /// A failed store insert must PROPAGATE, not be swallowed — that's what lets bootstrapStore keep
    /// the replay gate un-advanced so these records (only copy: the archive) retry next launch. (#152)
    func testReplayThrowsWhenStoreFailsSoGateCanHold() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-replay-throw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let archive = RawHistoryArchive(directory: dir)
        let frame = bytes("aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44")
        if case .failed = archive.archive([frame], trim: 70476, family: .whoop4) {
            return XCTFail("archive write should not fail")
        }

        do {
            _ = try await archive.replay(into: ThrowingStore(), deviceId: "test")
            XCTFail("replay must rethrow a store-insert failure")
        } catch is ThrowingStore.Boom {
            // expected — bootstrapStore's catch leaves the gate un-advanced.
        }
    }

    #if os(iOS)
    /// #649: locked/background BLE must be able to write rejects before acknowledging the strap trim, so the
    /// archive directory + file carry after-first-unlock protection (matching the primary SQLite store),
    /// not iOS's default complete protection which would fail a locked write.
    ///
    /// The iOS Simulator does not enforce data protection and may not report `.protectionKey` at all; when
    /// it doesn't, the write-succeeded check above is all we can assert here, so skip rather than fail on a
    /// platform that can't answer. On a real device (or a sim that does report it) the attribute is checked.
    func testArchiveAndDirectoryUseBackgroundReadableProtection() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-protection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let archive = RawHistoryArchive(directory: dir)
        let frame: [UInt8] = [0xAA, 0x01, 0x00, 0x00, 47, 25, 0x01]
        guard case .written(count: 1) = archive.archive([frame], trim: 1, family: .whoop4) else {
            return XCTFail("archive write should succeed")
        }

        let fm = FileManager.default
        let expected = FileProtectionType.completeUntilFirstUserAuthentication
        let directoryProtection = try fm.attributesOfItem(atPath: dir.path)[.protectionKey] as? FileProtectionType
        let fileProtection = try fm.attributesOfItem(atPath: archive.fileURL.path)[.protectionKey] as? FileProtectionType
        try XCTSkipIf(directoryProtection == nil && fileProtection == nil,
                      "Data protection attributes are not reported on this platform (iOS Simulator).")
        XCTAssertEqual(directoryProtection, expected)
        XCTAssertEqual(fileProtection, expected)
    }
    #endif
}
