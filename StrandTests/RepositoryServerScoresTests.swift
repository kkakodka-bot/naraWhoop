import Foundation
import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class RepositoryServerScoresTests: XCTestCase {
    private let day = "2026-09-18"
    private func local() -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 400, efficiency: 90, deepMin: 60, remMin: 90,
                    lightMin: 250, disturbances: 3, restingHr: 80, avgHrv: 99,
                    recovery: 77, strain: 22, exerciseCount: 2, avgSdnn: 33)
    }
    private func state(snapshot: Bool = true, active: Bool = true) throws -> ServerScoreViewState {
        let payload: [String: Any] = [
            "schemaVersion": 2, "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "day": day,
            "timezone": "America/Los_Angeles", "algorithmVersion": "test-2",
            "inputRevision": 2, "resultRevision": 3, "computedAt": "2026-09-18T14:00:00Z",
            "status": "partial", "coverage": [:],
            "daily": ["hrv_rmssd_ms": 42.0, "resting_hr_bpm": NSNull()], "sleep": []
        ]
        let decoded = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: payload), requestedDay: day)
        let entry = ServerScoreDayState(snapshot: snapshot ? decoded.snapshot : nil,
            phase: snapshot ? .partial : .pending, fetchedAt: nil, cached: false, pending: !snapshot,
            requestedInputRevision: 2, archiveStatus: nil)
        return ServerScoreViewState(generation: UUID(), revision: 1, currentDay: day,
            timezone: "America/Los_Angeles", configured: true, authenticated: true,
            capabilities: [.hrv, .restingHR, .sleepSessions],
            activated: active ? [.hrv, .restingHR, .sleepSessions] : [], days: [day: entry])
    }

    func testEveryRepositoryConsumerSeesAuthoritativeNullWithoutMutatingLocalData() async throws {
        let repo = Repository(deviceId: "my-whoop")
        repo.days = [local()]
        repo.sleeps = [CachedSleepSession(startTs: 1, endTs: 2, efficiency: 90,
                                         restingHr: 80, avgHrv: 99, stagesJSON: nil)]
        repo.applyServerScores(try state())
        XCTAssertEqual(repo.days.first?.avgHrv, 42)
        XCTAssertNil(repo.days.first?.restingHr)
        XCTAssertEqual(repo.days.first?.recovery, 77, "unmigrated fields retain their producer")
        XCTAssertTrue(repo.sleeps.isEmpty, "an authoritative empty set removes old sleep")
        XCTAssertEqual(repo.localSleepModelDays, [local()], "unmigrated builders retain their own inputs")
        XCTAssertEqual(repo.localSleepModelSleeps.count, 1)
        let resolved = await repo.resolvedSeries(key: "hrv", source: "my-whoop", from: day, to: day)
        XCTAssertEqual(resolved.points.map(\.value), [42])
        XCTAssertEqual(resolved.usedSources, ["server-snapshot"])
        let null = await repo.resolvedSeries(key: "rhr", source: "my-whoop", from: day, to: day)
        XCTAssertTrue(null.points.isEmpty)
        repo.applyServerScores(try state(active: false))
        XCTAssertEqual(repo.days, [local()], "rollback changes ownership, not the saved source rows")
        XCTAssertEqual(repo.sleeps.count, 1)
    }

    func testPendingOwnershipMasksLocalAndFreshInstallNeedsNoLocalDailyRow() throws {
        let masked = RepositoryServerScores.daily([local()], state: try state(snapshot: false))
        XCTAssertNil(masked.first?.avgHrv)
        XCTAssertNil(masked.first?.restingHr)
        let fresh = RepositoryServerScores.daily([], state: try state())
        XCTAssertEqual(fresh.first?.day, day)
        XCTAssertEqual(fresh.first?.avgHrv, 42)
        let rows = RepositoryServerScores.vitals([SourcedDailyMetric(metric: local(), source: .noopComputed)], state: try state())
        XCTAssertNil(rows.first(where: { $0.source == .noopComputed })?.metric.avgHrv)
        XCTAssertEqual(rows.first(where: { $0.source == .noopComputed })?.metric.recovery, 77)
        XCTAssertEqual(rows.first(where: { $0.source == .serverSnapshot })?.metric.avgHrv, 42)
        XCTAssertNil(rows.first(where: { $0.source == .serverSnapshot })?.metric.recovery)
    }

    func testRetiredRepositoryIgnoresLateSnapshots() throws {
        let repo = Repository(deviceId: "my-whoop")
        repo.days = [local()]
        repo.shutdownForAccountChange()
        repo.applyServerScores(try state())
        XCTAssertTrue(repo.days.isEmpty)
        XCTAssertTrue(repo.sleeps.isEmpty)
        XCTAssertTrue(repo.vitalRows.isEmpty)
        XCTAssertTrue(repo.localSleepModelDays.isEmpty)
        XCTAssertTrue(repo.localSleepModelSleeps.isEmpty)
    }

    func testStatusOnlyPublicationPreservesDerivedRevisionButKeepsStatusVisible() throws {
        let repo = Repository(deviceId: "my-whoop")
        repo.days = [local()]
        let initial = try state()
        XCTAssertTrue(repo.applyServerScores(initial))
        let sequence = repo.refreshSeq
        let projected = repo.days
        for phase in [ServerScoreDayState.Phase.loading, .offline, .authenticationRequired] {
            let changed = ServerScoreViewState(generation: initial.generation, revision: initial.revision,
                currentDay: initial.currentDay, timezone: initial.timezone, configured: true, authenticated: true,
                capabilities: initial.capabilities, activated: initial.activated,
                days: initial.days.mapValues { $0.retaining(phase) })
            XCTAssertFalse(repo.applyServerScores(changed))
            XCTAssertEqual(repo.serverPresentation.days[day]?.phase, phase)
            XCTAssertEqual(repo.refreshSeq, sequence)
            XCTAssertEqual(repo.days, projected)
        }
    }

    func testSameNumericRevisionNeverSuppressesOwnershipOrAccountReplacement() throws {
        let repo = Repository(deviceId: "my-whoop")
        repo.days = [local()]
        let initial = try state()
        repo.applyServerScores(initial)
        let sequence = repo.refreshSeq
        let replacement = ServerScoreViewState(generation: UUID(), revision: initial.revision,
            currentDay: initial.currentDay, timezone: initial.timezone, configured: true, authenticated: true,
            capabilities: initial.capabilities, activated: [], days: [:])
        XCTAssertTrue(repo.applyServerScores(replacement))
        XCTAssertGreaterThan(repo.refreshSeq, sequence)
        XCTAssertEqual(repo.days, [local()])
    }

    func testMetricCatalogAliasesResolveToTheSameOwnershipKeys() throws {
        XCTAssertEqual(RepositoryServerScores.metric(key: "spo2"), .spo2)
        XCTAssertEqual(RepositoryServerScores.metric(key: "energy_kcal"), .activeKcal)
        XCTAssertEqual(RepositoryServerScores.metric(key: "in_bed_min"), .sleepInBed)
        XCTAssertNil(RepositoryServerScores.metric(key: "unrecognized"))
    }

    func testHealthWritebackPreservesNullReplacementAndNeverRelabelsRmssd() throws {
        let pending = ServerHealthWritebackPlan.days(state: try state(snapshot: false), from: day, through: day)
        XCTAssertTrue(pending.isEmpty, "pending without a snapshot is not a deletion instruction")
        let plans = ServerHealthWritebackPlan.days(state: try state(), from: day, through: day)
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.replacedVitals, [.restingHR])
        XCTAssertNil(plan.snapshot.daily?[.restingHR], "a committed null must remove the old HealthKit value")
        XCTAssertFalse(plan.replacedVitals.contains(.hrv), "RMSSD has no matching HealthKit quantity")
        XCTAssertTrue(plan.replacesSleep)
        XCTAssertTrue(plan.snapshot.sleep.isEmpty, "empty committed sleep is an explicit replacement")
    }
}
