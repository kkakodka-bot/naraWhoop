#if canImport(Compression)
// Every test here drives the zlib-backed raw outbox (pruneRaw / RawBatchMeta), which exists only
// where Compression does. Same treatment RawOutboxTests gets, for the same reason.
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class PruneTests: XCTestCase {
    private let frames: [[UInt8]] = [[0xAA, 0x00, 0x01, 0x02]]
    private func meta(_ id: String, capturedAt: Int, bytes: Int) -> RawBatchMeta {
        RawBatchMeta(batchId: id, deviceId: "dev1",
                     clockRef: ClockRef(device: 0, wall: 0),
                     capturedAt: capturedAt, startTs: 0, endTs: 0,
                     frameCount: frames.count, byteSize: bytes)
    }

    func testPrunesAgedSyncedBatches() async throws {
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // synced long ago → pruned; synced recently → kept; unsynced → kept (under cap).
        try await store.enqueueRawBatch(meta("aged", capturedAt: 10, bytes: 100), frames: frames)
        try await store.enqueueRawBatch(meta("fresh", capturedAt: 20, bytes: 100), frames: frames)
        try await store.enqueueRawBatch(meta("unsynced", capturedAt: 30, bytes: 100), frames: frames)
        try await store.markRawBatchSynced(batchId: "aged", at: 1000)
        try await store.markRawBatchSynced(batchId: "fresh", at: 9500)

        let pruned = try await store.pruneRaw(now: 10000, keepWindowSeconds: 1000,
                                              maxUnsyncedBytes: 1_000_000)
        XCTAssertEqual(pruned, 1)                                  // only "aged"
        let remaining = try await store.allBatchIdsForTest()
        XCTAssertEqual(remaining, ["fresh", "unsynced"])
    }

    func testEvictsOldestRawBeyondByteCap() async throws {
        // Oldest bytes beyond the cap may retire only after the exact receipt fixture authorizes them.
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("u1", capturedAt: 10, bytes: 500), frames: frames)
        try await store.enqueueRawBatch(meta("u2", capturedAt: 20, bytes: 500), frames: frames)
        try await store.enqueueRawBatch(meta("u3", capturedAt: 30, bytes: 500), frames: frames)
        // Cap 1000 < 1500 total: newest-first u3(500)+u2(500)=1000 fits, u1 tips over → evicted.
        let pruned = try await store.pruneRaw(now: 100, keepWindowSeconds: 0, maxUnsyncedBytes: 1000)
        XCTAssertEqual(pruned, 1)
        let ids = try await store.allBatchIdsForTest()
        XCTAssertEqual(ids, ["u2", "u3"])                          // oldest (u1) dropped
    }

    func testEvictionAppliesToSyncedAndUnsyncedAlike() async throws {
        // The byte cap is a total-footprint bound: a freshly-synced batch still in the keep
        // window counts toward the cap, and the oldest raw (synced or not) is evicted first.
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("s1", capturedAt: 10, bytes: 800), frames: frames)
        try await store.enqueueRawBatch(meta("u2", capturedAt: 20, bytes: 800), frames: frames)
        try await store.markRawBatchSynced(batchId: "s1", at: 9000) // recent → survives Policy 1
        // Cap 1000 < 1600 total: u2(800) fits, s1 tips over → evicted by Policy 2.
        let pruned = try await store.pruneRaw(now: 9500, keepWindowSeconds: 1000, maxUnsyncedBytes: 1000)
        XCTAssertEqual(pruned, 1)
        let ids = try await store.allBatchIdsForTest()
        XCTAssertEqual(ids, ["u2"])
    }

    func testPruneNeverTouchesDecodedTables() async throws {
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1, bpm: 60)]), deviceId: "dev1")
        try await store.enqueueRawBatch(meta("aged", capturedAt: 10, bytes: 100), frames: frames)
        try await store.markRawBatchSynced(batchId: "aged", at: 1)
        _ = try await store.pruneRaw(now: 100000, keepWindowSeconds: 10, maxUnsyncedBytes: 0)
        let rowCounts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(rowCounts.hr, 1)   // decoded untouched
    }

    func testNothingToPruneReturnsZero() async throws {
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("u1", capturedAt: 10, bytes: 100), frames: frames)
        let pruned = try await store.pruneRaw(now: 100, keepWindowSeconds: 1000,
                                              maxUnsyncedBytes: 1_000_000)
        XCTAssertEqual(pruned, 0)
    }

    func testLargeBacklogMakesBoundedProgressWithoutDeletingNewestBytes() async throws {
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let count = WhoopStore.rawPruneRowLimit * 3 + 29
        for index in 0..<count {
            try await store.enqueueRawBatch(meta("batch-\(index)", capturedAt: index, bytes: 1), frames: frames)
        }
        var deleted = 0
        for _ in 0..<4 {
            let page = try await store.pruneRaw(now: count + 1, keepWindowSeconds: 0, maxUnsyncedBytes: 7)
            XCTAssertGreaterThan(page, 0)
            XCTAssertLessThanOrEqual(page, WhoopStore.rawPruneRowLimit)
            deleted += page
            let retained = try await store.allBatchIdsForTest()
            XCTAssertEqual(retained.count, count - deleted)
            for index in (count - 7)..<count { XCTAssertTrue(retained.contains("batch-\(index)")) }
        }
        XCTAssertEqual(deleted, count - 7)
        let idle = try await store.pruneRaw(now: count + 1, keepWindowSeconds: 0, maxUnsyncedBytes: 7)
        XCTAssertEqual(idle, 0)
    }

    func testAgingAndByteCapShareOneDeletionBudget() async throws {
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let aged = WhoopStore.rawPruneRowLimit - 5
        for index in 0..<(aged + 20) {
            let key = "batch-\(index)"
            try await store.enqueueRawBatch(meta(key, capturedAt: index, bytes: 1), frames: frames)
            if index < aged { try await store.markRawBatchSynced(batchId: key, at: 1) }
        }
        let first = try await store.pruneRaw(now: 10_000, keepWindowSeconds: 1_000, maxUnsyncedBytes: 0)
        XCTAssertEqual(first, WhoopStore.rawPruneRowLimit)
        let retained = try await store.allBatchIdsForTest()
        let expected = Set(((aged + 5)..<(aged + 20)).map { "batch-\($0)" })
        XCTAssertEqual(Set(retained), expected)
        let second = try await store.pruneRaw(now: 10_000, keepWindowSeconds: 1_000, maxUnsyncedBytes: 0)
        XCTAssertEqual(second, 15)
    }

    func testUnreceiptedRowsConsumeTheCapWithoutExposingNewerInCapRows() async throws {
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        for (key, timestamp, bytes) in [
            ("oldest-unreceipted", 10, 400), ("old-receipted", 20, 400),
            ("boundary-unreceipted", 30, 600), ("newest-protected", 40, 600),
        ] {
            try await store.enqueueRawBatch(meta(key, capturedAt: timestamp, bytes: bytes), frames: frames)
        }
        try await store.registryWriter.write { db in
            try db.execute(sql: "DELETE FROM rawDurabilityReceipt WHERE resourceKey IN ('oldest-unreceipted','boundary-unreceipted')")
        }
        let deleted = try await store.pruneRaw(now: 100, keepWindowSeconds: 0, maxUnsyncedBytes: 1_000)
        XCTAssertEqual(deleted, 1)
        let retained = try await store.allBatchIdsForTest()
        XCTAssertEqual(Set(retained), ["oldest-unreceipted", "boundary-unreceipted", "newest-protected"])
        let held = try await store.pruneRaw(now: 100, keepWindowSeconds: 0, maxUnsyncedBytes: 1_000)
        XCTAssertEqual(held, 0, "Unreceipted debt can exceed the cap without authorizing newer bytes")
    }

    func testEqualCaptureTimesKeepTheNewestRowIDsWithinTheCap() async throws {
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        for key in ["first", "second", "third"] {
            try await store.enqueueRawBatch(meta(key, capturedAt: 10, bytes: 500), frames: frames)
        }
        let deleted = try await store.pruneRaw(now: 100, keepWindowSeconds: 0, maxUnsyncedBytes: 1_000)
        XCTAssertEqual(deleted, 1)
        let retained = try await store.allBatchIdsForTest()
        XCTAssertEqual(Set(retained), ["second", "third"])
    }

    func testMismatchedOrUnexpiredReceiptsCannotAuthorizeEitherDeletionPolicy() async throws {
        let store = try await receiptedFixtureStore()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let keys = ["valid", "digest-mismatch", "owner-mismatch", "future-retention", "missing-receipt", "unassigned-source"]
        for key in keys {
            try await store.enqueueRawBatch(meta(key, capturedAt: 10, bytes: 100), frames: frames)
            try await store.markRawBatchSynced(batchId: key, at: 1)
        }
        try await store.registryWriter.write { db in
            // Persisted evidence corruption must fail closed, even if a legacy synced flag is present.
            try db.execute(sql: "UPDATE rawDurabilityReceipt SET contentSHA256 = ? WHERE resourceKey = 'digest-mismatch'",
                           arguments: [String(repeating: "0", count: 64)])
            try db.execute(sql: "UPDATE rawDurabilityReceipt SET scopeKey = 'other-synthetic-owner' WHERE resourceKey = 'owner-mismatch'")
            try db.execute(sql: "UPDATE rawDurabilityReceipt SET retainUntil = 20000 WHERE resourceKey = 'future-retention'")
            try db.execute(sql: "DELETE FROM rawDurabilityReceipt WHERE resourceKey = 'missing-receipt'")
            try db.execute(sql: "UPDATE ingestRawResource SET environment = NULL, accountId = NULL WHERE resourceKey = 'unassigned-source'")
        }
        let deleted = try await store.pruneRaw(now: 10_000, keepWindowSeconds: 100, maxUnsyncedBytes: 0)
        XCTAssertEqual(deleted, 1)
        let retained = try await store.allBatchIdsForTest()
        XCTAssertEqual(Set(retained), Set(keys.dropFirst()))
    }

}
#endif
