import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testAccountSwitchHidesSavedHealthDataAndRejectsOldPublisher() throws {
        let suite = "widget-owner-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        WidgetSnapshot.activateAccount(namespace: "account-a", defaults: defaults)
        var a = renderedSnapshot()
        a.accountNamespace = "account-a"
        a.save(to: defaults)
        XCTAssertEqual(WidgetSnapshot.load(from: defaults)?.recovery, 72)
        WidgetSnapshot.activateAccount(namespace: "account-b", defaults: defaults)
        XCTAssertNil(WidgetSnapshot.load(from: defaults))
        a.save(to: defaults)
        XCTAssertNil(WidgetSnapshot.load(from: defaults), "A late A publisher cannot replace B's widget")
        var b = a
        b.accountNamespace = "account-b"
        b.recovery = 33
        b.save(to: defaults)
        XCTAssertEqual(WidgetSnapshot.load(from: defaults)?.recovery, 33)
        WidgetSnapshot.activateAccount(namespace: nil, defaults: defaults)
        b.save(to: defaults)
        XCTAssertNil(WidgetSnapshot.load(from: defaults))
    }

    func testLegacyWidgetSnapshotIsNotAdoptedByFirstSignedInAccount() throws {
        let suite = "widget-legacy-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        renderedSnapshot().save(to: defaults)
        XCTAssertNotNil(WidgetSnapshot.load(from: defaults))
        WidgetSnapshot.activateAccount(namespace: "account-a", defaults: defaults)
        XCTAssertNil(WidgetSnapshot.load(from: defaults))
    }

    func testAltStoreProvisionedGroupWinsOverBuildTimeIdentifier() {
        let configured = "group.com.noopapp.noop.staging"
        let remapped = configured + ".TEAM123456"

        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": configured,
                "ALTAppGroups": [remapped]
            ]),
            remapped
        )
    }

    func testXcodeBuildFallsBackToConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop"
            ]),
            "group.example.noop"
        )
    }

    func testUnrelatedAltStoreGroupsDoNotOverrideConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop",
                "ALTAppGroups": [
                    "group.example.first",
                    "group.example.second"
                ]
            ]),
            "group.example.noop"
        )
    }

    func testSingleProvisionedGroupIsUsableWithoutConfiguredIdentifier() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "ALTAppGroups": ["group.example.noop.TEAM123456"]
            ]),
            "group.example.noop.TEAM123456"
        )
    }

    func testRuntimeUnavailableSnapshotContainsNoDemoValues() {
        let snapshot = WidgetSnapshot.unavailable

        XCTAssertNil(snapshot.recovery)
        XCTAssertNil(snapshot.bpm)
        XCTAssertNil(snapshot.batteryPct)
        XCTAssertFalse(snapshot.bonded)
    }

    private func renderedSnapshot(updated: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> WidgetSnapshot {
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: updated,
                       effort: 38, rest: 81, hrv: 64, restingHr: 52,
                       effortDisplay: "38", effortWhoop: false)
    }

    func testRenderedContentFirstPublishAlwaysChanges() {
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: nil, to: renderedSnapshot()))
    }

    func testRenderedContentIgnoresTimestampOnlyChange() {
        let previous = renderedSnapshot()
        let next = renderedSnapshot(updated: previous.updated.addingTimeInterval(900))

        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testRenderedContentDetectsLiveFieldChange() {
        let previous = renderedSnapshot()
        var next = previous
        next.bpm = 59

        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testRenderedContentDetectsScoreFieldChange() {
        let previous = renderedSnapshot()
        var next = previous
        next.rest = 82

        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testLiveUpdateReusesSnapshotWithinSameLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = renderedSnapshot(updated: Date(timeIntervalSince1970: 1_700_000_000))
        let oneHourLater = previous.updated.addingTimeInterval(3_600)

        XCTAssertFalse(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: previous, now: oneHourLater, calendar: calendar))
    }

    func testLiveUpdateRequiresFullBuildAfterLocalDayRollover() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = renderedSnapshot(updated: Date(timeIntervalSince1970: 1_700_000_000))
        let nextDay = previous.updated.addingTimeInterval(86_400)

        XCTAssertTrue(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: previous, now: nextDay, calendar: calendar))
        XCTAssertTrue(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: nil, now: nextDay, calendar: calendar))
    }
}

