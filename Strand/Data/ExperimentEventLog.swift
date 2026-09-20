import Foundation
import Combine

/// Temporary research labels. Independent of sensor collection and the database schema.
/// Unix seconds retain fractional precision; each tap is committed before the UI changes.
struct ExperimentEvent: Codable, Identifiable, Sendable {
    let id: UUID
    var label: String
    var note: String?
    let deviceId: String
    var startUnixSeconds: Double
    var endUnixSeconds: Double?
    let timeZoneIdentifier: String
    let source: String
}

struct ExperimentEventExport: Codable, Sendable {
    let schemaVersion: Int
    let exportedAtUnixSeconds: Double
    let events: [ExperimentEvent]
    let eventLabels: [String]
    /// Retained for older analysis tools. New clients should use `eventLabels`, which includes every
    /// editable preset rather than separating factory and user-created labels.
    let customLabels: [String]
}

@MainActor
protocol ExperimentEventPushSource: Sendable {
    func eventDeviceIds() -> [String]
    func eventDayKeys(deviceId: String) -> [String]
    func eventSnapshot(deviceId: String, from start: Int64, to end: Int64, limit: Int) -> [ExperimentEvent]
}

@MainActor
final class ExperimentEventLog: ObservableObject {
    static let shared = ExperimentEventLog()
    static let defaultLabels = [
        "Rest", "Walking", "Wrist movement", "Sleeve warming",
        "Off wrist", "Posture change", "Mental arithmetic",
    ]
    @Published private(set) var events: [ExperimentEvent] = []
    @Published private(set) var eventLabels: [String] = defaultLabels
    @Published private(set) var errorMessage: String?
    private var fileURL: URL?
    private var loaded = false

    var active: ExperimentEvent? { events.last(where: { $0.endUnixSeconds == nil }) }
    var customLabels: [String] {
        eventLabels.filter { label in
            !Self.defaultLabels.contains { $0.caseInsensitiveCompare(label) == .orderedSame }
        }
    }

