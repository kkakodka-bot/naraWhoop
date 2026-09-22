import Foundation
import NoopPush
import XCTest
#if !SCORING_INPUT_NATIVE_TESTS
@testable import Strand
#endif

@MainActor
final class AccountAlgorithmChoicesTests: XCTestCase {
    private func fixture(_ body: (PreferenceRuntimeFixture) async throws -> Void) async throws {
        let f = try PreferenceRuntimeFixture()
        let failures = testRun?.failureCount ?? 0
        do {
            try await body(f); try await f.close()
            if testRun?.failureCount == failures {
                f.defaults.removePersistentDomain(forName: f.domain)
                if FileManager.default.fileExists(atPath: f.root.path) { try FileManager.default.removeItem(at: f.root) }
            } else { print("Preserved choice fixture: \(f.root.path) suite=\(f.domain)") }
        } catch {
            try await f.close(); print("Preserved choice fixture: \(f.root.path) suite=\(f.domain)"); throw error
        }
    }

    func testFiveDefaultsAreExactAndUnownedFallbackIsNotAdopted() async throws {
        try await fixture { f in
            f.defaults.register(defaults: ["noopBanisterEffort": true, "noopExperimentalSleepV2": false,
                "noopMotionAwareWake": true, "noopStressPersonalBaseline": true, "noopSpo2CandidateDisplay": false])
            let preferences = AccountPreferences(defaults: f.defaults, domainName: f.domain, isCurrent: { true })
            let expected = ScoringAlgorithmChoices(banisterEffortEnabled: false, useSleepStagerV2: true,
                useMotionAwareWake: false, daytimePersonalBaselineEnabled: false, spo2CandidateDisplayEnabled: true)
            XCTAssertEqual(preferences.algorithmChoices, expected)
            preferences.bindScoringPreferences(f.runtime)
            try await f.runtime.hydrate()
            XCTAssertEqual(preferences.algorithmChoices, expected)
            XCTAssertEqual(f.runtime.accepted?.algorithmChoices, expected)
            XCTAssertTrue(f.runtime.accepted!.provenance.isEmpty)
            XCTAssertEqual(try f.intents().count, 0)
        }
    }

    func testScopedProfileIgnoresFallbackBeforeBindingAndDoesNotWriteDefaults() async throws {
        try await fixture { f in
            let sentinel = Date(timeIntervalSince1970: 100)
            f.defaults.register(defaults: ["profile.dateOfBirth": sentinel, "profile.ageExplicit": true,
                "profile.sex": "female", "profile.weightKg": 99.0, "profile.heightCm": 200.0,
                "profile.hrMaxOverride": 201, "profile.stepTicksPerStep": 8.0,
                "profile.stepsManualCoefficient": 4.0])
            let profile = ProfileStore(defaults: f.defaults, domainName: f.domain)
            XCTAssertNotEqual(profile.dateOfBirth, sentinel)
            XCTAssertEqual(profile.sex, "male"); XCTAssertEqual(profile.weightKg, 75)
            XCTAssertEqual(profile.heightCm, 178); XCTAssertEqual(profile.stepTicksPerStep, 1)
            XCTAssertEqual(profile.stepsManualCoefficient, 0); XCTAssertNil(profile.confirmedMaxHR)
            XCTAssertTrue(profile.scoringProfileValues.isEmpty)
            XCTAssertTrue(f.defaults.persistentDomain(forName: f.domain)?.isEmpty ?? true)
            let guest = ProfileStore(defaults: f.defaults)
            XCTAssertEqual(guest.weightKg, 99)
            guest.weightKg = 88
            XCTAssertEqual(guest.weightKg, 88)
            XCTAssertEqual(f.defaults.double(forKey: "profile.weightKg"), 88)
        }
    }

    func testBoundFacadesHaveOneAcceptedAuthorityAndLegacySettersCannotBypassIt() async throws {
        try await fixture { f in
            let profile = ProfileStore(defaults: f.defaults, domainName: f.domain)
            let preferences = AccountPreferences(defaults: f.defaults, domainName: f.domain, isCurrent: { f.current.get() })
            let behavior = BehaviorStore(defaults: f.defaults)
            profile.bindScoringPreferences(f.runtime); preferences.bindScoringPreferences(f.runtime)
            behavior.bindScoringPreferences(f.runtime)
            try await f.runtime.hydrate()
            profile.weightKg = 99; profile.hrMaxOverride = 200; preferences.hrvWindowRaw = "deep"
            behavior.recalibrateChargeBaseline(now: 1_700_000_000)
            XCTAssertEqual(profile.weightKg, 75); XCTAssertEqual(profile.hrMaxOverride, 0)
            XCTAssertEqual(preferences.hrvWindowRaw, "whole"); XCTAssertEqual(behavior.chargeBaselineEpoch, 0)
            XCTAssertTrue(f.defaults.persistentDomain(forName: f.domain)?.isEmpty ?? true)
            let epoch = PreferenceRuntimeFixture.date.timeIntervalSince1970
            let ticket = f.runtime.complete(f.action([
                .init(key: .weightKg, value: .number(82)), .init(key: .hrvWindow, value: .text("deep")),
                .init(key: .hrvBaselineEpoch, value: .number(epoch)), .init(key: .recoveryBaselineEpoch, value: .number(epoch)),
                .init(key: .effortMethod, value: .text("BANISTER")), .init(key: .useSleepStagerV2, value: .boolean(false)),
                .init(key: .useMotionAwareWake, value: .boolean(true)), .init(key: .daytimePersonalBaselineEnabled, value: .boolean(true)),
                .init(key: .spo2CandidateDisplayEnabled, value: .boolean(false))]))
            _ = try await ticket.acceptance()
            XCTAssertEqual(profile.weightKg, 82); XCTAssertEqual(preferences.hrvWindowRaw, "deep")
            XCTAssertEqual(behavior.chargeBaselineEpoch, epoch)
            XCTAssertEqual(f.runtime.accepted?.hrvBaselineEpoch, epoch)
            XCTAssertEqual(preferences.algorithmChoices, .init(banisterEffortEnabled: true, useSleepStagerV2: false,
                useMotionAwareWake: true, daytimePersonalBaselineEnabled: true, spo2CandidateDisplayEnabled: false))
            f.defaults.set(200, forKey: "profile.weightKg")
            XCTAssertEqual(profile.weightKg, 82, "mutable mirror is not authoritative")
            f.current.set(false)
            XCTAssertNil(f.runtime.accepted)
            XCTAssertEqual(profile.weightKg, 75); XCTAssertEqual(preferences.hrvWindowRaw, "whole")
            XCTAssertEqual(behavior.chargeBaselineEpoch, 0)
        }
    }