/// Exercises the exact orchestration used by WidgetSnapshot.publish, not WidgetKit delivery.
/// Every sink is in memory; these tests never resolve an App Group suite.
@MainActor
final class WidgetPublicationBoundaryTests: XCTestCase {
    private enum Rejected: Error { case revoked }

    @MainActor private final class Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        init(_ entered: XCTestExpectation) { self.entered = entered }

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func snapshot(recovery: Int = 72) -> WidgetSnapshot {
        WidgetSnapshot(recovery: recovery, bpm: 58, batteryPct: 84, bonded: true,
                       updated: Date(timeIntervalSince1970: 1_700_000_000),
                       effort: 38, rest: 81, hrv: 64, restingHr: 52,
                       effortDisplay: "38", effortWhoop: false, accountNamespace: "synthetic-owner")
    }

    func testValidPublicationPreparesThenValidatesChecksAndPassesExactSnapshot() async {
        let expected = snapshot()
        var events: [String] = []
        var delivered: [WidgetSnapshot] = []
        let result = await WidgetPublicationBoundary.publish(prepare: {
            events.append("prepare"); return expected
        }, validate: {
            events.append("validate"); return true
        }, checkBoundary: {
            events.append("boundary")
        }, isCurrent: {
            events.append("current"); return true
        }, save: {
            events.append("save"); delivered.append($0)
        })
        XCTAssertTrue(result)
        XCTAssertEqual(events, ["prepare", "validate", "boundary", "current", "save"])
        XCTAssertEqual(delivered, [expected])
    }

