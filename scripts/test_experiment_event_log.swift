// Run with: swiftc Strand/Data/ExperimentEventLog.swift scripts/test_experiment_event_log.swift -o /tmp/noop-event-log-test && /tmp/noop-event-log-test
import Foundation

@main
struct ExperimentEventLogSmokeTest {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-event-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("events.json")
        let start = Date(timeIntervalSince1970: 1_789_763_348.125)
        let log = ExperimentEventLog(fileURL: url)
        log.start(label: "  Walking  ", deviceId: "strap-A", at: start)
        precondition(log.active?.label == "Walking")
        log.start(label: "Duplicate", deviceId: "strap-B", at: start)
        precondition(log.events.count == 1)

        // Reopening must preserve the original start, label, and strap attribution.
        let reopened = ExperimentEventLog(fileURL: url)
        precondition(reopened.active?.startUnixSeconds == start.timeIntervalSince1970)
        precondition(reopened.active?.deviceId == "strap-A")
        reopened.stop(at: start.addingTimeInterval(-1))
        precondition(reopened.active != nil && reopened.errorMessage != nil)
        reopened.stop(at: start.addingTimeInterval(90.5))
        precondition(reopened.active == nil && reopened.errorMessage == nil)
        reopened.stop(at: start.addingTimeInterval(100))
        let saved = ExperimentEventLog(fileURL: url)
        precondition(saved.events.count == 1)
        precondition(saved.events[0].endUnixSeconds! - saved.events[0].startUnixSeconds == 90.5)
        let exported = try JSONDecoder().decode([ExperimentEvent].self,
            from: Data(contentsOf: saved.export()!))
        precondition(exported[0].id == saved.events[0].id)
        precondition(exported[0].endUnixSeconds == saved.events[0].endUnixSeconds)

        // Corrupt existing labels must never be replaced by an empty/new log.
        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let original = Data("invalid json".utf8)
        try original.write(to: corruptURL)
        let corrupt = ExperimentEventLog(fileURL: corruptURL)
        corrupt.start(label: "Rest", deviceId: "strap-A", at: start)
        precondition(corrupt.errorMessage != nil && corrupt.events.isEmpty)
        let preserved = try Data(contentsOf: corruptURL)
        precondition(preserved == original)

        // An unsuccessful disk commit must leave the active interval available to retry.
        let failureURL = directory.appendingPathComponent("failure.json")
        let failing = ExperimentEventLog(fileURL: failureURL)
        try FileManager.default.createDirectory(at: failureURL, withIntermediateDirectories: false)
        failing.start(label: "Rest", deviceId: "strap-A", at: start)
        precondition(failing.errorMessage != nil && failing.active == nil)

        let stopURL = directory.appendingPathComponent("stop-failure.json")
        let stopFailure = ExperimentEventLog(fileURL: stopURL)
        stopFailure.start(label: "Rest", deviceId: "strap-A", at: start)
        // Replace only this test's file with an unwritable destination shape.
        try FileManager.default.removeItem(at: stopURL)
        try FileManager.default.createDirectory(at: stopURL, withIntermediateDirectories: false)
        stopFailure.stop(at: start.addingTimeInterval(30))
        precondition(stopFailure.active != nil && stopFailure.errorMessage != nil)
        print("PASS: persistence, duplicate taps, clock reversal, exact export, corrupt-file protection, write failure")
    }
}
