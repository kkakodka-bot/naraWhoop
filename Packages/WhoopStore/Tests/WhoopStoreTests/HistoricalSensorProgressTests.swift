import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class HistoricalSensorProgressTests: XCTestCase {
    func testLegacyOutcomeDefaultExcludesHousekeepingRows() {
        let outcome = BackfillInsertOutcome(
            counts: (2, 3, 100, 200, 4, 5, 6, 7), markedJobs: false)
        XCTAssertEqual(outcome.insertedHistoricalSensorRows, 27)
    }

    func testRawOnlyProgressCountsActualInsertsWithoutScoringDebt() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(
            ppgWaveform: [
                PpgWaveformSample(ts: 1_700_000_100, samples: [1, -2], recordIndex: 10),
                PpgWaveformSample(ts: 1_700_000_100, samples: [3, -4], recordIndex: 11),
            ],
            v18Aux: [V18AuxSample(ts: 1_700_000_100, recordIndex: 12)])
        let first = try await store.insertAndMarkJobsOwed(
            streams, deviceId: "test", postOffloadJobKinds: [SyncJobKind.rescore.rawValue])
        XCTAssertEqual(first.insertedHistoricalSensorRows, 3)
        XCTAssertFalse(first.markedJobs)
        let jobs = try await store.owedJobs()
        XCTAssertEqual(jobs.map(\.kind), ["cloudPush"])

        let replay = try await store.insertAndMarkJobsOwed(
            streams, deviceId: "test", postOffloadJobKinds: [SyncJobKind.rescore.rawValue])
        XCTAssertEqual(replay.insertedHistoricalSensorRows, 0)
        XCTAssertFalse(replay.markedJobs)
    }

    func testAllAdditionalSensorStreamsContributeProgress() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(
            steps: [StepSample(ts: 100, counter: 12)],
            sleepState: [SleepStateSample(ts: 100, state: 2)],
            ppgHr: [PpgHrSample(ts: 100, bpm: 61, conf: 0.9)])
        let first = try await store.insertAndMarkJobsOwed(
            streams, deviceId: "test", postOffloadJobKinds: [SyncJobKind.rescore.rawValue])
        XCTAssertEqual(first.insertedHistoricalSensorRows, 3)
        XCTAssertTrue(first.markedJobs)
        let replay = try await store.insertAndMarkJobsOwed(
            streams, deviceId: "test", postOffloadJobKinds: [SyncJobKind.rescore.rawValue])
        XCTAssertEqual(replay.insertedHistoricalSensorRows, 0)
        XCTAssertFalse(replay.markedJobs)
    }

    func testEventsAndBatteryDoNotEstablishSensorProgress() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(
            events: [WhoopEvent(ts: 100, kind: "test", payload: [:])],
            battery: [BatterySample(ts: 100, soc: 80, mv: 3900)])
        let outcome = try await store.insertAndMarkJobsOwed(
            streams, deviceId: "test", postOffloadJobKinds: [SyncJobKind.rescore.rawValue])
        XCTAssertEqual(outcome.counts.events, 1)
        XCTAssertEqual(outcome.counts.battery, 1)
        XCTAssertEqual(outcome.insertedHistoricalSensorRows, 0)
    }

    func testEmptyAuxiliaryPayloadDoesNotClaimProgress() async throws {
        let store = try await WhoopStore.inMemory()
        let outcome = try await store.insertAndMarkJobsOwed(
            Streams(v18Aux: [V18AuxSample(ts: 100)]), deviceId: "test",
            postOffloadJobKinds: [SyncJobKind.rescore.rawValue])
        XCTAssertEqual(outcome.insertedHistoricalSensorRows, 0)
        XCTAssertFalse(outcome.markedJobs)
    }

    func testWaveformIgnoresLegacyTimestampFrontierWhenRangeSkipEnabled() async throws {
        let key = "enableBackfillRangeSkip"
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(prior, forKey: key) }
        let store = try await WhoopStore.inMemory()
        let kinds = [SyncJobKind.rescore.rawValue]
        let first = try await store.insertAndMarkJobsOwed(
            Streams(ppgWaveform: [PpgWaveformSample(ts: 100, samples: [1], recordIndex: 10)]),
            deviceId: "test", postOffloadJobKinds: kinds)
        XCTAssertEqual(first.insertedHistoricalSensorRows, 1)
        let newFrontier = try await store.backfillFrontierForTest(deviceId: "test", stream: "ppgWaveform")
        XCTAssertNil(newFrontier, "waveform records must not create a timestamp-only frontier")

        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO backfillFrontier (deviceId, stream, maxTs) VALUES (?, ?, ?)
                """, arguments: ["test", "ppgWaveform", 200])
        }
        let laterRecord = Streams(ppgWaveform: [
            PpgWaveformSample(ts: 100, samples: [2], recordIndex: 11),
        ])
        let second = try await store.insertAndMarkJobsOwed(
            laterRecord, deviceId: "test", postOffloadJobKinds: kinds)
        XCTAssertEqual(second.insertedHistoricalSensorRows, 1)
        let replay = try await store.insertAndMarkJobsOwed(
            laterRecord, deviceId: "test", postOffloadJobKinds: kinds)
        XCTAssertEqual(replay.insertedHistoricalSensorRows, 0)
        let rows = try await store.ppgWaveformSamples(deviceId: "test", from: 100, to: 100)
        XCTAssertEqual(rows.map(\.recordIndex), [10, 11])
        let existingFrontier = try await store.backfillFrontierForTest(deviceId: "test", stream: "ppgWaveform")
        XCTAssertEqual(existingFrontier, 200, "old frontier rows are ignored, not rewritten")
    }

    func testDuplicateReplayDoesNotSpendAuxiliaryOrWaveformRetentionBudget() async throws {
        let store = try await receiptedFixtureStore()
        func streams(_ timestamps: [Int]) -> Streams {
            Streams(
                ppgWaveform: timestamps.map { PpgWaveformSample(ts: $0, samples: [1], recordIndex: $0) },
                v18Aux: timestamps.map { V18AuxSample(ts: $0, recordIndex: $0) })
        }
        _ = try await store.insert(
            streams([100, 101, 102]), deviceId: "test",
            v18AuxRetentionRows: 1, v18AuxPruneEveryRows: 4,
            ppgWaveformRetentionRows: 1, ppgWaveformPruneEveryRows: 4)
        _ = try await store.insert(
            streams([100]), deviceId: "test",
            v18AuxRetentionRows: 1, v18AuxPruneEveryRows: 4,
            ppgWaveformRetentionRows: 1, ppgWaveformPruneEveryRows: 4)
        let waveforms = try await store.ppgWaveformSamples(deviceId: "test", from: 0, to: 1000)
        let auxiliary = try await store.v18AuxSamples(deviceId: "test", from: 0, to: 1000)
        XCTAssertEqual(waveforms.map(\.ts), [100, 101, 102])
        XCTAssertEqual(auxiliary.map(\.ts), [100, 101, 102])

        _ = try await store.insert(
            streams([103]), deviceId: "test",
            v18AuxRetentionRows: 1, v18AuxPruneEveryRows: 4,
            ppgWaveformRetentionRows: 1, ppgWaveformPruneEveryRows: 4)
        let retainedWaveforms = try await store.ppgWaveformSamples(deviceId: "test", from: 0, to: 1000)
        let retainedAuxiliary = try await store.v18AuxSamples(deviceId: "test", from: 0, to: 1000)
        XCTAssertEqual(retainedWaveforms.map(\.ts), [103])
        XCTAssertEqual(retainedAuxiliary.map(\.ts), [103])
    }
}
