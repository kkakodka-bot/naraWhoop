import Foundation
import GRDB
import NoopPush
import WhoopStore
import XCTest
#if !SCORING_INPUT_NATIVE_TESTS
@testable import Strand
#endif

@MainActor
final class ScoringConsentRelayTests: XCTestCase {
    private let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private func fixture() throws -> AccountStorageLayout {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AccountStorageLayout(baseDirectory: root,
            scope: try AccountScope(projectURL: "https://consent-relay.invalid", userID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    }

    private func config(_ enabled: Bool, day: String = "2026-09-17") throws -> ScoringConsentConfiguration {
        .init(change: try ScoringInputChange(device: device, kind: .config, entity: "primary", effectiveDay: day,
            payload: JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "journalContextEnabled": enabled])),
            timezone: "America/Los_Angeles")
    }

    private func offline(_ layout: AccountStorageLayout) throws -> ScoringInputCoordinator {
        let inputs = ScoringInputCoordinator(context: .init(scope: try XCTUnwrap(layout.scope), generation: UUID()), layout: layout,
            dependencies: .init(isCurrent: { _ in true }, canUpload: { false }, head: { _, _ in
                XCTFail("paused delivery performed a head request"); throw ScoringInputRPC.Failure.unavailable
            }, send: { _, _ in
                XCTFail("paused delivery performed a mutation"); throw ScoringInputRPC.Failure.unavailable
            }))
        addTeardownBlock { try await inputs.waitForRetirement() }
        return inputs
    }