    func testClearRemovesOverrideAndReopenDoesNotResurrectLegacySeed() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            _ = try await f.runtime.complete(f.action([.init(key: .effortMethod, value: .text("BANISTER")),
                .init(key: .weightKg, value: .number(82))])).acceptance()
            _ = try await f.runtime.complete(f.action([.init(key: .effortMethod, value: .clear),
                .init(key: .weightKg, value: .clear)])).acceptance()
            XCTAssertFalse(f.runtime.accepted!.hasOverride(.weightKg))
            XCTAssertEqual(f.runtime.accepted?.weightKg, 75)
            XCTAssertFalse(f.runtime.accepted!.algorithmChoices.banisterEffortEnabled)
            XCTAssertNil(f.defaults.persistentDomain(forName: f.domain)?["profile.weightKg"])
            XCTAssertNil(f.defaults.persistentDomain(forName: f.domain)?["noopBanisterEffort"])
            try await f.close()
            let next = try PreferenceRuntimeFixture(root: f.root,
                context: .init(scope: f.context.scope, generation: UUID()), domain: f.domain,
                seed: ["profile.weightKg": 99.0, "noopBanisterEffort": true])
            try await next.runtime.hydrate()
            XCTAssertEqual(next.runtime.accepted?.weightKg, 75)
            XCTAssertEqual(next.runtime.accepted?.values[.weightKg], .clear)
            XCTAssertFalse(next.runtime.accepted!.algorithmChoices.banisterEffortEnabled)
            XCTAssertEqual(try next.intents().count, 2)
            try await next.close()
        }
    }

    func testDOBAndConfigFreezeAtCapturedBirthdayTimezoneWithExplicitConsentOnly() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
            var cal = Calendar.current; cal.timeZone = zone
            let dob = try XCTUnwrap(cal.date(from: DateComponents(year: 1996, month: 9, day: 18, hour: 0)))
            let before = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 23, minute: 59)))
            let after = before.addingTimeInterval(120)
            let patch: [ScoringPreferenceIntent.Patch] = [.init(key: .dateOfBirth, value: .number(dob.timeIntervalSince1970)),
                .init(key: .ageExplicit, value: .boolean(true)), .init(key: .sex, value: .text("female")),
                .init(key: .hrZoneThresholds, value: .integers([90, 110, 130, 150, 170])),
                .init(key: .stepsManualCoefficient, value: .number(0.75))]
            let first = f.runtime.complete(f.action(patch, date: before, zone: zone.identifier,
                consent: .init(journalEnabled: false, cycleEnabled: true)))
            let second = f.runtime.complete(f.action([.init(key: .weightKg, value: .number(71))], date: after,
                zone: zone.identifier, consent: .init(journalEnabled: true, cycleEnabled: false)))
            _ = try await first.acceptance(); _ = try await second.acceptance()
            let intents = try f.intents()
            XCTAssertEqual(intents.map(\.effectiveDay), ["2026-09-17", "2026-09-18"])
            for (index, intent) in intents.enumerated() {
                let profile = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.profile!.payload) as? [String: Any])
                let config = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.config!.payload) as? [String: Any])
                XCTAssertEqual(profile["age"] as? Int, index == 0 ? 29 : 30)
                XCTAssertEqual(config["customHRZoneLowerBounds"] as? [Int], [90, 110, 130, 150, 170])
                XCTAssertEqual(config["stepsManualCoefficient"] as? Double, 0.75)
                XCTAssertEqual(config["journalContextEnabled"] as? Bool, index == 1)
                XCTAssertEqual(config["cycleAwarenessEnabled"] as? Bool, index == 0)
            }
            XCTAssertEqual(f.runtime.accepted?.dateOfBirth, dob)
            XCTAssertEqual(f.defaults.integer(forKey: "profile.age"), ProfileStore.years(from: dob, to: Date()))
        }
    }

    func testInvalidPatchCannotChangeAcceptedStateOrAdmitIntent() async throws {
        try await fixture { f in
            try await f.runtime.hydrate()
            for patch: [ScoringPreferenceIntent.Patch] in [[], [.init(key: .weightKg, value: .number(.nan))],
                [.init(key: .effortMethod, value: .text("invented"))], [.init(key: .weightKg, value: .number(72)), .init(key: .weightKg, value: .number(73))]] {
                let ticket = f.runtime.complete(f.action(patch))
                XCTAssertEqual(ticket.state, .held(.invalid))
            }
            XCTAssertEqual(f.runtime.accepted?.position, .initial)
            XCTAssertEqual(try f.intents().count, 0)
        }
    }
}