    func testRevocationWhileLastPayloadReadIsSuspendedDoesNotReachSave() async {
        let gate = Gate(expectation(description: "last payload read suspended"))
        let value = snapshot()
        var current = true, saves = 0, checks = 0
        let work = Task {
            await WidgetPublicationBoundary.publish(prepare: {
                await gate.wait(); return value
            }, validate: { current }, checkBoundary: {
                checks += 1
            }, isCurrent: { current }, save: { _ in saves += 1 })
        }
        addTeardownBlock { @MainActor in gate.release(); _ = await work.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        current = false
        gate.release()
        let result = await work.value
        XCTAssertFalse(result)
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(saves, 0)
    }

    func testSynchronousBoundaryRejectsStaleTrueAsyncValidation() async {
        let gate = Gate(expectation(description: "validation suspended"))
        let value = snapshot()
        var current = true, saves = 0, checks = 0
        let work = Task {
            await WidgetPublicationBoundary.publish(prepare: { value }, validate: {
                let admittedBeforeSuspension = current
                await gate.wait()
                return admittedBeforeSuspension
            }, checkBoundary: {
                checks += 1
                guard current else { throw Rejected.revoked }
            }, isCurrent: { true }, save: { _ in saves += 1 })
        }
        addTeardownBlock { @MainActor in gate.release(); _ = await work.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        current = false
        gate.release()
        let result = await work.value
        XCTAssertFalse(result)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(saves, 0)
    }

    func testOwnerChangeAfterPreparationRejectsSave() async {
        let capturedOwner = "owner-a"
        var activeOwner = capturedOwner, saves = 0
        let value = snapshot()
        let result = await WidgetPublicationBoundary.publish(prepare: {
            activeOwner = "owner-b"; return value
        }, validate: { true }, checkBoundary: {}, isCurrent: {
            activeOwner == capturedOwner
        }, save: { _ in saves += 1 })
        XCTAssertFalse(result)
        XCTAssertEqual(saves, 0)
    }

    func testPresentationRevisionChangeAfterValidationRejectsSave() async {
        let capturedRevision = 7
        var revision = capturedRevision, saves = 0
        let value = snapshot()
        let result = await WidgetPublicationBoundary.publish(prepare: { value }, validate: {
            revision += 1; return true
        }, checkBoundary: {}, isCurrent: {
            revision == capturedRevision
        }, save: { _ in saves += 1 })
        XCTAssertFalse(result)
        XCTAssertEqual(saves, 0)
    }

    func testFailedBoundaryDoesNotConsultCurrentOrInvokeSink() async {
        var currentChecks = 0, saves = 0
        let value = snapshot()
        let result = await WidgetPublicationBoundary.publish(prepare: { value }, validate: { true },
            checkBoundary: { throw Rejected.revoked }, isCurrent: {
                currentChecks += 1; return true
            }, save: { _ in saves += 1 })
        XCTAssertFalse(result)
        XCTAssertEqual(currentChecks, 0)
        XCTAssertEqual(saves, 0)
    }

    func testCurrentNoChangeCallbackRunsOnceAndReturnsTrue() async {
        let previous = snapshot()
        var callbacks = 0, changed = false
        let result = await WidgetPublicationBoundary.publish(prepare: { previous }, validate: { true },
            checkBoundary: {}, isCurrent: { true }, save: {
                callbacks += 1
                changed = WidgetSnapshot.renderedContentChanged(from: previous, to: $0)
            })
        XCTAssertTrue(result)
        XCTAssertEqual(callbacks, 1)
        XCTAssertFalse(changed)
    }

    func testCancellationAtFinalAdmissionPreventsPublication() async {
        let gate = Gate(expectation(description: "payload suspended before cancellation"))
        let value = snapshot()
        var saves = 0
        let work = Task {
            await WidgetPublicationBoundary.publish(prepare: {
                await gate.wait(); return value
            }, validate: { true }, checkBoundary: {
                try Task.checkCancellation()
            }, isCurrent: { true }, save: { _ in saves += 1 })
        }
        addTeardownBlock { @MainActor in gate.release(); _ = await work.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        work.cancel()
        gate.release()
        let result = await work.value
        XCTAssertFalse(result)
        XCTAssertEqual(saves, 0)
    }

    func testReleasedOldPayloadCannotReplaceAlreadyPublishedSuccessor() async {
        let gate = Gate(expectation(description: "old payload suspended"))
        let oldSnapshot = snapshot(recovery: 40), newSnapshot = snapshot(recovery: 80)
        var revision = 1
        var delivered: [WidgetSnapshot] = []
        let oldWork = Task {
            await WidgetPublicationBoundary.publish(prepare: {
                await gate.wait(); return oldSnapshot
            }, validate: { revision == 1 }, checkBoundary: {}, isCurrent: { revision == 1 },
                save: { delivered.append($0) })
        }
        addTeardownBlock { @MainActor in gate.release(); _ = await oldWork.value }
        await fulfillment(of: [gate.entered], timeout: 5)
        revision = 2
        let newResult = await WidgetPublicationBoundary.publish(prepare: { newSnapshot },
            validate: { revision == 2 }, checkBoundary: {}, isCurrent: { revision == 2 },
            save: { delivered.append($0) })
        XCTAssertTrue(newResult)
        gate.release()
        let oldResult = await oldWork.value
        XCTAssertFalse(oldResult)
        XCTAssertEqual(delivered, [newSnapshot])
    }
}

// These regressions require the actual app module and disposable SQLite Store. They are not part
// of the retained Foundation-only 45-method harness and never use an App Group or WidgetKit sink.
import GRDB
import NoopPush
import WhoopStore
@testable import Strand

private func exportBoundaryFixtureBaseDirectory() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"] else {
        return URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
    }
    var isDirectory: ObjCBool = false
    guard path.hasPrefix("/"), !path.utf8.contains(0),
          FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw NSError(domain: "NARATestFixtureRoot", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "NARA_TEST_FIXTURE_ROOT must name an existing absolute directory"
        ])
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

@MainActor
final class ExportBoundaryStoreFixture {
    enum Failure: Error { case hermeticHostRequired }
    let root: URL
    let context: AccountSessionContext
    let layout: AccountStorageLayout
    let defaults: UserDefaults
    let store: WhoopStore
    let repo: Repository
    private var model: AppModel?
    private var legacyToken: String?

    init() async throws {
        let base = try exportBoundaryFixtureBaseDirectory()
        root = base.appendingPathComponent("export-boundary-" + UUID().uuidString)
        context = .init(scope: try AccountScope(projectURL: "https://" + UUID().uuidString + ".invalid",
            userID: UUID().uuidString), generation: UUID())
        layout = .init(baseDirectory: root, scope: context.scope)
        try layout.prepare()
        defaults = try XCTUnwrap(UserDefaults(suiteName: layout.preferencesSuite))
        defaults.setPersistentDomain(["noopExperimentalSleepV2": false], forName: layout.preferencesSuite)
        store = try await WhoopStore(path: layout.databaseURL.path)
        try await store.bindAccountOwner(projectURL: context.scope.projectURL, userID: context.scope.userID)
        for id in ["my-whoop", "my-whoop-noop", "synthetic-strap", "synthetic-strap-noop", "apple-health"] {
            try await store.upsertDevice(id: id, mac: nil, name: "synthetic export fixture")
        }
        repo = Repository(deviceId: "synthetic-strap", storageLayout: layout)
        repo.setStoreForTesting(store)
    }

