import Foundation
import StrandDesign
import StrandImport
import WhoopStore

/// Export admission travels with the immutable result; a cached read is not a new measurement.
enum CanonicalExport {
    struct Window: Codable {
        let ledger: CanonicalConsumerLedger
        let currentResult: ServerCanonicalResults?
        let historicalResult: ServerCanonicalResults?
        enum CodingKeys: String, CodingKey {
            case ledger, currentResult = "current_result", historicalResult = "historical_result"
        }
    }
    struct Document: Codable {
        let schemaVersion: Int
        let windows: [Window]
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", windows }
    }

    static func isCurrent(_ ledger: CanonicalConsumerLedger) -> Bool {
        ledger.permitsRead && ledger.cached != true &&
            (ledger.readState == nil || ["available", "partial"].contains(ledger.readState!))
    }

    static func document(_ state: ServerScoreViewState) -> Document {
        Document(schemaVersion: 1, windows: state.canonicalDays.values.sorted { $0.day < $1.day }.compactMap { result in
            guard let ledger = CanonicalConsumerPublication.ledger(result, state: state) else { return nil }
            let current = isCurrent(ledger)
            return Window(ledger: ledger, currentResult: current ? result : nil,
                          historicalResult: current ? nil : result)
        })
    }

    static func data(_ state: ServerScoreViewState) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document(state))
    }

    static func csv(_ state: ServerScoreViewState) -> String {
        func cell(_ raw: String) -> String {
            let safe = raw.first.map { "=+-@\t\r".contains($0) } == true ? "'" + raw : raw
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["project,owner,source,device,window,family,metric,value,status,reason,input_revision,result_revision,algorithm,configuration,computed_at,observed_through,authorization,read_state,cached"]
        for window in document(state).windows {
            guard let result = window.currentResult ?? window.historicalResult else { continue }
            for key in result.families.keys.sorted() {
                guard let family = result.families[key] else { continue }
                for metric in family.metrics.sorted() {
                    let value = window.currentResult == nil ? nil : family.number(metric)
                    var fields: [String] = [result.project, result.ownerID, result.sourceID, result.deviceID, result.day, key, metric]
                    fields.append(value.map { String($0) } ?? "")
                    fields += [family.status, family.reason ?? ""]
                    fields.append(family.inputRevision.map { String($0) } ?? "")
                    fields += [family.resultRevision ?? "", family.algorithmVersion ?? "", family.configurationVersion ?? ""]
                    fields += [family.computedAt ?? "", family.observedThrough ?? "", family.canonicalQualification ?? ""]
                    fields.append(window.ledger.readState ?? "available")
                    fields.append(window.ledger.cached.map { String($0) } ?? "false")
                    lines.append(fields.map(cell).joined(separator: ","))
                }
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func writeArchive(state: ServerScoreViewState, historicalEntries: [(name: String, data: Data)],
                             to destination: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let entries: [(name: String, data: Data)] = [
            ("canonical_results.json", try data(state)),
            ("canonical_read_states.json", try encoder.encode(document(state).windows.map(\.ledger))),
            ("canonical_metrics.csv", Data(csv(state).utf8)),
            ("README.txt", Data("Canonical export schema 1. current_result is admitted current data; historical_result retains the original immutable receipt after a failed, pending, or cached read and is not a current measurement. CSV values are blank for those reads. Every window includes its ownership and read-state ledger. historical_source files retain original rows for audit, not canonical physiology. No phone scoring or reconstruction is performed.\n".utf8))
        ]
        try WhoopCsvExporter.writeArchive(entries: entries + historicalEntries, to: destination)
    }

    @MainActor
    static func installArchive(from staged: URL, to destination: URL,
                               access: () throws -> (() -> Void) = { {} },
                               validate: () throws -> Void) throws {
        try validate()
        let close = try access()
        defer { close() }
        let payload = try Data(contentsOf: staged)
        // Opening a provider or acquiring a URL can change the account/device/read state.
        try validate()
        try payload.write(to: destination, options: .atomic)
    }

    @MainActor
    static func writeShortcut(state: ServerScoreViewState, directory: URL,
                              validate: () throws -> Void = {}, beforePublish: () throws -> Void = {}) throws {
        try validate()
        let payload = try data(state)
        // Retire the unrevisioned automation first. If this fails, publish no replacement result.
        try Data().write(to: directory.appendingPathComponent(ShortcutHealthExport.fileName), options: .atomic)
        try validate()
        try beforePublish()
        try validate()
        // Atomic installation preserves the previous complete payload if publication fails.
        try payload.write(to: directory.appendingPathComponent("noop_server_results.json"), options: .atomic)
    }
}