    func testDecisionCompletionPublishesAfterSavingEndsAndNeverAfterRetirement() async throws {
        let layout = try fixture()
        let consent = ScoringContextConsent(layout: layout)
        await consent.load()
        let frozen = try config(true)
        consent.configuration = { _, _, _ in frozen }
        var completions = 0
        consent.willChange = { [weak consent] in XCTAssertEqual(consent?.saving, true) }
        consent.didChange = { [weak consent] in
            completions += 1
            XCTAssertEqual(consent?.saving, false, "presentation must observe the completed transition")
        }
        await consent.setEnabled(true, purpose: .journal)
        XCTAssertEqual(completions, 1); XCTAssertTrue(consent.enabled(.journal))
        let database = try DatabaseQueue(path: layout.directory.appendingPathComponent("scoring-context-consent.sqlite").path)
        defer { try? database.close() }
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_completion BEFORE UPDATE ON consent_decision
                BEGIN SELECT RAISE(ABORT,'synthetic completion failure'); END;
                """)
        }
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertEqual(completions, 2); XCTAssertFalse(consent.enabled(.journal))
        XCTAssertNotNil(consent.error)
        consent.willChange = { [weak consent] in consent?.retire() }
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertEqual(completions, 2, "a retired runtime must not republish")
        XCTAssertFalse(consent.saving)
    }

    func testCrashAfterConsentCommitRetainsFrozenDayTimezoneSourceAndPayload() async throws {
        let layout = try fixture()
        let consent = ScoringContextConsent(layout: layout)
        let frozen = try config(false)
        consent.configuration = { _, _, _ in frozen }
        await consent.load()
        await consent.setEnabled(false, purpose: .journal, now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(consent.error)
        consent.retire()
        let reopened = ScoringContextConsent(layout: layout)
        await reopened.load()
        reopened.configuration = { _, _, _ in
            XCTFail("recovery must not rebuild an old choice from today's preferences")
            throw ScoringInputJournal.Failure.invalidInput
        }
        let inputs = try offline(layout)
        try await reopened.relay(to: inputs)
        try await reopened.relay(to: inputs)
        let journal = try ScoringInputJournal(layout: layout)
        let next = try await journal.next()
        XCTAssertEqual(next?.change, frozen.change)
        let status = try await journal.status()
        XCTAssertEqual(status.pending, 1)
        let stored = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let intents = try await stored.pendingIntents()
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.configuration, frozen)
        XCTAssertEqual(intents.first?.id.uuidString.lowercased(), next?.id)
        reopened.retire(); inputs.retire(); await journal.retire()
    }

    func testRelayCrashAfterImportAndAfterReceiptReusesOriginalMutation() async throws {
        let layout = try fixture()
        let store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let frozen = try config(false)
        _ = try await store.set(.journal, enabled: false, configuration: frozen)
        let intents = try await store.pendingIntents()
        let intent = try XCTUnwrap(intents.first)
        let journal = try ScoringInputJournal(layout: layout)
        _ = try await journal.importOrigin(intent.id, change: frozen.change, position: intent.position)
        let firstValue = try await journal.next()
        let first = try XCTUnwrap(firstValue)
        let replay = try await journal.importOrigin(intent.id, change: frozen.change, position: intent.position)
        XCTAssertEqual(replay, .queued(first.id))
        let receipt = ScoringInputJournalTests.receipt(first, revision: 12)
        try await journal.settle(first, receipt: receipt)
        await journal.retire()
        let recovered = try ScoringInputJournal(layout: layout)
        let afterLostLocalRelayReceipt = try await recovered.importOrigin(intent.id, change: frozen.change, position: intent.position)
        XCTAssertEqual(afterLostLocalRelayReceipt, .accepted(receipt))
        try await store.recordProgress(afterLostLocalRelayReceipt, for: intent)
        let pending = try await store.pendingIntents()
        let status = try await recovered.status()
        XCTAssertTrue(pending.isEmpty); XCTAssertEqual(status.pending, 0)
        do {
            _ = try await recovered.importOrigin(intent.id, change: config(true).change, position: intent.position)
            XCTFail("a stable origin accepted changed content")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .invalidInput) }
        await recovered.retire()
    }

    func testRapidToggleRelayPrecedesFreshConfigAndNeverAppendsAnOldChoiceAgain() async throws {
        let layout = try fixture()
        let store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let first = try config(false)
        let second = try config(true, day: "2026-09-18")
        _ = try await store.set(.journal, enabled: false, configuration: first)
        _ = try await store.set(.journal, enabled: true, configuration: second)
        let consent = ScoringContextConsent(layout: layout)
        await consent.load()
        let inputs = try offline(layout)
        inputs.prepareAdmission = { [weak consent, weak inputs] in
            guard let consent, let inputs else { throw ScoringInputJournal.Failure.retired }
            try await consent.relay(to: inputs)
        }
        let fresh = try config(false, day: "2026-09-19").change
        try await inputs.enqueue(fresh)
        // Join the coordinator's offline relay before this test drives the same SQLite file
        // through a second writer. No concurrent drain is part of this ordering assertion.
        await inputs.reconcile()?.value
        let journal = try ScoringInputJournal(layout: layout)
        var revision: Int64 = 0
        var ids: [String] = []
        for expected in [first.change, second.change, fresh] {
            let nextValue = try await journal.next()
            let next = try XCTUnwrap(nextValue)
            XCTAssertEqual(next.change, expected)
            ids.append(next.id); revision += 1
            try await journal.settle(next, receipt: ScoringInputJournalTests.receipt(next, revision: revision))
        }
        XCTAssertEqual(Set(ids).count, 3)
        try await consent.relay(to: inputs)
        try await consent.relay(to: inputs)
        let status = try await journal.status()
        XCTAssertEqual(status.pending, 0)
        consent.retire(); inputs.retire(); await journal.retire()
    }

    func testFailedDecisionTransactionRetainsDenialButNeverRelaysFailedGrant() async throws {
        let layout = try fixture()
        let store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        _ = try await store.set(.journal, enabled: true)
        let database = try DatabaseQueue(path: layout.directory.appendingPathComponent("scoring-context-consent.sqlite").path)
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_decision BEFORE UPDATE ON consent_decision
                BEGIN SELECT RAISE(ABORT,'injected decision failure'); END;
                """)
        }
        do { _ = try await store.set(.journal, enabled: false, configuration: config(false)); XCTFail("denial write unexpectedly passed") } catch {}
        let reopened = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let values = try await reopened.read()
        XCTAssertEqual(values[.journal]?.enabled, false)
        let denials = try await reopened.pendingIntents()
        XCTAssertEqual(denials.map(\.configuration), [try config(false)])
        do { _ = try await reopened.set(.journal, enabled: true, configuration: config(true)); XCTFail("grant write unexpectedly passed") } catch {}
        let afterGrant = try await reopened.pendingIntents()
        XCTAssertEqual(afterGrant, denials)
        let held = try await reopened.read()
        XCTAssertEqual(held[.journal]?.enabled, false)
    }

    func testOriginAndMutationRollbackTogetherAtRetiredCommitBoundary() async throws {
        let layout = try fixture()
        let fence = StoreWriteFence()
        let journal = try ScoringInputJournal(layout: layout, fence: fence)
        let origin = UUID(), change = try config(false).change
        let position = ScoringInputJournal.OriginPosition(source: UUID(), sequence: 1)
        do {
            _ = try await journal.importOrigin(origin, change: change, position: position, beforeCommit: { fence.invalidate() })
            XCTFail("retired origin committed")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired) }
        let reopened = try ScoringInputJournal(layout: layout)
        let progress = try await reopened.originProgress(origin)
        let status = try await reopened.status()
        XCTAssertNil(progress); XCTAssertEqual(status.pending, 0)
        _ = try await reopened.importOrigin(origin, change: change, position: position)
        let next = try await reopened.next()
        XCTAssertEqual(next?.id, origin.uuidString.lowercased())
        await reopened.retire()
    }

    func testConfigurationCaptureFailureStillPersistsPurposePauseBeforeReopen() async throws {
        let layout = try fixture()
        let consent = ScoringContextConsent(layout: layout)
        await consent.load(); await consent.setEnabled(true, purpose: .journal)
        consent.configuration = { _, _, _ in throw ScoringInputJournal.Failure.invalidInput }
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertNotNil(consent.error); XCTAssertFalse(consent.enabled(.journal))
        consent.retire()
        let reopened = ScoringContextConsent(layout: layout)
        await reopened.load()
        XCTAssertNotNil(reopened.error); XCTAssertFalse(reopened.enabled(.journal))
        let store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        let intents = try await store.pendingIntents()
        XCTAssertTrue(intents.isEmpty, "a missing snapshot is not permission to fabricate a remote payload")
        reopened.retire()
    }

    func testOwnerlessPopulatedConsentOutboxIsNotAdopted() async throws {
        let layout = try fixture()
        let store = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
        _ = try await store.set(.journal, enabled: false, configuration: config(false))
        let database = try DatabaseQueue(path: layout.directory.appendingPathComponent("scoring-context-consent.sqlite").path)
        try await database.write { db in
            try db.execute(sql: "DELETE FROM consent_owner; DELETE FROM consent_decision")
        }
        do {
            _ = try ScoringContextConsentStore(layout: layout, fence: StoreWriteFence())
            XCTFail("ownerless retained intent was rebound")
        } catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .wrongOwner) }
        let count = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM consent_intent") }
        XCTAssertEqual(count, 1)
    }

    func testReviewedReplacementIsNotMisreportedAsOriginalConsentReceipt() async throws {
        let layout = try fixture()
        let journal = try ScoringInputJournal(layout: layout)
        let id = UUID(), change = try config(false).change
        let position = ScoringInputJournal.OriginPosition(source: UUID(), sequence: 1)
        _ = try await journal.importOrigin(id, change: change, position: position)
        let nextValue = try await journal.next()
        let next = try XCTUnwrap(nextValue)
        try await journal.retry(next, conflict: true)
        let reviewValue = try await journal.conflict(id: next.id)
        let review = try XCTUnwrap(reviewValue)
        let replacement = try await journal.resolveConflict(review,
            head: ScoringInputJournalTests.head(change, scope: try XCTUnwrap(layout.scope), revision: 9),
            replacement: config(true).change)
        let replay = try await journal.importOrigin(id, change: change, position: position)
        XCTAssertEqual(replay, .resolved(replacement))
        await journal.retire()
    }

    func testConsentRelayCannotCrossAccountOrProject() async throws {
        let layout = try fixture(), other = try fixture()
        let consent = ScoringContextConsent(layout: layout)
        consent.configuration = { [self] _, enabled, _ in try config(enabled) }
        await consent.load(); await consent.setEnabled(false, purpose: .journal)
        let otherLayout = AccountStorageLayout(baseDirectory: other.directory,
            scope: try AccountScope(projectURL: "https://other.invalid", userID: device))
        let inputs = try offline(otherLayout)
        do { try await consent.relay(to: inputs); XCTFail("another account adopted consent intent") }
        catch { XCTAssertEqual(error as? ScoringInputJournal.Failure, .wrongOwner) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherLayout.directory.appendingPathComponent("history-inputs.sqlite").path))
        consent.retire(); inputs.retire()
    }
}
