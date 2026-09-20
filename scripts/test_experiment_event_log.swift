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

        // Schema-2 installs persisted only user-added labels. Migration must turn the factory list
        // into ordinary editable entries without losing those additions.
        let legacyURL = directory.appendingPathComponent("legacy-events.json")
        try Data("""
        {"schemaVersion":2,"events":[],"customLabels":["Reading"]}
        """.utf8).write(to: legacyURL)
        let migrated = ExperimentEventLog(fileURL: legacyURL)
        precondition(migrated.eventLabels == ExperimentEventLog.defaultLabels + ["Reading"])
        ExperimentEventLog.defaultLabels.forEach(migrated.removeEventLabel)
        migrated.removeEventLabel("Reading")
        precondition(ExperimentEventLog(fileURL: legacyURL).eventLabels.isEmpty)

        let log = ExperimentEventLog(fileURL: url)
        log.addCustomLabel("  Reading  ")
        log.addCustomLabel("reading")
        log.addCustomLabel("rest")
        precondition(log.customLabels == ["Reading"])
        precondition(log.eventLabels == ExperimentEventLog.defaultLabels + ["Reading"])
        log.start(label: "  Walking  ", note: "  uphill  ", deviceId: "strap-A", at: start)
        precondition(log.active?.label == "Walking")
        precondition(log.active?.note == "uphill")
        log.start(label: "Duplicate", deviceId: "strap-B", at: start)
        precondition(log.events.count == 1)

        // Reopening must preserve the original start, label, and strap attribution.
        let reopened = ExperimentEventLog(fileURL: url)
        precondition(reopened.customLabels == ["Reading"])
        precondition(reopened.active?.startUnixSeconds == start.timeIntervalSince1970)
        precondition(reopened.active?.deviceId == "strap-A")
        precondition(reopened.eventDayKeys(deviceId: "strap-A") == ["2026-09-18"])
        precondition(reopened.eventDayKeys(deviceId: "strap-B").isEmpty)
        reopened.saveActiveNoteDraft("  draft survives relaunch  ")
        precondition(ExperimentEventLog(fileURL: url).active?.note == "draft survives relaunch")
        reopened.stop(at: start.addingTimeInterval(-1))
        precondition(reopened.active != nil && reopened.errorMessage != nil)
        reopened.stop(note: "  final atomic note  ", at: start.addingTimeInterval(90.5))
        precondition(reopened.active == nil && reopened.errorMessage == nil)
        precondition(reopened.events[0].note == "final atomic note")
        let eventID = reopened.events[0].id
        reopened.update(id: eventID, label: "Outdoor walk", note: "  sunny  ")
        precondition(reopened.events[0].label == "Outdoor walk")
        precondition(reopened.events[0].note == "sunny")
        reopened.stop(at: start.addingTimeInterval(100))
        let saved = ExperimentEventLog(fileURL: url)
        precondition(saved.events.count == 1)
        precondition(saved.events[0].label == "Outdoor walk")
        precondition(saved.events[0].note == "sunny")
        precondition(saved.events[0].endUnixSeconds! - saved.events[0].startUnixSeconds == 90.5)

        // A completed interval can be added after the fact without becoming the active event.
        precondition(saved.addCompleted(label: "Reading", note: "chapter 3", deviceId: "strap-A",
                                        start: start.addingTimeInterval(120),
                                        end: start.addingTimeInterval(180)))
        precondition(saved.active == nil && saved.events.count == 2)
        precondition(!saved.addCompleted(label: "Invalid", deviceId: "strap-A",
                                         start: start.addingTimeInterval(300),
                                         end: start.addingTimeInterval(200)))

        // Factory presets are ordinary editable event types after migration.
        precondition(saved.renameEventLabel("Rest", to: "Recovery rest"))
        saved.removeEventLabel("Walking")
        precondition(saved.eventLabels.first == "Recovery rest")
        precondition(!saved.eventLabels.contains("Walking"))
        let exported = try JSONDecoder().decode(ExperimentEventExport.self,
            from: Data(contentsOf: saved.export()!))
        precondition(exported.schemaVersion == 3)
        precondition(exported.eventLabels == saved.eventLabels)
        precondition(exported.events.count == 2)
        precondition(exported.events.first(where: { $0.id == eventID })?.endUnixSeconds ==
                     saved.events.first(where: { $0.id == eventID })?.endUnixSeconds)

        saved.removeCustomLabel("reading")
        precondition(!saved.eventLabels.contains("Reading"))
        saved.delete(id: eventID)
        precondition(saved.events.count == 1)
        let deleted = ExperimentEventLog(fileURL: url)
        precondition(deleted.events.count == 1)
        precondition(deleted.eventLabels == saved.eventLabels)

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
        print("PASS: persistence, retroactive intervals, editable presets, duplicate taps, clock reversal, export, corrupt-file protection, write failure")
    }
}
