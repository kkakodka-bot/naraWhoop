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

    func testFIFOAgeAndIndependentOwnersHoldPreparationThroughDrain() {
        let environment = Environment(), first = UUID(), second = UUID()
        let budget = environment.budget()
        budget.pipeline(owner: first, depth: 3, oldestUptime: 95)
        budget.pipeline(owner: second, depth: 2, oldestUptime: 98)
        XCTAssertEqual(budget.snapshot().fifoDepth, 5)
        XCTAssertEqual(budget.snapshot().oldestFIFOAge, 5)
        XCTAssertEqual(budget.snapshot().reason, .fifo)
        budget.pipeline(owner: first, depth: 0, oldestUptime: nil)
        XCTAssertFalse(budget.permits(.cloudPreparation))
        budget.pipeline(owner: second, depth: 0, oldestUptime: nil)
        XCTAssertEqual(budget.snapshot().reason, .cooldown)
        environment.update(now: 115)
        XCTAssertTrue(budget.permits(.cloudPreparation))
    }

    func testBackgroundDeadlineExpiresWithoutAnotherLifecycleCallback() {
        let environment = Environment(), budget = environment.budget()
        budget.lifecycle(backgroundRemaining: 10)
        XCTAssertTrue(budget.permits(.bulk))
        XCTAssertEqual(budget.snapshot().maximumTransfers, 1)
        environment.update(now: 106)
        XCTAssertEqual(budget.snapshot().reason, .backgroundDeadline)
        XCTAssertTrue(budget.permits(.localCommit))
        budget.lifecycle(backgroundRemaining: nil)
        XCTAssertTrue(budget.permits(.bulk))
    }

    func testStorageAndNetworkPressureNeverBlockDurableCommit() {
        let environment = Environment(), budget = environment.budget()
        budget.storage(availableBytes: 1_048_576)
        XCTAssertEqual(budget.snapshot().reason, .storage)
        XCTAssertTrue(budget.permits(.acknowledgement))
        budget.storage(availableBytes: 1_073_741_824)
        budget.network(permitted: false)
        XCTAssertEqual(budget.snapshot(for: .cloudTransfer).reason, .network)
        XCTAssertTrue(budget.permits(.scoring))
        XCTAssertTrue(budget.permits(.localCommit))
    }

    func testGrantedBackgroundTaskOverridesExpiredAssertionUntilLastTaskCompletes() {
        let environment = Environment(), budget = environment.budget()
        let first = UUID(), second = UUID()
        budget.lifecycle(backgroundRemaining: 0)
        XCTAssertFalse(budget.permits(.cloudPreparation))
        budget.backgroundOpportunity(owner: first, active: true)
        budget.backgroundOpportunity(owner: second, active: true)
        XCTAssertTrue(budget.permits(.cloudPreparation))
        XCTAssertEqual(budget.snapshot().maximumTransfers, 1)
        environment.update(thermal: .critical)
        XCTAssertFalse(budget.permits(.cloudPreparation), "A granted task cannot bypass thermal priority")
        XCTAssertTrue(budget.permits(.localCommit))
        environment.update(now: 200, thermal: .nominal)
        _ = budget.permits(.bulk)
        environment.update(now: 215)
        budget.backgroundOpportunity(owner: first, active: false)
        budget.backgroundOpportunity(owner: first, active: false)
        XCTAssertTrue(budget.permits(.bulk))
        budget.backgroundOpportunity(owner: second, active: false)
        XCTAssertEqual(budget.snapshot().reason, .backgroundDeadline)
    }

    func testCloudPackingQuotaDoesNotPreventDrainingImmutableJobs() {
        let environment = Environment(), budget = environment.budget(), owner = UUID()
        budget.queuedCloud(owner: owner, bytes: 300 * 1_048_576, jobs: 130)
        XCTAssertEqual(budget.snapshot(for: .cloudPreparation).reason, .queuedCloud)
        XCTAssertTrue(budget.permits(.cloudTransfer))
        budget.queuedCloud(owner: owner, bytes: 0, jobs: 0)
        XCTAssertTrue(budget.permits(.cloudPreparation))
    }

    func testHistoryAndHealthyFIFOReserveRelayWithoutAdmittingMaintenance() {
        let environment = Environment(), budget = environment.budget(), owner = UUID()
        budget.history(owner: owner, active: true)
        for time in stride(from: 100.0, through: 1_000.0, by: 1) {
            environment.update(now: time)
            budget.pipeline(owner: owner, depth: 1, oldestUptime: time - 0.001)
            for work in [ResourceBudget.Work.cloudPreparation, .cloudTransfer, .cloudControl] {
                XCTAssertTrue(budget.permits(work))
                XCTAssertEqual(budget.snapshot(for: work).maximumTransfers, 2)
            }
            XCTAssertFalse(budget.permits(.bulk))
            budget.pipeline(owner: owner, depth: 0, oldestUptime: nil)
            XCTAssertTrue(budget.permits(.cloudTransfer), "FIFO transitions cannot renew relay cooldown")
        }
    }

    func testOverloadedFIFOStopsPreparationWhileReceiptsAndReadyDebtCanDrain() {
        let environment = Environment(), budget = environment.budget(), owner = UUID()
        budget.pipeline(owner: owner, depth: ResourceBudget.maximumPreparationFIFODepth + 1, oldestUptime: 100)
        XCTAssertEqual(budget.snapshot(for: .cloudPreparation).reason, .fifo)
        XCTAssertTrue(budget.permits(.cloudTransfer))
        XCTAssertTrue(budget.permits(.cloudControl))
        budget.pipeline(owner: owner, depth: 1, oldestUptime: 90)
        XCTAssertEqual(budget.snapshot(for: .cloudPreparation).reason, .fifo)
        XCTAssertTrue(budget.permits(.localCommit))
    }

    func testLaterBLEOpportunityOverridesOldAssertionOnlyForItsFiniteWorkBudget() {
        let environment = Environment(), budget = environment.budget(), owner = UUID()
        budget.lifecycle(backgroundRemaining: 10)
        environment.update(now: 7_300)
        XCTAssertFalse(budget.permits(.cloudTransfer))
        let event = budget.beginOpportunity(kind: .bleCallback, owner: owner)
        XCTAssertNil(event.platformDeadlineUptime, "CoreBluetooth does not expose an OS grant deadline")
        XCTAssertEqual(event.workDeadlineUptime, 7_302)
        XCTAssertTrue(budget.isCurrent(event))
        XCTAssertTrue(budget.permits(.cloudPreparation))
        XCTAssertTrue(budget.permits(.cloudControl))
        XCTAssertEqual(budget.snapshot(for: .cloudTransfer).maximumTransfers, 1)
        XCTAssertFalse(budget.permits(.bulk), "A BLE event is not maintenance authorization")
        environment.update(now: 7_302)
        XCTAssertFalse(budget.isCurrent(event))
        XCTAssertEqual(budget.snapshot(for: .cloudTransfer).reason, .backgroundDeadline)
        XCTAssertTrue(budget.permits(.localCommit))
    }

    func testOpportunityExpirationAndOwnerRetirementCannotCancelAnotherOwner() {
        let environment = Environment(), budget = environment.budget(), owner = UUID()
        budget.lifecycle(backgroundRemaining: 0)
        let first = budget.beginOpportunity(kind: .taskAssertion, owner: owner, maximumDuration: 5, platformRemaining: 0.5)
        let other = budget.beginOpportunity(kind: .urlSession, owner: UUID())
        XCTAssertEqual(first.platformDeadlineUptime, 100.5)
        environment.update(now: 100.5)
        XCTAssertFalse(budget.isCurrent(first))
        XCTAssertTrue(budget.isCurrent(other))
        budget.endOpportunities(owner: owner)
        XCTAssertTrue(budget.permits(.cloudControl))
        budget.endOpportunity(other)
        XCTAssertFalse(budget.permits(.cloudControl))
        budget.endOpportunity(other)
        XCTAssertFalse(budget.permits(.cloudTransfer))
    }

    func testFiniteOpportunityDoesNotBypassHeatStorageOrNetwork() {
        let environment = Environment(), budget = environment.budget()
        budget.lifecycle(backgroundRemaining: 0)
        _ = budget.beginOpportunity(kind: .bleCallback, owner: UUID())
        environment.update(thermal: .critical)
        XCTAssertEqual(budget.snapshot(for: .cloudControl).reason, .heat)
        environment.update(thermal: .nominal)
        budget.storage(availableBytes: 1)
        XCTAssertEqual(budget.snapshot(for: .cloudTransfer).reason, .storage)
        budget.storage(availableBytes: 1_073_741_824)
        budget.network(permitted: false)
        XCTAssertEqual(budget.snapshot(for: .cloudControl).reason, .network)
        XCTAssertTrue(budget.permits(.acknowledgement))
    }
}
