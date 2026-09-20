import Foundation
import GRDB
import NoopPush
import StrandAnalytics
import WhoopStore
import XCTest
@testable import Strand

@MainActor
final class ServerScoreContextAppTests: XCTestCase {
    private let day = "2026-09-15"
    private let fields: Set<ServerScoreMetric> = [.cyclePhase, .circadianPhase, .circadianOffset, .illnessScore, .illnessDistance]
    private let emittedDistance = IllnessDistance.Result(distance: 7.25, deviatingFeatures: 2,
                                                        fires: true, usedDiagonalFallback: false)

    private actor InputOpenGate {
        let store: WhoopStore
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        init(store: WhoopStore, entered: XCTestExpectation) {
            self.store = store; self.entered = entered
        }

        func open() async -> WhoopStore {
            if !released {
                await withCheckedContinuation { continuation = $0; entered.fulfill() }
            }
            return store
        }

        func resume() {
            released = true
            continuation?.resume(); continuation = nil
        }

        func close() throws { try store.registryWriter.close() }
    }

    @MainActor private final class Fixture {
        let root: URL
        let context: AccountSessionContext
        let layout: AccountStorageLayout
        let inputGate: InputOpenGate?
        var model: AppModel?
        var pendingReads: [Task<Void, Never>] = []
        var notificationMessages: [String] = []
        init(inputGate: InputOpenGate? = nil, recordNotifications: Bool = false) throws {
            self.inputGate = inputGate
            root = FileManager.default.temporaryDirectory.appendingPathComponent("context-app-" + UUID().uuidString)
            let scope = try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid", userID: UUID().uuidString)
            context = .init(scope: scope, generation: UUID())
            layout = .init(baseDirectory: root, scope: scope)
            let captured = context
            // This suite exercises publication races, not another suite's history cooldown or host heat.
            let budget = ResourceBudget(cooldown: 0, thermal: { 0 }, lowPower: { false })
            if let inputGate {
                model = AppModel(storageLayout: layout, context: context, captureAllowed: false,
                    openStore: { await inputGate.open() },
                    postIllnessNotification: { [weak self] in self?.notificationMessages.append($0) },
                    scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: captured, isCurrent: { $0 == captured }),
                    nativePreferenceCurrent: { $0 == captured },
                    resourceBudget: budget,
                    isCurrent: { $0 == captured })
            } else if recordNotifications {
                model = AppModel(storageLayout: layout, context: context, captureAllowed: false,
                    postIllnessNotification: { [weak self] in self?.notificationMessages.append($0) },
                    scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: captured, isCurrent: { $0 == captured }),
                    nativePreferenceCurrent: { $0 == captured },
                    resourceBudget: budget,
                    isCurrent: { $0 == captured })
            } else {
                model = AppModel(storageLayout: layout, context: context, captureAllowed: false,
                    scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: captured, isCurrent: { $0 == captured }),
                    nativePreferenceCurrent: { $0 == captured }, resourceBudget: budget,
                    isCurrent: { $0 == captured })
            }
        }
        func close() async throws {
            let generic = model?.shutdownForAccountChange()
            await inputGate?.resume()
            for read in pendingReads { await read.value }
            pendingReads = []
            let bleDrained = await model?.ble.drainCaptureAfterAccountChange() ?? true
            let genericDrained = await generic?.drain() ?? true
            XCTAssertTrue(bleDrained); XCTAssertTrue(genericDrained)
            try await model?.scoringInputs?.waitForRetirement()
            model = nil
            try await inputGate?.close()
            UserDefaults(suiteName: layout.preferencesSuite)?.removePersistentDomain(forName: layout.preferencesSuite)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
    }

    private func fixture(inputGate: InputOpenGate? = nil, recordNotifications: Bool = false) throws -> Fixture {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting, "requires hermetic app construction")
        let f = try Fixture(inputGate: inputGate, recordNotifications: recordNotifications)
        addTeardownBlock { try await f.close() }
        return f
    }

    private func suspendedFixture() async throws -> (Fixture, InputOpenGate, XCTestExpectation) {
        let store = try await WhoopStore.inMemory()
        let entered = expectation(description: "actual Repository input reader suspended at store open")
        let gate = InputOpenGate(store: store, entered: entered)
        return (try fixture(inputGate: gate), gate, entered)
    }

    private func localDays() -> [DailyMetric] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let end = Date(timeIntervalSince1970: 1_789_430_400)
        return (0..<40).map { index in
            let raised = index >= 38
            return DailyMetric(day: formatter.string(from: end.addingTimeInterval(Double(index - 39) * 86_400)),
                totalSleepMin: 480, efficiency: 90, deepMin: 60, remMin: 80, lightMin: 340,
                disturbances: nil, restingHr: raised ? 100 : 60, avgHrv: raised ? 10 : 60,
                recovery: nil, strain: nil, exerciseCount: nil,
                skinTempDevC: raised ? 1 : Double(index % 2) * 0.01,
                respRateBpm: raised ? 25 : 16)
        }
    }

    private func view(_ f: Fixture, active: Set<ServerScoreMetric>? = nil,
                      status: String = "partial", complete: Bool = true,
                      generation: UUID? = nil, user: String? = nil,
                      distance: IllnessDistance.Result? = nil, nullDistance: Bool = false,
                      snapshotCapabilities: Set<ServerScoreMetric>? = nil, currentDay: String? = nil,
                      hasSnapshot: Bool = true, configured: Bool = true,
                      authenticated: Bool = true) throws -> ServerScoreViewState {
        let details: [String: Any] = ["contextPolicy": "as-of-context-v1",
            "cycle": ["phase": "luteal", "confidence": "solid", "shiftMarkers": [], "awarenessOnly": true,
                "baselinePolicy": "pre_observation_absolute_temperature", "note": "synthetic cycle note"],
            "circadian": ["confidence": "wide", "acrophaseHours": 16.5, "observedDays": 7,
                "habitualWakeHour": 7.5, "measuredTemperatureMinimum": false, "note": "synthetic clock note"],
            "illness": ["level": "raised", "signalCount": 2, "suppressedBy": [], "distanceFires": true,
                "distanceIsAlertGate": false, "wellnessOnly": true, "firedSignals": [], "copy": "synthetic illness copy"]]
        var object: [String: Any] = ["schemaVersion": 2, "userId": user ?? f.context.scope.userID,
            "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "day": day, "timezone": "UTC",
            "algorithmVersion": "fixture", "inputRevision": 1, "resultRevision": 2,
            "computedAt": "2026-09-15T12:00:00Z", "status": status, "coverage": [:], "sleep": [],
            "capabilities": (snapshotCapabilities ?? fields).map(\.rawValue), "details": complete ? details : [:],
            "metrics": status == "no_data" ? [:] : [
                "circadian_phase_hour": ["value": 4.5, "unit": "local_hour", "method": "CircadianEngine_observed_hourly_hr_proxy"],
                "circadian_offset_min": ["value": -45, "unit": "min", "method": "CircadianEngine"],
                "illness_score": ["value": 32, "unit": "score_0_100", "method": "IllnessSignalEngine"]]]
        // Existing callers remain legacy/extension-absent unless this explicit synthetic result is supplied.
        if let distance {
            if complete {
                var extended = details
                var illness = try XCTUnwrap(details["illness"] as? [String: Any])
                illness["distanceDeviatingFeatures"] = distance.deviatingFeatures
                illness["distanceUsedDiagonalFallback"] = distance.usedDiagonalFallback
                illness["distanceFires"] = distance.fires
                extended["illness"] = illness; object["details"] = extended
            }
            if status != "no_data" {
                var metrics = try XCTUnwrap(object["metrics"] as? [String: Any])
                let value: Any = nullDistance ? NSNull() : distance.distance
                metrics["illness_distance"] = ["value": value, "unit": "dimensionless",
                    "method": "IllnessDistance_identity_correlation", "status": "available"]
                object["metrics"] = metrics
            }
        }
        let snapshot = try XCTUnwrap(ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day).snapshot)
        return .init(generation: generation ?? f.context.generation, revision: 1, currentDay: currentDay ?? day, timezone: "UTC",
            configured: configured, authenticated: authenticated, capabilities: fields, activated: active ?? fields,
            days: hasSnapshot ? [day: .init(snapshot: snapshot, phase: .offline, fetchedAt: nil, cached: true,
                pending: false, requestedInputRevision: nil, archiveStatus: nil)] : [:])
    }

    private func allowContext(_ model: AppModel) async throws {
        try await model.prepareScoringPreferences()
        let consent = try XCTUnwrap(model.scoringContextConsent)
        await consent.load()
        await consent.setEnabled(true, purpose: .cycle)
        await consent.setEnabled(true, purpose: .journal)
        XCTAssertTrue(consent.enabled(.cycle)); XCTAssertTrue(consent.enabled(.journal))
        model.behavior.illnessWatch = true
    }

    private func seedLocal(_ model: AppModel) {
        model.cyclePhase = .init(phase: .follicular, confidence: .building, cycleDayLow: nil, cycleDayHigh: nil,
            cycleLengthDays: nil, nextPeriodWindow: nil, shiftMarkers: [], note: "synthetic local cycle")
        model.cycleCurve = [1, 2, 3]
        model.circadianPhase = .init(tempMinHour: 1, acrophaseHours: 12, offsetVsScheduleMinutes: 5,
            confidence: .wide, note: "synthetic local clock")
        model.illnessSignal = .init(score: 1, level: .quiet, firedSignals: [], suppressedBy: [], signalCount: 0,
            copy: "synthetic local illness")
        model.illnessDistance = .init(distance: 8, deviatingFeatures: 3, fires: true, usedDiagonalFallback: false)
        model.healthAlert = .init(message: .raised, firedSignals: ["synthetic local alert"])
    }

    func testOwnedCachedResultsSurviveRefreshWithoutLocalHistoryOrNewAlerts() async throws {
        let f = try fixture(), model = try XCTUnwrap(f.model)
        try await allowContext(model); seedLocal(model)
        model.applyServerScorePresentation(try view(f))
        await model.refreshV5Signals(); model.reevaluateIllness()
        XCTAssertEqual(model.cyclePhase?.phase, .luteal)
        XCTAssertEqual(model.cyclePhase?.note, "synthetic cycle note")
        XCTAssertEqual(model.circadianPhase?.tempMinHour, 4.5)
        XCTAssertEqual(model.circadianPhase?.offsetVsScheduleMinutes, -45)
        XCTAssertEqual(model.illnessSignal?.score, 32)
        XCTAssertEqual(model.illnessSignal?.firedSignals, [], "empty emitted labels stay empty despite two signals")
        XCTAssertNil(model.healthAlert, "cached raised result is not a new notification or semantic alert")
        XCTAssertNil(model.illnessDistance, "missing feature evidence is not manufactured from its scalar")
        XCTAssertTrue(model.cycleCurve.isEmpty, "old local curve must not sit beside a server phase")
    }

    func testOwnedNoDataAndIncompleteRevisionClearLocalValuesWithoutFallback() async throws {
        let f = try fixture(), model = try XCTUnwrap(f.model)
        try await allowContext(model)
        for state in [try view(f, status: "no_data"), try view(f, complete: false)] {
            seedLocal(model); model.applyServerScorePresentation(state)
            await model.refreshV5Signals(); model.reevaluateIllness()
            XCTAssertNil(model.cyclePhase); XCTAssertNil(model.circadianPhase)
            XCTAssertNil(model.illnessSignal); XCTAssertNil(model.illnessDistance)
            XCTAssertNil(model.healthAlert); XCTAssertTrue(model.cycleCurve.isEmpty)
        }
    }

    func testPartialCircadianOwnershipNeverBlendsValuesAndLeavesUnownedFamiliesAlone() throws {
        let f = try fixture(), model = try XCTUnwrap(f.model)
        seedLocal(model)
        model.applyServerScorePresentation(try view(f, active: [.circadianPhase]))
        XCTAssertNil(model.circadianPhase)
        XCTAssertEqual(model.cyclePhase?.note, "synthetic local cycle")
        XCTAssertEqual(model.illnessSignal?.score, 1)
        XCTAssertEqual(model.illnessDistance?.distance, 8)
        model.applyServerScorePresentation(try view(f, active: [.circadianPhase, .circadianOffset]))
        XCTAssertEqual(model.circadianPhase?.tempMinHour, 4.5)
        model.applyServerScorePresentation(try view(f, active: []))
        XCTAssertNil(model.circadianPhase, "withdrawal clears the previously published server object immediately")
    }

    func testWrongGenerationOrAccountCannotPublishContextOrRepositoryState() throws {
        let f = try fixture(), model = try XCTUnwrap(f.model)
        seedLocal(model)
        model.applyServerScorePresentation(try view(f, generation: UUID()))
        model.applyServerScorePresentation(try view(f, user: UUID().uuidString.lowercased()))
        XCTAssertEqual(model.repo.serverPresentation, .empty)
        XCTAssertEqual(model.cyclePhase?.note, "synthetic local cycle")
        XCTAssertEqual(model.circadianPhase?.tempMinHour, 1)
    }

    func testConsentTransitionClearsSensitiveOwnedResultsBeforeStorageAwait() async throws {
        let f = try fixture(), model = try XCTUnwrap(f.model)
        try await allowContext(model)
        model.applyServerScorePresentation(try view(f))
        XCTAssertNotNil(model.cyclePhase); XCTAssertNotNil(model.illnessSignal)
        let consent = try XCTUnwrap(model.scoringContextConsent), original = consent.willChange
        var pauses = 0
        consent.willChange = {
            original?(); pauses += 1
            XCTAssertTrue(consent.saving)
            XCTAssertNil(model.cyclePhase); XCTAssertNil(model.illnessSignal)
        }
        await consent.setEnabled(false, purpose: .cycle)
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertEqual(pauses, 2)
        await model.refreshV5Signals(); model.reevaluateIllness()
        XCTAssertNil(model.cyclePhase); XCTAssertNil(model.illnessSignal)
        consent.willChange = original
    }

    func testCompletedConsentGrantRepublishesCachedContextWithoutAnotherScoreRefresh() async throws {
        let f = try fixture(), model = try XCTUnwrap(f.model)
        try await model.prepareScoringPreferences()
        let consent = try XCTUnwrap(model.scoringContextConsent)
        await consent.load()
        model.behavior.illnessWatch = true
        model.applyServerScorePresentation(try view(f))
        XCTAssertNil(model.cyclePhase); XCTAssertNil(model.illnessSignal)
        await consent.setEnabled(true, purpose: .cycle)
        XCTAssertEqual(model.cyclePhase?.phase, .luteal)
        await consent.setEnabled(true, purpose: .journal)
        XCTAssertEqual(model.cyclePhase?.phase, .luteal)
        XCTAssertEqual(model.illnessSignal?.score, 32)
        XCTAssertNil(model.healthAlert)
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertNil(model.illnessSignal)
        XCTAssertEqual(model.cyclePhase?.phase, .luteal, "the unrelated enabled purpose must recover after the pause")
    }

    func testRetirementClearsContextAndRejectsLaterPublicationAndRefresh() async throws {
        let f = try fixture(), model = try XCTUnwrap(f.model)
        seedLocal(model)
        model.shutdownForAccountChange()
        model.applyServerScorePresentation(try view(f))
        await model.refreshV5Signals(); model.reevaluateIllness()
        XCTAssertNil(model.cyclePhase); XCTAssertNil(model.circadianPhase)
        XCTAssertNil(model.illnessSignal); XCTAssertNil(model.illnessDistance)
        XCTAssertNil(model.healthAlert); XCTAssertTrue(model.cycleCurve.isEmpty)
    }

    func testIllnessOptOutDuringActualInputReadCannotRepublishOrNotify() async throws {
        let (f, gate, entered) = try await suspendedFixture()
        let model = try XCTUnwrap(f.model)
        model.repo.days = localDays(); model.behavior.illnessWatch = true
        let read = try XCTUnwrap(model.reevaluateIllness())
        f.pendingReads.append(read)
        await fulfillment(of: [entered], timeout: 2)

        model.behavior.illnessWatch = false
        XCTAssertNil(model.reevaluateIllness())
        await gate.resume(); await read.value
        XCTAssertNil(model.illnessSignal); XCTAssertNil(model.illnessDistance)
        XCTAssertNil(model.healthAlert); XCTAssertTrue(f.notificationMessages.isEmpty)

        // Positive control: the same real inputs and engine can publish and notify once enabled.
        model.behavior.illnessWatch = true
        let current = try XCTUnwrap(model.reevaluateIllness())
        await current.value
        XCTAssertEqual(model.illnessSignal?.level, .raised)
        XCTAssertNotNil(model.illnessDistance); XCTAssertNotNil(model.healthAlert)
        XCTAssertEqual(f.notificationMessages.count, 1)
    }

    func testCycleOptOutDuringActualInputReadCannotRepublishCurve() async throws {
        let (f, gate, entered) = try await suspendedFixture()
        let model = try XCTUnwrap(f.model)
        let previous = model.cycleAwarenessEnabled
        defer { model.cycleAwarenessEnabled = previous }
        model.repo.days = localDays(); model.cycleAwarenessEnabled = true
        // Isolate the cycle read; a second circadian read must not hold the opt-out clear path.
        model.applyServerScorePresentation(try view(f, active: [.circadianPhase, .circadianOffset], status: "no_data"))
        let read = Task { await model.refreshV5Signals() }
        f.pendingReads.append(read)
        await fulfillment(of: [entered], timeout: 2)

        model.cycleAwarenessEnabled = false
        await model.refreshV5Signals()
        await gate.resume(); await read.value
        XCTAssertNil(model.cyclePhase); XCTAssertTrue(model.cycleCurve.isEmpty)

        model.cycleAwarenessEnabled = true
        await model.refreshV5Signals()
        XCTAssertNotNil(model.cyclePhase)
        XCTAssertFalse(model.cycleCurve.isEmpty, "positive control uses the same actual inputs")
    }

    func testIllnessOwnershipChangesDuringActualReadKeepOutputsIndependent() async throws {
        for active: Set<ServerScoreMetric> in [[.illnessScore], [.illnessDistance], [.illnessScore, .illnessDistance]] {
            let (f, gate, entered) = try await suspendedFixture()
            let model = try XCTUnwrap(f.model)
            model.repo.days = localDays(); model.behavior.illnessWatch = true
            let read = try XCTUnwrap(model.reevaluateIllness())
            f.pendingReads.append(read)
            await fulfillment(of: [entered], timeout: 2)

            model.applyServerScorePresentation(try view(f, active: active, status: "no_data"))
            await gate.resume(); await read.value
            if active.contains(.illnessScore) {
                XCTAssertNil(model.illnessSignal); XCTAssertNil(model.healthAlert)
                XCTAssertTrue(f.notificationMessages.isEmpty, "owned-null score cannot revive a local alert")
            } else {
                XCTAssertEqual(model.illnessSignal?.level, .raised)
                XCTAssertEqual(f.notificationMessages.count, 1, "unowned score retains its local producer")
            }
            XCTAssertEqual(model.illnessDistance == nil, active.contains(.illnessDistance))
        }
    }

    func testCycleOwnedNullDuringActualInputReadSuppressesOldLocalResult() async throws {
        let (f, gate, entered) = try await suspendedFixture()
        let model = try XCTUnwrap(f.model)
        let previous = model.cycleAwarenessEnabled
        defer { model.cycleAwarenessEnabled = previous }
        model.repo.days = localDays(); model.cycleAwarenessEnabled = true
        let read = Task { await model.refreshV5Signals() }
        f.pendingReads.append(read)
        await fulfillment(of: [entered], timeout: 2)

        model.applyServerScorePresentation(try view(f, active: [.cyclePhase], status: "no_data"))
        await gate.resume(); await read.value
        XCTAssertNil(model.cyclePhase); XCTAssertTrue(model.cycleCurve.isEmpty)
        XCTAssertTrue(f.notificationMessages.isEmpty)
    }

    func testRetirementDuringActualIllnessReadCannotPublishIntoEitherAccount() async throws {
        let (f, gate, entered) = try await suspendedFixture()
        let model = try XCTUnwrap(f.model)
        model.repo.days = localDays(); model.behavior.illnessWatch = true
        let read = try XCTUnwrap(model.reevaluateIllness())
        f.pendingReads.append(read)
        await fulfillment(of: [entered], timeout: 2)

        model.shutdownForAccountChange()
        let successor = try fixture(), next = try XCTUnwrap(successor.model)
        await gate.resume(); await read.value
        for candidate in [model, next] {
            XCTAssertNil(candidate.illnessSignal); XCTAssertNil(candidate.illnessDistance)
            XCTAssertNil(candidate.healthAlert)
        }
        XCTAssertTrue(f.notificationMessages.isEmpty)
    }

    func testRetirementDuringActualCycleReadCannotRepublishPhaseOrCurve() async throws {
        let (f, gate, entered) = try await suspendedFixture()
        let model = try XCTUnwrap(f.model)
        let previous = model.cycleAwarenessEnabled
        defer { model.cycleAwarenessEnabled = previous }
        model.repo.days = localDays(); model.cycleAwarenessEnabled = true
        let read = Task { await model.refreshV5Signals() }
        f.pendingReads.append(read)
        await fulfillment(of: [entered], timeout: 2)

        model.shutdownForAccountChange()
        let successor = try fixture(), next = try XCTUnwrap(successor.model)
        await gate.resume(); await read.value
        for candidate in [model, next] {
            XCTAssertNil(candidate.cyclePhase); XCTAssertTrue(candidate.cycleCurve.isEmpty)
            XCTAssertNil(candidate.circadianPhase)
        }
        XCTAssertTrue(f.notificationMessages.isEmpty)
    }

    private func assertDistance(_ actual: IllnessDistance.Result?, _ expected: IllnessDistance.Result,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual?.distance, expected.distance, file: file, line: line)
        XCTAssertEqual(actual?.deviatingFeatures, expected.deviatingFeatures, file: file, line: line)
        XCTAssertEqual(actual?.fires, expected.fires, file: file, line: line)
        XCTAssertEqual(actual?.usedDiagonalFallback, expected.usedDiagonalFallback, file: file, line: line)
    }

    func testCompleteCachedDistanceBindsWithoutLocalHistoryOrNewNotification() async throws {
        let f = try fixture(recordNotifications: true), model = try XCTUnwrap(f.model)
        try await allowContext(model); seedLocal(model)
        XCTAssertTrue(model.repo.days.isEmpty)
        let cached = try view(f, distance: emittedDistance)
        model.applyServerScorePresentation(cached)
        assertDistance(model.illnessDistance, emittedDistance)
        XCTAssertNil(model.reevaluateIllness(), "both owned outputs must skip the local input read")
        await model.refreshV5Signals()
        assertDistance(model.illnessDistance, emittedDistance)
        XCTAssertEqual(model.illnessSignal?.score, 32)
        XCTAssertNil(model.healthAlert)
        XCTAssertTrue(f.notificationMessages.isEmpty, "cached distance fires is not a notification event")
    }

    func testDistanceReplacementClearsNullLegacyWithdrawalAndMissingDayWithoutFallback() async throws {
        let f = try fixture(recordNotifications: true), model = try XCTUnwrap(f.model)
        try await allowContext(model)
        let cached = try view(f, distance: emittedDistance)
        let unavailable = [
            try view(f, status: "no_data", distance: emittedDistance),
            try view(f, complete: false, distance: emittedDistance),
            try view(f, distance: emittedDistance, nullDistance: true),
            try view(f), // Legacy default remains extension-absent, not a fabricated complete result.
            try view(f, distance: emittedDistance, snapshotCapabilities: fields.subtracting([.illnessDistance])),
            try view(f, distance: emittedDistance, currentDay: "2026-09-16"),
            try view(f, distance: emittedDistance, hasSnapshot: false)
        ]
        for replacement in unavailable {
            model.applyServerScorePresentation(cached)
            assertDistance(model.illnessDistance, emittedDistance)
            model.applyServerScorePresentation(replacement)
            XCTAssertTrue(model.repo.serverPresentation.owns(.illnessDistance))
            XCTAssertNil(model.illnessDistance)
            XCTAssertNil(model.reevaluateIllness())
            await model.refreshV5Signals()
            XCTAssertNil(model.illnessDistance)
            XCTAssertNil(model.healthAlert)
        }
        XCTAssertTrue(f.notificationMessages.isEmpty)
    }

    func testDistanceOwnershipLossClearsPublishedResultAndLeavesUnownedLocalSeedAlone() async throws {
        let f = try fixture(recordNotifications: true), model = try XCTUnwrap(f.model)
        try await allowContext(model)
        let cached = try view(f, distance: emittedDistance)
        for replacement in [
            try view(f, active: fields.subtracting([.illnessDistance]), distance: emittedDistance),
            try view(f, distance: emittedDistance, configured: false),
            try view(f, distance: emittedDistance, authenticated: false)
        ] {
            model.applyServerScorePresentation(cached)
            assertDistance(model.illnessDistance, emittedDistance)
            model.applyServerScorePresentation(replacement)
            XCTAssertFalse(model.repo.serverPresentation.owns(.illnessDistance))
            XCTAssertNil(model.illnessDistance, "withdrawal cannot retain the old server result")
        }
        seedLocal(model)
        model.applyServerScorePresentation(try view(f, active: [], distance: emittedDistance))
        XCTAssertEqual(model.illnessDistance?.distance, 8, "unowned local output is not overwritten by a populated wire field")
        XCTAssertTrue(f.notificationMessages.isEmpty)
    }

    func testWrongAccountOrGenerationCannotReplaceBoundDistance() async throws {
        let f = try fixture(recordNotifications: true), model = try XCTUnwrap(f.model)
        try await allowContext(model)
        let cached = try view(f, distance: emittedDistance)
        model.applyServerScorePresentation(cached)
        assertDistance(model.illnessDistance, emittedDistance)
        let foreign = IllnessDistance.Result(distance: 19, deviatingFeatures: 3, fires: true, usedDiagonalFallback: false)
        for rejected in [try view(f, generation: UUID(), distance: foreign),
                         try view(f, user: UUID().uuidString.lowercased(), distance: foreign)] {
            model.applyServerScorePresentation(rejected)
            XCTAssertEqual(model.repo.serverPresentation, cached)
            assertDistance(model.illnessDistance, emittedDistance)
        }
        XCTAssertNil(model.healthAlert)
        XCTAssertTrue(f.notificationMessages.isEmpty)
    }

    func testDistanceConsentSavingRevocationAndCompletedGrantRespectCachedPublication() async throws {
        let f = try fixture(recordNotifications: true), model = try XCTUnwrap(f.model)
        try await model.prepareScoringPreferences()
        let consent = try XCTUnwrap(model.scoringContextConsent)
        await consent.load()
        model.behavior.illnessWatch = true
        let cached = try view(f, distance: emittedDistance)
        model.applyServerScorePresentation(cached)
        XCTAssertNil(model.illnessDistance, "an ungranted journal purpose cannot expose cached distance")
        let originalWill = consent.willChange, originalDid = consent.didChange
        defer { consent.willChange = originalWill; consent.didChange = originalDid }
        var paused = 0, completed = 0
        consent.willChange = {
            originalWill?(); paused += 1
            XCTAssertTrue(consent.saving)
            XCTAssertNil(model.illnessDistance, "clear synchronously before the consent storage await")
            model.applyServerScorePresentation(cached)
            XCTAssertNil(model.illnessDistance, "a score publication during saving cannot reopen presentation")
        }
        consent.didChange = {
            originalDid?(); completed += 1
            XCTAssertFalse(consent.saving)
        }
        await consent.setEnabled(true, purpose: .journal)
        assertDistance(model.illnessDistance, emittedDistance)
        XCTAssertEqual(model.repo.serverPresentation, cached)
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertNil(model.illnessDistance)
        XCTAssertNil(model.illnessSignal)
        await consent.setEnabled(true, purpose: .journal)
        assertDistance(model.illnessDistance, emittedDistance)
        XCTAssertEqual(paused, 3); XCTAssertEqual(completed, 3)

        model.behavior.illnessWatch = false
        XCTAssertNil(model.reevaluateIllness())
        XCTAssertNil(model.illnessDistance)
        model.behavior.illnessWatch = true
        XCTAssertNil(model.reevaluateIllness())
        assertDistance(model.illnessDistance, emittedDistance)
        XCTAssertNil(model.healthAlert)
        XCTAssertTrue(f.notificationMessages.isEmpty)
    }

    func testFailedJournalConsentChangeKeepsDistanceHiddenUntilExplicitRetry() async throws {
        let f = try fixture(recordNotifications: true), model = try XCTUnwrap(f.model)
        try await allowContext(model)
        let cached = try view(f, distance: emittedDistance)
        model.applyServerScorePresentation(cached)
        assertDistance(model.illnessDistance, emittedDistance)
        let consent = try XCTUnwrap(model.scoringContextConsent), original = consent.configuration
        defer { consent.configuration = original }
        consent.configuration = { _, _, _ in throw ScoringInputJournal.Failure.invalidInput }
        await consent.setEnabled(false, purpose: .journal)
        XCTAssertNotNil(consent.error)
        XCTAssertFalse(consent.saving); XCTAssertFalse(consent.enabled(.journal))
        XCTAssertNil(model.illnessDistance)
        model.applyServerScorePresentation(cached)
        XCTAssertNil(model.illnessDistance, "retained cached evidence cannot bypass a failed consent transition")
        consent.configuration = original
        await consent.setEnabled(true, purpose: .journal)
        XCTAssertNil(consent.error)
        assertDistance(model.illnessDistance, emittedDistance)
        XCTAssertNil(model.healthAlert)
        XCTAssertTrue(f.notificationMessages.isEmpty)
    }

    func testCompleteDistanceDuringActualInputReadKeepsOwnershipAndNotificationsIndependent() async throws {
        for active: Set<ServerScoreMetric> in [[.illnessScore], [.illnessDistance], [.illnessScore, .illnessDistance]] {
            let (f, gate, entered) = try await suspendedFixture()
            let model = try XCTUnwrap(f.model)
            try await allowContext(model)
            model.repo.days = localDays()
            let read = try XCTUnwrap(model.reevaluateIllness())
            f.pendingReads.append(read)
            await fulfillment(of: [entered], timeout: 2)

            model.applyServerScorePresentation(try view(f, active: active, distance: emittedDistance))
            if active.contains(.illnessDistance) { assertDistance(model.illnessDistance, emittedDistance) }
            else { XCTAssertNil(model.illnessDistance, "the unowned local producer is still suspended") }
            XCTAssertTrue(f.notificationMessages.isEmpty)
            await gate.resume(); await read.value
            if active.contains(.illnessDistance) {
                assertDistance(model.illnessDistance, emittedDistance)
            } else {
                XCTAssertNotNil(model.illnessDistance, "unowned distance retains its independent local producer")
                XCTAssertNotEqual(model.illnessDistance?.distance, emittedDistance.distance)
            }
            if active.contains(.illnessScore) {
                XCTAssertEqual(model.illnessSignal?.score, 32)
                XCTAssertNil(model.healthAlert)
                XCTAssertTrue(f.notificationMessages.isEmpty)
            } else {
                XCTAssertEqual(model.illnessSignal?.level, .raised)
                XCTAssertNotNil(model.healthAlert)
                XCTAssertEqual(f.notificationMessages.count, 1, "only the unowned local score may notify")
            }
        }
    }

    func testConsentRevocationOrOptOutDuringActualReadCannotRestoreBoundDistance() async throws {
        for localOptOut in [false, true] {
            let (f, gate, entered) = try await suspendedFixture()
            let model = try XCTUnwrap(f.model)
            try await allowContext(model)
            model.repo.days = localDays()
            let read = try XCTUnwrap(model.reevaluateIllness())
            f.pendingReads.append(read)
            await fulfillment(of: [entered], timeout: 2)
            model.applyServerScorePresentation(try view(f, distance: emittedDistance))
            assertDistance(model.illnessDistance, emittedDistance)
            if localOptOut {
                model.behavior.illnessWatch = false
                XCTAssertNil(model.reevaluateIllness())
            } else {
                await model.scoringContextConsent?.setEnabled(false, purpose: .journal)
            }
            XCTAssertNil(model.illnessDistance)
            await gate.resume(); await read.value
            XCTAssertNil(model.illnessDistance); XCTAssertNil(model.illnessSignal)
            XCTAssertNil(model.healthAlert)
            XCTAssertTrue(f.notificationMessages.isEmpty)
        }
    }

    func testRetirementDuringActualReadClearsBoundDistanceAndRejectsLatePublication() async throws {
        let (f, gate, entered) = try await suspendedFixture()
        let model = try XCTUnwrap(f.model)
        try await allowContext(model)
        model.repo.days = localDays()
        let read = try XCTUnwrap(model.reevaluateIllness())
        f.pendingReads.append(read)
        await fulfillment(of: [entered], timeout: 2)
        let cached = try view(f, distance: emittedDistance)
        model.applyServerScorePresentation(cached)
        assertDistance(model.illnessDistance, emittedDistance)
        model.shutdownForAccountChange()
        XCTAssertNil(model.illnessDistance)
        let successor = try fixture(recordNotifications: true), next = try XCTUnwrap(successor.model)
        model.applyServerScorePresentation(cached)
        next.applyServerScorePresentation(cached)
        await gate.resume(); await read.value
        for candidate in [model, next] {
            XCTAssertNil(candidate.illnessDistance); XCTAssertNil(candidate.illnessSignal)
            XCTAssertNil(candidate.healthAlert)
        }
        XCTAssertEqual(next.repo.serverPresentation, .empty)
        XCTAssertTrue(f.notificationMessages.isEmpty); XCTAssertTrue(successor.notificationMessages.isEmpty)
    }
}
