import Foundation
import Combine

/// Temporary research labels. Independent of sensor collection and the database schema.
/// Unix seconds retain fractional precision; each tap is committed before the UI changes.
struct ExperimentEvent: Codable, Identifiable {
    let id: UUID
    let label: String
    let deviceId: String
    let startUnixSeconds: Double
    var endUnixSeconds: Double?
    let timeZoneIdentifier: String
    let source: String
}

@MainActor
final class ExperimentEventLog: ObservableObject {
    static let shared = ExperimentEventLog()
    @Published private(set) var events: [ExperimentEvent] = []
    @Published private(set) var errorMessage: String?
    private var fileURL: URL?
    private var loaded = false

    var active: ExperimentEvent? { events.last(where: { $0.endUnixSeconds == nil }) }

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
                events = try JSONDecoder().decode([ExperimentEvent].self, from: Data(contentsOf: url))
            }
            loaded = true
        } catch {
            errorMessage = "Could not open event labels: \(error.localizedDescription)"
        }
    }

    func start(label: String, deviceId: String, at date: Date = Date()) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, active == nil, !label.isEmpty else { return }
        var next = events
        next.append(ExperimentEvent(id: UUID(), label: label, deviceId: deviceId,
            startUnixSeconds: date.timeIntervalSince1970, endUnixSeconds: nil,
            timeZoneIdentifier: TimeZone.current.identifier, source: "manual_experiment"))
        save(next)
    }

    func stop(at date: Date = Date()) {
        guard loaded, let index = events.lastIndex(where: { $0.endUnixSeconds == nil }) else { return }
        guard date.timeIntervalSince1970 >= events[index].startUnixSeconds else {
            errorMessage = "The phone clock moved backwards. Check Date & Time before stopping."
            return
        }
        var next = events
        next[index].endUnixSeconds = date.timeIntervalSince1970
        save(next)
    }

    func export() -> URL? {
        guard loaded else { return nil }
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("noop-events-\(UUID().uuidString).json")
            try encoded(events).write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = "Could not export labels: \(error.localizedDescription)"
            return nil
        }
    }

    private func encoded(_ events: [ExperimentEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(events)
    }

    private func save(_ next: [ExperimentEvent]) {
        guard loaded, let fileURL else { return }
        do {
            try encoded(next).write(to: fileURL, options: .atomic)
            events = next
            errorMessage = nil
        } catch {
            errorMessage = "Event was not saved: \(error.localizedDescription). Please try again."
        }
    }
}
