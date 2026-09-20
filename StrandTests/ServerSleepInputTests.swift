import Foundation
import NoopPush
import WhoopStore
import XCTest
@testable import Strand

@MainActor
final class ServerSleepInputTests: XCTestCase {
    private let day = "2026-09-18"
    private let source = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    private let start = 1_789_693_200 // 2026-09-18 01:00 UTC
    private let end = 1_789_711_200

    private func state(identity: Bool = true, empty: Bool = false) throws -> ServerScoreViewState {
        var sleep: [String: Any] = ["id": id, "start_at": "2026-09-18T01:00:00Z",
            "end_at": "2026-09-18T06:00:00Z", "is_nap": false, "stages": []]
        if identity { sleep.merge(["originalStart": start, "originalEnd": end, "editEntity": "sleep:" + id]) { _, b in b } }
        let payload: [String: Any] = ["schemaVersion": 2,
            "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "sourceDeviceId": source,
            "day": day, "timezone": "UTC", "algorithmVersion": "history-test",
            "inputRevision": 3, "resultRevision": 4, "computedAt": "2026-09-18T07:00:00Z",
            "status": "partial", "coverage": [:], "daily": [:], "sleep": empty ? [] : [sleep],
            "dependency": ["stateSchemaVersion": 1, "generation": 3, "configurationRevision": 1,
                           "profileRevision": 1, "sourceEra": "test"]]
        let decoded = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: payload), requestedDay: day)
        let entry = ServerScoreDayState(snapshot: decoded.snapshot, phase: .partial, fetchedAt: nil,
            cached: true, pending: false, requestedInputRevision: 3, archiveStatus: nil)
        return ServerScoreViewState(generation: UUID(), revision: 4, currentDay: day, timezone: "UTC",
            configured: true, authenticated: true, capabilities: [.sleepSessions], activated: [.sleepSessions], days: [day: entry])
    }

    func testEditDeleteUndoAreOrderedDurableInputsWithoutOpeningLocalPhysiology() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AccountStorageLayout(baseDirectory: root,
            scope: try AccountScope(projectURL: "https://sleep-input.invalid", userID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let journal = try ScoringInputJournal(layout: layout)
        var opens = 0
        let repo = Repository(deviceId: "my-whoop", openStore: { opens += 1; throw ScoringInputJournal.Failure.invalidInput })
        repo.scoringInputWriter = { _ = try await journal.enqueue($0) }
        repo.applyServerScores(try state())
        let original = repo.sleeps
        await repo.editSleepTimes(detectedStartTs: start, oldEndTs: end, storedStagesJSON: nil,
                                  newStartTs: start + 60, newEndTs: end - 60)
        let undo = await repo.deleteSleepSession(detectedStartTs: start, endTs: end)
        await repo.undoDeleteSleepSession(try XCTUnwrap(undo))
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(repo.sleeps, original, "pending edits do not forge server results")
        XCTAssertNil(repo.serverInputError)
        await journal.retire()
        let reopened = try ScoringInputJournal(layout: layout)
        let status = try await reopened.status()
        XCTAssertEqual(status.pending, 3)
        for (offset, dismissed) in [false, true, false].enumerated() {
            let pending = try await reopened.next()
            let input = try XCTUnwrap(pending)
            XCTAssertEqual(input.change.entity, "sleep:" + id)
            XCTAssertEqual(input.change.device, source)
            XCTAssertEqual(input.change.kind, .sleepEdit)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: input.change.payload) as? [String: Any])
            XCTAssertEqual(payload["dismissed"] as? Bool, dismissed)
            XCTAssertEqual(payload["originalStart"] as? Int, start)
            XCTAssertEqual(payload["originalEnd"] as? Int, end)
            XCTAssertNil(payload["stages"], "the phone does not restage or synthesize sleep")
            let receipt = ScoringInputReceipt(schemaVersion: 1,
                userId: try XCTUnwrap(UUID(uuidString: input.scope.userID)),
                sourceDeviceId: try XCTUnwrap(UUID(uuidString: input.change.device)), kind: input.change.kind,
                entity: input.change.entity, revision: Int64(offset + 1), clientId: input.clientID,
                clientMutationId: try XCTUnwrap(UUID(uuidString: input.id)), clientRevision: input.clientRevision,
                effectiveDay: input.change.effectiveDay, deleted: input.change.deleted,
                invalidatedFrom: input.change.effectiveDay)
            try await reopened.settle(input, receipt: receipt)
        }
    }

    func testRejectedAdmissionLeavesAuthoritativeSessionAndReturnsNoUndo() async throws {
        let repo = Repository(deviceId: "my-whoop")
        repo.applyServerScores(try state())
        let original = repo.sleeps
        repo.scoringInputWriter = { _ in throw ScoringInputJournal.Failure.storageLimit }
        let undo = await repo.deleteSleepSession(detectedStartTs: start, endTs: end)
        XCTAssertNil(undo)
        XCTAssertEqual(repo.sleeps, original)
        XCTAssertNotNil(repo.serverInputError)
        XCTAssertTrue(repo.dismissedSleepWindows().isEmpty)
    }

    func testMissingIdentityFailsClosedAndRetiredRepositoryCannotQueue() async throws {
        let repo = Repository(deviceId: "my-whoop")
        var writes = 0
        repo.scoringInputWriter = { _ in writes += 1 }
        repo.applyServerScores(try state(identity: false))
        await repo.editSleepTimes(detectedStartTs: start, oldEndTs: end, storedStagesJSON: nil,
                                  newStartTs: start + 60, newEndTs: end)
        XCTAssertEqual(writes, 0)
        XCTAssertNotNil(repo.serverInputError)
        repo.applyServerScores(try state())
        repo.shutdownForAccountChange()
        await repo.editSleepTimes(detectedStartTs: start, oldEndTs: end, storedStagesJSON: nil,
                                  newStartTs: start + 60, newEndTs: end)
        XCTAssertEqual(writes, 0)
    }

    func testManualNapOnEmptyServerDayQueuesStableIdentityWithoutLocalStaging() async throws {
        let repo = Repository(deviceId: "my-whoop")
        var changes: [ScoringInputChange] = []
        repo.scoringInputWriter = { changes.append($0) }
        repo.applyServerScores(try state(empty: true))
        await repo.addManualNap(startTs: start, endTs: start + 1200)
        let change = try XCTUnwrap(changes.first)
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(change.entity.hasPrefix("sleep:"))
        XCTAssertNotNil(UUID(uuidString: String(change.entity.dropFirst(6))))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: change.payload) as? [String: Any])
        XCTAssertEqual(payload["isNap"] as? Bool, true)
        XCTAssertNil(payload["stages"])
        XCTAssertTrue(repo.sleeps.isEmpty)
    }

    func testEarlierWakeDayUsesSnapshotTimezoneAcrossDaylightSavingTransition() throws {
        let parse = ISO8601DateFormatter()
        func timestamp(_ value: String) throws -> Int {
            Int(try XCTUnwrap(parse.date(from: value)).timeIntervalSince1970)
        }
        let originalStart = try timestamp("2026-11-01T06:00:00Z")
        let originalEnd = try timestamp("2026-11-01T16:00:00Z")
        let earlierEnd = try timestamp("2026-11-01T06:45:00Z") // Oct 31, 23:45 PDT
        let input = ServerSleepInput(device: source, day: "2026-11-01", entity: "sleep:" + id,
            originalStart: originalStart, originalEnd: originalEnd, start: originalStart,
            end: originalEnd, isNap: false, timezone: "America/Los_Angeles")
        let changed = try input.change(end: earlierEnd)
        XCTAssertEqual(changed.effectiveDay, "2026-10-31")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: changed.payload) as? [String: Any])
        XCTAssertEqual(payload["originalEnd"] as? Int, originalEnd)
        XCTAssertEqual(payload["end"] as? Int, earlierEnd)
    }
}