    func openModel() throws -> AppModel {
        guard AppRuntimeMode.isUnitTesting else { throw Failure.hermeticHostRequired }
        let context = context, store = store
        let driver = IntelligenceEngine.PreferenceRecomputeDriver(markOwed: { [weak self] in
            let token = UUID().uuidString; self?.legacyToken = token; return token
        }, markCompleted: { [weak self] _, token in
            guard let self, let token, token == self.legacyToken else { return false }
            self.legacyToken = nil; return true
        }, parkAttempt: { [weak self] token in
            guard let self, let token, token == self.legacyToken else { return false }
            self.legacyToken = nil; return true
        })
        let result = AppModel(storageLayout: layout, context: context, captureAllowed: false,
            openStore: { store }, postIllnessNotification: { _ in XCTFail("empty synthetic fixture has no illness event") },
            scoringInputDependencies: ScoringPreferenceAppTestSupport.dependencies(context: context, isCurrent: { $0 == context }),
            nativePreferenceCurrent: { $0 == context }, preferenceScoringEnabled: { false },
            preferenceRecomputeDriver: driver, isCurrent: { $0 == context })
        result.syncEngine.bind(result)
        model = result
        return result
    }

    func hideSeries() async throws {
        try await store.registryWriter.write { db in
            try db.execute(sql: "ALTER TABLE metricSeries RENAME TO widgetRetainedMetricSeries")
        }
    }

    func restoreSeries() async throws {
        try await store.registryWriter.write { db in
            try db.execute(sql: "ALTER TABLE widgetRetainedMetricSeries RENAME TO metricSeries")
        }
    }

    func close() async throws {
        if let model {
            let generic = model.shutdownForAccountChange()
            _ = await model.intelligence.runPreferenceProjection()
            let bleDrained = await model.ble.drainCaptureAfterAccountChange()
            XCTAssertTrue(bleDrained)
            if let generic { let drained = await generic.drain(); XCTAssertTrue(drained) }
            await model.scoringPreferences?.waitForRetirement()
            try await model.scoringInputs?.waitForRetirement()
        }
        model = nil
        repo.shutdownForAccountChange()
        try store.registryWriter.close()
        defaults.removePersistentDomain(forName: layout.preferencesSuite)
        try FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class WidgetExportRepositoryTests: XCTestCase {
    private func fixture() async throws -> ExportBoundaryStoreFixture {
        let fixture = try await ExportBoundaryStoreFixture()
        addTeardownBlock { @MainActor in try await fixture.close() }
        return fixture
    }

    private func daily(_ day: String, recovery: Double = 10) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 70, remMin: 90,
            lightMin: 260, disturbances: 1, restingHr: 60, avgHrv: 50, recovery: recovery,
            strain: 4, exerciseCount: 0)
    }

    private func rest(_ repo: Repository, anchor: String?, today: String,
                      guarded: Bool = true) async throws -> Double? {
        try await WidgetPublicationBoundary.restScore(anchorDay: anchor, today: today,
            requiresSuccessfulRead: guarded, strictRead: {
                try await repo.exploreSeriesForExport(key: "sleep_performance", source: "my-whoop")
            }, legacyRead: {
                await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            }, serverOwned: { repo.serverPresentation.owns(.sleepPerformance) })
    }