    init(fileURL: URL? = nil) {
        do {
            let url: URL
            if let fileURL { url = fileURL }
            else {
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                url = support.appendingPathComponent("OpenWhoop/experiment-events.json")
            }
            self.fileURL = url
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                if let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
                    events = state.events
                    if let savedLabels = state.eventLabels {
                        eventLabels = deduplicated(savedLabels)
                    } else {
                        // Builds 345-355 stored factory labels in code and only persisted additions.
                        eventLabels = deduplicated(Self.defaultLabels + (state.customLabels ?? []))
                    }
                } else {
                    // Build 345 stored a bare event array. Read it once and upgrade on the next write.
                    events = try JSONDecoder().decode([ExperimentEvent].self, from: data)
                }
            }
            loaded = true
        } catch {
            errorMessage = "Could not open event labels: \(error.localizedDescription)"
        }
    }

    func start(label: String, note: String? = nil, deviceId: String, at date: Date = Date()) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, active == nil, !label.isEmpty else { return }
        var next = events
        next.append(ExperimentEvent(id: UUID(), label: label, note: trimmed(note), deviceId: deviceId,
            startUnixSeconds: date.timeIntervalSince1970, endUnixSeconds: nil,
            timeZoneIdentifier: TimeZone.current.identifier, source: "manual_experiment"))
        save(next)
    }

    /// Add an interval after it happened. Unlike `start`, this does not affect the active recorder.
    /// The complete event is committed atomically so it is immediately available to JSON/cloud export.
    @discardableResult
    func addCompleted(label value: String, note: String? = nil, deviceId: String,
                      start: Date, end: Date) -> Bool {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !label.isEmpty else { return false }
        guard end >= start else {
            errorMessage = "End time must be after the start time."
            return false
        }
        guard end <= Date().addingTimeInterval(60) else {
            errorMessage = "Past events cannot end in the future."
            return false
        }
        var next = events
        next.append(ExperimentEvent(id: UUID(), label: label, note: trimmed(note), deviceId: deviceId,
            startUnixSeconds: start.timeIntervalSince1970, endUnixSeconds: end.timeIntervalSince1970,
            timeZoneIdentifier: TimeZone.current.identifier, source: "manual_experiment_retroactive"))
        next.sort {
            if $0.startUnixSeconds != $1.startUnixSeconds { return $0.startUnixSeconds < $1.startUnixSeconds }
            return $0.id.uuidString < $1.id.uuidString
        }
        return save(next)
    }

    func stop(at date: Date = Date()) {
        finishActive(note: active?.note, at: date)
    }

    /// Complete the active interval and its latest note in one atomic file replacement. A failed
    /// write therefore cannot stop the event while silently retaining an older note.
    func stop(note: String, at date: Date = Date()) {
        finishActive(note: note, at: date)
    }

    /// Persist the in-progress note as the user types so navigation, backgrounding, or a process
    /// restart cannot discard the draft. The event remains active and its start time is unchanged.
    func saveActiveNoteDraft(_ note: String) {
        guard loaded, let index = events.lastIndex(where: { $0.endUnixSeconds == nil }) else { return }
        let nextNote = trimmed(note)
        guard events[index].note != nextNote else { return }
        var next = events
        next[index].note = nextNote
        save(next)
    }

    private func finishActive(note: String?, at date: Date) {
        guard loaded, let index = events.lastIndex(where: { $0.endUnixSeconds == nil }) else { return }
        guard date.timeIntervalSince1970 >= events[index].startUnixSeconds else {
            errorMessage = "The phone clock moved backwards. Check Date & Time before stopping."
            return
        }
        var next = events
        next[index].note = trimmed(note)
        next[index].endUnixSeconds = date.timeIntervalSince1970
        save(next)
    }

    @discardableResult
    func addEventLabel(_ value: String) -> Bool {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !label.isEmpty else { return false }
        guard !eventLabels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else {
            errorMessage = "An event type with that name already exists."
            return false
        }
        return save(events, eventLabels: eventLabels + [label])
    }

    func addCustomLabel(_ value: String) { _ = addEventLabel(value) }

    func removeEventLabel(_ value: String) {
        guard loaded else { return }
        let next = eventLabels.filter { $0.caseInsensitiveCompare(value) != .orderedSame }
        guard next != eventLabels else { return }
        _ = save(events, eventLabels: next)
    }

    func removeCustomLabel(_ value: String) { removeEventLabel(value) }

    @discardableResult
    func renameEventLabel(_ oldValue: String, to newValue: String) -> Bool {
        let label = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !label.isEmpty,
              let index = eventLabels.firstIndex(where: { $0.caseInsensitiveCompare(oldValue) == .orderedSame }) else {
            return false
        }
        guard !eventLabels.enumerated().contains(where: {
            $0.offset != index && $0.element.caseInsensitiveCompare(label) == .orderedSame
        }) else {
            errorMessage = "An event type with that name already exists."
            return false
        }
        var next = eventLabels
        next[index] = label
        return save(events, eventLabels: next)
    }

    func moveEventLabels(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard loaded, !offsets.isEmpty else { return }
        var next = eventLabels
        let moving = offsets.sorted().map { next[$0] }
        for index in offsets.sorted(by: >) { next.remove(at: index) }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertion = max(0, min(next.count, destination - removedBeforeDestination))
        next.insert(contentsOf: moving, at: insertion)
        _ = save(events, eventLabels: next)
    }

    func update(id: UUID, label value: String, note: String?) {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !label.isEmpty, let index = events.firstIndex(where: { $0.id == id }) else { return }
        var next = events
        next[index].label = label
        next[index].note = trimmed(note)
        save(next)
    }

    @discardableResult
    func update(id: UUID, label value: String, note: String?, start: Date, end: Date) -> Bool {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !label.isEmpty, let index = events.firstIndex(where: { $0.id == id }) else { return false }
        guard end >= start else {
            errorMessage = "End time must be after the start time."
            return false
        }
        guard end <= Date().addingTimeInterval(60) else {
            errorMessage = "Past events cannot end in the future."
            return false
        }
        var next = events
        next[index].label = label
        next[index].note = trimmed(note)
        next[index].startUnixSeconds = start.timeIntervalSince1970
        next[index].endUnixSeconds = end.timeIntervalSince1970
        next.sort {
            if $0.startUnixSeconds != $1.startUnixSeconds { return $0.startUnixSeconds < $1.startUnixSeconds }
            return $0.id.uuidString < $1.id.uuidString
        }
        return save(next)
    }

    func delete(id: UUID) {
        guard loaded else { return }
        let next = events.filter { $0.id != id }
        guard next.count != events.count else { return }
        save(next)
    }

    func export() -> URL? {
        guard loaded else { return nil }
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("noop-events-\(UUID().uuidString).json")
            let snapshot = ExperimentEventExport(
                schemaVersion: 3,
                exportedAtUnixSeconds: Date().timeIntervalSince1970,
                events: events,
                eventLabels: eventLabels,
                customLabels: customLabels
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = "Could not export labels: \(error.localizedDescription)"
            return nil
        }
    }

    func eventDeviceIds() -> [String] {
        Array(Set(events.map(\.deviceId).filter { !$0.isEmpty })).sorted()
    }

    func eventDayKeys(deviceId: String) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return Array(Set(events.lazy.filter { $0.deviceId == deviceId }.map { event in
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: Date(timeIntervalSince1970: event.startUnixSeconds)
            )
            return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        })).sorted()
    }

    func eventSnapshot(deviceId: String, from start: Int64, to end: Int64, limit: Int) -> [ExperimentEvent] {
        Array(events.lazy
            .filter {
                $0.deviceId == deviceId
                    && $0.startUnixSeconds >= Double(start)
                    && $0.startUnixSeconds < Double(end)
            }
            .sorted {
                if $0.startUnixSeconds != $1.startUnixSeconds {
                    return $0.startUnixSeconds < $1.startUnixSeconds
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(limit))
    }

    @discardableResult
    private func save(_ next: [ExperimentEvent]) -> Bool {
        save(next, eventLabels: eventLabels)
    }

    @discardableResult
    private func save(_ next: [ExperimentEvent], eventLabels nextLabels: [String]) -> Bool {
        guard loaded, let fileURL else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let state = PersistedState(schemaVersion: 3, events: next,
                                       customLabels: nil, eventLabels: nextLabels)
            try encoder.encode(state).write(to: fileURL, options: .atomic)
            events = next
            eventLabels = nextLabels
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Event was not saved: \(error.localizedDescription). Please try again."
            return false
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else { continue }
            result.append(label)
        }
        return result
    }

    private struct PersistedState: Codable {
        let schemaVersion: Int
        let events: [ExperimentEvent]
        let customLabels: [String]?
        let eventLabels: [String]?
    }
}

extension ExperimentEventLog: ExperimentEventPushSource {}
