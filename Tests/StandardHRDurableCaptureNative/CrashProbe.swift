import Foundation
import Darwin
import WhoopStore

@MainActor
enum StandardHRCaptureCrashProbe {
    static let project = "https://standard-hr-fixture.invalid"
    static let user = "00000000-0000-0000-0000-0000000000a1"
    static let device = "synthetic-standard-hr"
    static let timestamp = 1_750_000_000
    static let measurement: [UInt8] = [0x16, 72, 0, 4, 0, 4]

    static func runIfRequested() async -> Bool {
        let args = CommandLine.arguments
        guard args.count == 4, args[1] == "--capture-crash-child" else { return false }
        do {
            let mode = args[2]
            let store = try await WhoopStore(path: args[3])
            try await store.bindAccountOwner(projectURL: project, userID: user)
            try await store.upsertDevice(id: device, mac: nil, name: nil)
            #if STANDARD_HR_CAPTURE_BASELINE
            let journal: GenericCaptureJournal
            if mode == "baseline-blocked-thirty" {
                journal = GenericCaptureJournal { _, _ in
                    crash("writer-entered-before-insert")
                }
            } else {
                journal = GenericCaptureJournal(store: store)
            }
            let source = StandardHRSource(live: LiveState(), deviceId: device,
                persist: { _ in fatalError("checked admission required") },
                admit: { journal.admit($0, deviceID: device) }, startCentral: false)
            let count = mode == "baseline-blocked-thirty" ? 30 : 1
            for index in 0..<count {
                guard source.ingestHeartRateMeasurement(measurement, at: timestamp + index) else { exit(80) }
            }
            if mode == "baseline-stop-control" {
                source.stop()
                journal.sealCapture()
                guard await journal.drain() else { exit(81) }
                crash("legacy-stop-drain-completed")
            } else if mode == "baseline-subthreshold" {
                guard source.pendingCaptureCount == 1, journal.pendingBatchCount == 0 else { exit(82) }
                crash("subthreshold-ram-only")
            } else if mode == "baseline-blocked-thirty" {
                guard source.pendingCaptureCount == 0, journal.pendingBatchCount == 30 else { exit(83) }
                _ = await journal.drain()
                exit(84)
            } else { exit(85) }
            #else
            let owner = try StandardHRCaptureOwner(projectURL: project, userID: user)
            var hooks = StandardHRJournalHooks()
            switch mode {
            case "before-t1": hooks.beforeAppend = { _ in crash("before-t1") }
            case "after-t1": hooks.afterAppend = { _ in crash("after-t1-before-receipt-observer") }
            case "after-projection": hooks.afterProjection = { _ in crash("projection-returned-before-ram-settlement") }
            case "after-t3": break
            default: exit(85)
            }
            let journal = try await GenericCaptureJournal.prepareStandardHR(
                store: store, owner: owner, runtimeGeneration: UUID(), hooks: hooks)
            let source = try StandardHRSource(live: LiveState(), deviceId: device,
                durableCapture: journal.standardHRSink(deviceID: device), startCentral: false)
            guard source.ingestHeartRateMeasurement(measurement, at: timestamp) else { exit(86) }
            source.stop()
            journal.sealCapture()
            guard await journal.drain() else { exit(87) }
            crash("after-t3-and-seal")
            #endif
        } catch {
            fputs("capture child preparation failed\n", stderr)
            exit(88)
        }
    }

    nonisolated static func crash(_ boundary: String) -> Never {
        print("CAPTURE_BOUNDARY \(boundary)")
        fflush(stdout)
        guard kill(getpid(), SIGKILL) == 0 else { _exit(89) }
        // Do not race normal exit against delivery of the fatal signal we are testing.
        while true { _ = Darwin.pause() }
    }
}