    func testActualReadFailureRetainsExactWidgetJobDespiteValidMetadataThenRetryPublishesStoredValue() async throws {
        let f = try await fixture(), model = try f.openModel()
        await model.retryScoringPreferenceRecompute()
        XCTAssertEqual(model.intelligence.preferenceWorkDisposition, .complete)
        let today = Repository.localDayKey(Date())
        _ = try await f.store.upsertMetricSeries([.init(day: today, key: "sleep_performance", value: 83.25)],
                                               deviceId: "my-whoop")
        model.repo.days = [daily(today)]
        let token = try await f.store.markJobOwed(kind: "widgetPublish")
        try await f.hideSeries()
        var deliveries: [Double?] = [], metadataAfterFailure: [Bool] = []
        var errors: [DatabaseError] = [], preparationValidations = 0, stageCalls = 0
        model.syncEngine.dependentStageDriver = .init(perform: { stage, admission in
            XCTAssertEqual(stage, .widgetPublish); stageCalls += 1
            let result = await WidgetPublicationBoundary.publish(prepare: {
                do { return try await self.rest(model.repo, anchor: today, today: today) }
                catch { if let error = error as? DatabaseError { errors.append(error) }; throw error }
            }, validate: {
                preparationValidations += 1; return await admission.validate()
            }, checkBoundary: { try admission.checkBoundary() }, isCurrent: { model.isAccountRuntimeActive },
                save: { deliveries.append($0) })
            if !result { metadataAfterFailure.append(await admission.validate()) }
            return result
        })
        await model.syncEngine.drain(reason: .foreground)
        XCTAssertEqual(stageCalls, 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.resultCode, .SQLITE_ERROR)
        XCTAssertTrue(errors.first?.message?.contains("no such table: metricSeries") == true)
        XCTAssertEqual(metadataAfterFailure, [true], "head/token validation does not prove payload reads succeeded")
        XCTAssertEqual(preparationValidations, 0)
        XCTAssertTrue(deliveries.isEmpty)
        let retained = try await f.store.owedJobs()
        XCTAssertEqual(retained.first { $0.kind == "widgetPublish" }?.token, token)
        XCTAssertEqual(retained.first { $0.kind == "widgetPublish" }?.attempts, 1)

        try await f.restoreSeries()
        await model.syncEngine.drain(reason: .foreground)
        XCTAssertEqual(stageCalls, 2)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(preparationValidations, 1)
        XCTAssertEqual(deliveries, [83.25])
        let completed = try await f.store.owedJobs()
        XCTAssertFalse(completed.contains { $0.kind == "widgetPublish" })
        let preserved = try await f.store.metricSeries(deviceId: "my-whoop", key: "sleep_performance", from: today, to: today)
        XCTAssertEqual(preserved, [.init(day: today, key: "sleep_performance", value: 83.25)])
    }

    func testStrictReadPreservesDailyComputedCanonicalActiveAndImportedPrecedence() async throws {
        let f = try await fixture()
        let days = (1...5).map { "2026-09-0\($0)" }
        f.repo.days = days.map { daily($0) }
        let layers: [(String, Int, Double)] = [
            ("my-whoop-noop", 1, 20), ("synthetic-strap-noop", 2, 30),
            ("my-whoop", 3, 40), ("synthetic-strap", 4, 50)
        ]
        for (source, start, value) in layers {
            _ = try await f.store.upsertMetricSeries(days[start...].map { .init(day: $0, key: "recovery", value: value) },
                                                   deviceId: source)
        }
        let strict = try await f.repo.exploreSeriesForExport(key: "recovery", source: "my-whoop", fullHistory: true)
        let legacy = await f.repo.exploreSeries(key: "recovery", source: "my-whoop", fullHistory: true)
        XCTAssertEqual(strict.map(\.day), days)
        XCTAssertEqual(strict.map(\.value), [10, 20, 30, 40, 50])
        XCTAssertEqual(strict.map(\.value), legacy.map(\.value))
        let exactSource = try await f.repo.exploreSeriesForExport(key: "recovery", source: "synthetic-strap-noop", fullHistory: true)
        XCTAssertEqual(exactSource.map(\.day), Array(days[2...]))
        XCTAssertEqual(exactSource.map(\.value), [30, 30, 30])
    }

    func testStrictReadPreservesRestSeriesPrecedenceOverDailyComposite() async throws {
        let f = try await fixture(), today = Repository.localDayKey(Date())
        f.repo.days = [daily(today)]
        let fallback = try XCTUnwrap(Repository.dailyColumn(key: "sleep_performance", day: daily(today)))
        let emptyStored = try await f.repo.exploreSeriesForExport(key: "sleep_performance", source: "my-whoop")
        XCTAssertEqual(emptyStored.map(\.value), [fallback])
        for (source, value) in [("my-whoop-noop", 20.0), ("synthetic-strap-noop", 30),
                                ("my-whoop", 40), ("synthetic-strap", 50)] {
            _ = try await f.store.upsertMetricSeries([.init(day: today, key: "sleep_performance", value: value)], deviceId: source)
            let strict = try await rest(f.repo, anchor: today, today: today)
            let legacy = try await rest(f.repo, anchor: today, today: today, guarded: false)
            XCTAssertEqual(strict, value)
            XCTAssertEqual(strict, legacy)
        }
    }

