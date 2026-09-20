import Foundation
import XCTest
@testable import Strand

final class ResourceBudgetTests: XCTestCase {
    private final class Environment: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: TimeInterval = 100
        private var heat = ProcessInfo.ThermalState.nominal.rawValue
        private var powerSaving = false

        func update(now: TimeInterval? = nil, thermal: ProcessInfo.ThermalState? = nil,
                    lowPower: Bool? = nil) {
            lock.lock(); defer { lock.unlock() }
            if let now { instant = now }
            if let thermal { heat = thermal.rawValue }
            if let lowPower { powerSaving = lowPower }
        }

        private func read<T>(_ value: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return value()
        }

        func budget() -> ResourceBudget {
            ResourceBudget(cooldown: 15,
                clock: { self.read { self.instant } },
                thermal: { self.read { self.heat } },
                lowPower: { self.read { self.powerSaving } })
        }
    }

    func testSeriousAndCriticalHeatBlockBulkButAdmitCommitAndACK() {
        for heat in [ProcessInfo.ThermalState.serious, .critical] {
            let environment = Environment()
            environment.update(thermal: heat)
            let budget = environment.budget()

            XCTAssertFalse(budget.permits(.bulk), "heat=\(heat.rawValue)")
            XCTAssertTrue(budget.permits(.localCommit))
            XCTAssertTrue(budget.permits(.acknowledgement))
            XCTAssertTrue(budget.permits(.urgentControl))
        }
    }

    func testOverlappingHistoryOwnersKeepBulkBlockedUntilLastRelease() {
        let environment = Environment()
        let budget = environment.budget()
        let first = UUID(), second = UUID()
        budget.history(owner: first, active: true)
        budget.history(owner: second, active: true)
        environment.update(now: 130)
        budget.history(owner: first, active: false)
        budget.history(owner: UUID(), active: false)
        environment.update(now: 160)
        XCTAssertFalse(budget.permits(.bulk), "The remaining history owner still has priority")
        XCTAssertTrue(budget.permits(.localCommit))
        XCTAssertTrue(budget.permits(.acknowledgement))

        budget.history(owner: second, active: false)
        environment.update(now: 174.999)
        XCTAssertFalse(budget.permits(.bulk))
        environment.update(now: 175)
        XCTAssertTrue(budget.permits(.bulk))
    }

    func testDuplicateHistoryReleaseDoesNotExtendCooldown() {
        let environment = Environment()
        let budget = environment.budget()
        let owner = UUID()
        budget.history(owner: owner, active: true)
        budget.history(owner: owner, active: true)
        environment.update(now: 120)
        budget.history(owner: owner, active: false)
        environment.update(now: 134)
        budget.history(owner: owner, active: false)
        XCTAssertFalse(budget.permits(.bulk))
        environment.update(now: 135)
        XCTAssertTrue(budget.permits(.bulk), "Duplicate callbacks cannot postpone existing debt forever")
    }

    func testThermalRecoveryAfterLongIdleStartsHysteresisAtObservedRecovery() {
        let environment = Environment()
        let budget = environment.budget()
        environment.update(thermal: .serious)
        XCTAssertFalse(budget.permits(.bulk))

        environment.update(now: 1_000, thermal: .nominal)
        XCTAssertFalse(budget.permits(.bulk), "No worker polling during heat must not bypass cooling time")
        environment.update(now: 1_014.999)
        XCTAssertFalse(budget.permits(.bulk))
        environment.update(now: 1_015)
        XCTAssertTrue(budget.permits(.bulk))
    }

    func testNewHeatDuringCooldownRequiresAnotherStableRecoveryInterval() {
        let environment = Environment()
        let budget = environment.budget()
        environment.update(thermal: .serious)
        XCTAssertFalse(budget.permits(.bulk))
        environment.update(now: 105, thermal: .nominal)
        XCTAssertFalse(budget.permits(.bulk))
        environment.update(now: 110, thermal: .critical)
        XCTAssertFalse(budget.permits(.bulk))

        environment.update(now: 200, thermal: .fair)
        XCTAssertFalse(budget.permits(.bulk))
        environment.update(now: 214.999)
        XCTAssertFalse(budget.permits(.bulk))
        environment.update(now: 215)
        XCTAssertTrue(budget.permits(.bulk))
    }

    func testLowPowerBlocksBulkAndRecoveryRetainsCooldown() {
        let environment = Environment()
        let budget = environment.budget()
        environment.update(lowPower: true)
        XCTAssertFalse(budget.permits(.bulk))
        XCTAssertTrue(budget.permits(.localCommit))
        XCTAssertTrue(budget.permits(.acknowledgement))

        environment.update(now: 1_000, lowPower: false)
        XCTAssertFalse(budget.permits(.bulk))
        environment.update(now: 1_014.999)
        XCTAssertFalse(budget.permits(.bulk))
        environment.update(now: 1_015)
        XCTAssertTrue(budget.permits(.bulk))
    }

    func testFairTemperatureWithoutEarlierPressureAdmitsBulk() {
        let environment = Environment()
        environment.update(thermal: .fair)
        let budget = environment.budget()
        XCTAssertTrue(budget.permits(.bulk))
    }

    func testResumeDelayTracksLastOwnerAndDoesNotPollWhilePressureIsActive() {
        let environment = Environment()
        let budget = environment.budget()
        let owner = UUID()
        XCTAssertEqual(budget.bulkResumeDelay(), 0)
        budget.history(owner: owner, active: true)
        XCTAssertNil(budget.bulkResumeDelay())
        environment.update(now: 110)
        budget.history(owner: owner, active: false)
        XCTAssertEqual(budget.bulkResumeDelay(), 15)
        environment.update(now: 124)
        XCTAssertEqual(budget.bulkResumeDelay(), 1)
        environment.update(now: 125)
        XCTAssertEqual(budget.bulkResumeDelay(), 0)
        environment.update(thermal: .serious)
        XCTAssertNil(budget.bulkResumeDelay())
        environment.update(now: 200, thermal: .nominal)
        XCTAssertEqual(budget.bulkResumeDelay(), 15)
        XCTAssertTrue(budget.permits(.acknowledgement))
    }
}
