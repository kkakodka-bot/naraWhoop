import XCTest
@testable import Strand
import WhoopStore

final class SyncDrainPolicyTests: XCTestCase {

    func testIntermediateBacklogBurstDefersDrain() {
        XCTAssertFalse(SyncDrainPolicy.shouldStartDrain(backlogBurstInProgress: true))
        XCTAssertTrue(SyncDrainPolicy.shouldStartDrain(backlogBurstInProgress: false))
    }

    func testOffloadCompleteRunsOnlyDurablyOwedStages() {
        let owed: Set<SyncJobKind> = [.rescore, .healthWriteback]
        for stage in SyncDrainPolicy.stageOrder {
            XCTAssertEqual(
                SyncDrainPolicy.shouldRun(stage: stage, owedKinds: owed, reason: .offloadComplete),
                owed.contains(stage),
                "wake reason must not invent debt for \(stage.rawValue)"
            )
        }
    }

    func testForegroundRunsOnlyOwedStages() {
        let owed: Set<SyncJobKind> = [.cloudPush, .widgetPublish]
        XCTAssertTrue(SyncDrainPolicy.shouldRun(stage: .cloudPush, owedKinds: owed, reason: .foreground))
        XCTAssertFalse(SyncDrainPolicy.shouldRun(stage: .rescore, owedKinds: owed, reason: .foreground))
        XCTAssertTrue(SyncDrainPolicy.shouldRun(stage: .widgetPublish, owedKinds: owed, reason: .foreground))
        XCTAssertFalse(SyncDrainPolicy.shouldRun(stage: .healthWriteback, owedKinds: owed, reason: .foreground))
    }

    func testDeferredOrRemarkedRescoreBlocksExports() {
        XCTAssertFalse(SyncDrainPolicy.shouldContinue(
            after: .rescore, succeeded: false, rescoreStillOwed: true))
        XCTAssertFalse(SyncDrainPolicy.shouldContinue(
            after: .rescore, succeeded: true, rescoreStillOwed: true))
        XCTAssertTrue(SyncDrainPolicy.shouldContinue(
            after: .rescore, succeeded: true, rescoreStillOwed: false))
    }

    func testExportFailureDoesNotBlockIndependentLaterExports() {
        XCTAssertTrue(SyncDrainPolicy.shouldContinue(
            after: .cloudPush, succeeded: false, rescoreStillOwed: false))
        XCTAssertTrue(SyncDrainPolicy.shouldContinue(
            after: .cloudPush, succeeded: true, rescoreStillOwed: true),
            "raw transport must not prevent the following rescore stage from running")
    }

    func testMatchingBurstVectorsCoalesceToOneTerminalDrain() {
        struct Vector {
            let name: String
            let owed: Bool
            let continuations: [Bool]
            let expectedDrains: Int
        }
        let vectors = [
            Vector(name: "ordinary-morning-empty-tail", owed: true,
                   continuations: [true, false], expectedDrains: 1),
            Vector(name: "productive-deep-backlog", owed: true,
                   continuations: [true, true, true, false], expectedDrains: 1),
            Vector(name: "intermediate-history-complete", owed: true,
                   continuations: [true], expectedDrains: 0),
            Vector(name: "productive-timeout-continuation", owed: true,
                   continuations: [true, false], expectedDrains: 1),
            Vector(name: "final-empty-tail-retains-debt", owed: true,
                   continuations: [false], expectedDrains: 1),
            Vector(name: "duplicate-or-phantom", owed: false,
                   continuations: [false], expectedDrains: 0),
            Vector(name: "future-clock-rejected-rows", owed: false,
                   continuations: [false], expectedDrains: 0),
            Vector(name: "restart-with-durable-debt", owed: true,
                   continuations: [false], expectedDrains: 1),
            Vector(name: "cap-terminal", owed: true,
                   continuations: Array(repeating: true, count: BackfillContinuation.defaultMaxAutoContinues)
                       + [false], expectedDrains: 1),
        ]
        for vector in vectors {
            let drains = vector.continuations.filter {
                BacklogBurstDrainPolicy.shouldDrain(
                    hasOwedWork: vector.owed,
                    willAutoContinue: $0)
            }.count
            XCTAssertEqual(drains, vector.expectedDrains, vector.name)
        }
    }

    func testDeepBurstRunsEachExpensiveStageExactlyOnceAfterTerminal() {
        let owed = Set(SyncDrainPolicy.stageOrder)
        var runs = Dictionary(uniqueKeysWithValues: SyncDrainPolicy.stageOrder.map { ($0, 0) })
        let boundaries = Array(
            repeating: true,
            count: BackfillContinuation.defaultMaxAutoContinues) + [false]
        for willContinue in boundaries {
            guard BacklogBurstDrainPolicy.shouldDrain(
                hasOwedWork: true,
                willAutoContinue: willContinue) else { continue }
            for stage in SyncDrainPolicy.stageOrder where SyncDrainPolicy.shouldRun(
                stage: stage,
                owedKinds: owed,
                reason: .offloadComplete) {
                runs[stage, default: 0] += 1
            }
        }
        XCTAssertEqual(runs, Dictionary(
            uniqueKeysWithValues: SyncDrainPolicy.stageOrder.map { ($0, 1) }))
    }

    func testStageOrderIsStable() {
        XCTAssertEqual(
            SyncDrainPolicy.stageOrder,
            [.cloudPush, .rescore, .healthWriteback, .widgetPublish]
        )
    }
}