    func testSuccessfulEmptyLocalSeriesIsPublishableNotAReadError() async throws {
        let f = try await fixture(), today = Repository.localDayKey(Date())
        var deliveries: [Double?] = []
        let result = await WidgetPublicationBoundary.publish(prepare: {
            try await self.rest(f.repo, anchor: today, today: today)
        }, validate: { true }, checkBoundary: {}, isCurrent: { true }, save: { deliveries.append($0) })
        XCTAssertTrue(result)
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertNil(deliveries[0])
    }

    func testAuthoritativeServerNullSkipsBrokenLocalStoreAndForbidsTailFallback() async throws {
        let f = try await fixture(), today = Repository.localDayKey(Date())
        let previous = Repository.localDayKey(Date().addingTimeInterval(-86400))
        f.repo.days = [daily(today)]
        _ = try await f.store.upsertMetricSeries([.init(day: today, key: "sleep_performance", value: 99)], deviceId: "my-whoop")
        func entry(day: String, value: Any) throws -> ServerScoreDayState {
            let payload: [String: Any] = ["schemaVersion": 2, "userId": f.context.scope.userID,
                "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "day": day,
                "timezone": TimeZone.current.identifier, "algorithmVersion": "synthetic-export",
                "inputRevision": 2, "resultRevision": 3, "computedAt": "2026-09-18T14:00:00Z",
                "status": "partial", "coverage": [:], "capabilities": ["sleep_performance"],
                "daily": ["sleep_performance": value], "sleep": []]
            let decoded = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: payload), requestedDay: day)
            return ServerScoreDayState(snapshot: decoded.snapshot, phase: .partial, fetchedAt: nil,
                cached: false, pending: false, requestedInputRevision: 2, archiveStatus: nil)
        }
        let null = try entry(day: today, value: NSNull()), prior = try entry(day: previous, value: 77.0)
        func state(_ entries: [String: ServerScoreDayState], revision: UInt64) -> ServerScoreViewState {
            .init(generation: UUID(), revision: revision, currentDay: today, timezone: TimeZone.current.identifier,
                configured: true, authenticated: true, capabilities: [.sleepPerformance],
                activated: [.sleepPerformance], days: entries)
        }
        f.repo.applyServerScores(state([today: null], revision: 1))
        try await f.hideSeries()
        let empty = try await f.repo.exploreSeriesForExport(key: "sleep_performance", source: "my-whoop")
        XCTAssertTrue(empty.isEmpty, "authoritative null is valid even if the local query would throw")
        f.repo.applyServerScores(state([today: null, previous: prior], revision: 2))
        let strict = try await f.repo.exploreSeriesForExport(key: "sleep_performance", source: "my-whoop")
        XCTAssertEqual(strict.map(\.value), [77])
        let value = try await rest(f.repo, anchor: today, today: today)
        XCTAssertNil(value, "server-owned null cannot borrow yesterday or the local 99")
    }

    func testLegacyNilPolicyStillPublishesDailyFallbackAfterActualQueryFailure() async throws {
        let f = try await fixture(), today = Repository.localDayKey(Date())
        f.repo.days = [daily(today)]
        let expected = try XCTUnwrap(Repository.dailyColumn(key: "sleep_performance", day: daily(today)))
        try await f.hideSeries()
        var values: [Double?] = []
        let result = await WidgetPublicationBoundary.publish(prepare: {
            try await self.rest(f.repo, anchor: today, today: today, guarded: false)
        }, validate: { true }, checkBoundary: {}, isCurrent: { true }, save: { values.append($0) })
        XCTAssertTrue(result)
        XCTAssertEqual(values, [expected])
    }

    func testSuccessfulStrictSamePayloadTakesNoChangePath() async throws {
        let f = try await fixture(), today = Repository.localDayKey(Date())
        _ = try await f.store.upsertMetricSeries([.init(day: today, key: "sleep_performance", value: 71)], deviceId: "my-whoop")
        let prior = WidgetSnapshot(recovery: 40, bpm: nil, batteryPct: nil, bonded: false,
            updated: Date(), rest: 71, accountNamespace: f.context.scope.namespace)
        var callbacks = 0, writes = 0
        let result = await WidgetPublicationBoundary.publish(prepare: {
            var next = prior
            let rest = try await self.rest(f.repo, anchor: today, today: today)
            next.rest = rest.map { Int($0.rounded()) }
            next.updated = prior.updated.addingTimeInterval(1)
            return next
        }, validate: { true }, checkBoundary: {}, isCurrent: { true }, save: {
            callbacks += 1
            if WidgetSnapshot.renderedContentChanged(from: prior, to: $0) { writes += 1 }
        })
        XCTAssertTrue(result)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(writes, 0)
    }

    func testStrictUnavailableStoreFailsWhileLegacyRemainsEmpty() async throws {
        let f = try await fixture()
        let repo = Repository(deviceId: "synthetic-unavailable", storageLayout: f.layout, presentationAllowed: false)
        defer { repo.shutdownForAccountChange() }
        do {
            _ = try await repo.exploreSeriesForExport(key: "sleep_performance", source: "my-whoop")
            XCTFail("unavailable Store is not successful absence")
        } catch Repository.ExportSeriesReadError.storeUnavailable { }
        let legacy = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        XCTAssertTrue(legacy.isEmpty)
    }

    func testStrictRetiredRepositoryCannotReadOrPublish() async throws {
        let f = try await fixture()
        f.repo.shutdownForAccountChange()
        do {
            _ = try await f.repo.exploreSeriesForExport(key: "sleep_performance", source: "my-whoop")
            XCTFail("retirement must cancel strict reads")
        } catch is CancellationError { }
    }

    func testStrictOtherSourceFailureIsNotConvertedToAnEmptySeries() async throws {
        let f = try await fixture()
        try await f.hideSeries()
        do {
            _ = try await f.repo.exploreSeriesForExport(key: "sleep_performance", source: "apple-health")
            XCTFail("the original SQL error must propagate")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
            XCTAssertTrue(error.message?.contains("no such table: metricSeries") == true)
        }
    }

    func testNoAnchorNeedsNoSeriesReadEvenWhenLocalTableIsUnavailable() async throws {
        let f = try await fixture()
        try await f.hideSeries()
        let value = try await rest(f.repo, anchor: nil, today: Repository.localDayKey(Date()))
        XCTAssertNil(value)
    }

    func testLocalTodayMayBorrowTailButHistoricalAnchorCannotBorrowAnotherDay() async throws {
        let f = try await fixture(), now = Date()
        let today = Repository.localDayKey(now)
        let yesterday = Repository.localDayKey(now.addingTimeInterval(-86400))
        let older = Repository.localDayKey(now.addingTimeInterval(-2 * 86400))
        _ = try await f.store.upsertMetricSeries([.init(day: yesterday, key: "sleep_performance", value: 61)], deviceId: "my-whoop")
        let tail = try await rest(f.repo, anchor: today, today: today)
        let absent = try await rest(f.repo, anchor: older, today: today)
        let exact = try await rest(f.repo, anchor: yesterday, today: today)
        XCTAssertEqual(tail, 61)
        XCTAssertNil(absent)
        XCTAssertEqual(exact, 61)
    }

    func testStrictSkinTemperatureUsesSameScaleFilterAndSeriesRangeAsLegacyReader() async throws {
        let f = try await fixture()
        let rows: [MetricPoint] = [
            .init(day: "2000-01-01", key: "skin_temp", value: 33),
            .init(day: "2000-01-02", key: "skin_temp", value: 34),
            .init(day: "2000-01-03", key: "skin_temp", value: 35),
            .init(day: "2000-01-04", key: "skin_temp", value: 0.2)
        ]
        for source in ["my-whoop", "apple-health"] {
            _ = try await f.store.upsertMetricSeries(rows, deviceId: source)
            let full = try await f.repo.exploreSeriesForExport(key: "skin_temp", source: source, fullHistory: true)
            let legacy = await f.repo.exploreSeries(key: "skin_temp", source: source, fullHistory: true)
            XCTAssertEqual(full.map(\.day), ["2000-01-04"])
            XCTAssertEqual(full.map(\.value), [0.2], "the existing selector uses the latest scale, not a majority vote")
            XCTAssertEqual(full.map(\.day), legacy.map(\.day))
            XCTAssertEqual(full.map(\.value), legacy.map(\.value))
            let recent = try await f.repo.exploreSeriesForExport(key: "skin_temp", source: source, days: 1)
            XCTAssertTrue(recent.isEmpty)
        }
    }
}
