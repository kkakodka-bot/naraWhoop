import Combine
import Foundation
import NoopPush
import XCTest
#if !SCORING_INPUT_NATIVE_TESTS
@testable import Strand
#endif

@MainActor
final class ScoringPreferencePublicationFenceTests: XCTestCase {
    private func fixture(_ body: (PreferenceRuntimeFixture) async throws -> Void) async throws {
        let value = try PreferenceRuntimeFixture()
        do {
            try await body(value)
            try await value.close()
            value.defaults.removePersistentDomain(forName: value.domain)
        } catch {
            try await value.close()
            throw error
        }
        // The synthetic SQLite root is retained: consent/journal teardown can outlive observers.
    }

    func testInvalidationPrecedesObserversAndAcceptedValue() async throws {
        try await fixture { value in
            try await value.runtime.hydrate()
            var revoked = false
            var priorSequences: [Int64] = []
            var publicationObserved = false
            value.runtime.willAccept = {
                priorSequences.append(value.runtime.accepted!.position.sequence)
                revoked = true
            }
            let observer = value.runtime.objectWillChange.sink {
                if revoked { publicationObserved = true }
            }
            value.runtime.onAccepted = { snapshot, _ in
                XCTAssertTrue(revoked)
                XCTAssertTrue(publicationObserved)
                XCTAssertEqual(snapshot.position.sequence, 1)
                XCTAssertEqual(value.runtime.accepted?.position.sequence, 1)
            }
            let ticket = value.runtime.complete(value.action(local: true))
            _ = try await ticket.acceptance()
            XCTAssertEqual(priorSequences, [0])
            XCTAssertTrue(publicationObserved)
            XCTAssertEqual(value.runtime.accepted?.weightKg, 71)
            value.runtime.willAccept = nil
            withExtendedLifetime(observer) {}
        }
    }

    func testRetirementInsidePrepublicationHookPreventsHydration() async throws {
        try await fixture { value in
            var publications = 0
            value.runtime.onAccepted = { _, _ in publications += 1 }
            value.runtime.willAccept = {
                XCTAssertNil(value.runtime.accepted)
                value.runtime.retire()
            }
            do {
                try await value.runtime.hydrate()
                XCTFail("retirement during prepublication must reject hydration")
            } catch {
                XCTAssertEqual(error as? ScoringInputJournal.Failure, .retired)
            }
            XCTAssertNil(value.runtime.accepted)
            XCTAssertEqual(publications, 0)
        }
    }

    func testRetirementInvalidatesBeforePublishingClearedState() async throws {
        try await fixture { value in
            try await value.runtime.hydrate()
            var revoked = false
            var observedClearedState = false
            value.runtime.willAccept = { revoked = true }
            let observer = value.runtime.objectWillChange.sink {
                if value.runtime.accepted == nil {
                    XCTAssertTrue(revoked)
                    observedClearedState = true
                }
            }
            value.runtime.retire()
            XCTAssertTrue(revoked)
            XCTAssertTrue(observedClearedState)
            XCTAssertNil(value.runtime.willAccept)
            withExtendedLifetime(observer) {}
        }
    }
}
