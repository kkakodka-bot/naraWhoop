#!/usr/bin/env swift
// Regenerate the oracle block in PushCapabilitiesParseTests.swift and PushCapabilitiesParseTest.kt.
// Run from repo root: swift Tools/push_capabilities_oracle.swift

import Foundation

private let receiverId = "00000000-0000-4000-8000-000000000099"

enum PushAppendTable: String, CaseIterable {
    case hrSample, rrInterval, event, battery, spo2Sample, skinTempSample, respSample, gravitySample
    var wireName: String { rawValue }
}

enum PushMutableTable: String, CaseIterable {
    case dailyMetric, sleepSession, workout, journal
    var wireName: String { rawValue }
}

struct PushProtocolException: Error {
    let message: String
    init(message: String) { self.message = message }
}

struct PushCapabilities {
    let appendTables: Set<PushAppendTable>
    let mutableTables: Set<PushMutableTable>
    let protocolVersion: String
    let receiverStateId: String
    var isEmpty: Bool { appendTables.isEmpty && mutableTables.isEmpty }

    static func parse(_ bytes: Data) throws -> PushCapabilities {
        guard let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw PushProtocolException(message:"capabilities are not valid JSON")
        }
        let required = Set(["type", "protocolVersion", "receiverStateId", "streams"])
        let actual = Set(obj.keys)
        guard required.isSubset(of: actual) else {
            throw PushProtocolException(message:"capabilities are missing required protocol 1.0 members")
        }
        if actual.contains(where: { ["command", "commands", "endpoint", "url", "cadence", "schema", "fields"].contains($0) }) {
            throw PushProtocolException(message:"capabilities contain forbidden remote-control metadata")
        }
        guard obj["type"] as? String == "capabilities" else {
            throw PushProtocolException(message:"unsupported capability document")
        }
        let version = obj["protocolVersion"] as? String ?? ""
        guard version == "1.0" || version == "1.1" else {
            throw PushProtocolException(message:"unsupported capability document")
        }
        guard let receiverStateId = obj["receiverStateId"] as? String,
              UUID(uuidString: receiverStateId)?.uuidString.lowercased() == receiverStateId else {
            throw PushProtocolException(message:"capabilities.receiverStateId must be a canonical UUID")
        }
        guard let streams = obj["streams"] as? [Any] else {
            throw PushProtocolException(message:"capabilities.streams must be an array")
        }
        let appendByName = Dictionary(uniqueKeysWithValues: PushAppendTable.allCases.map { ($0.wireName, $0) })
        let mutableByName = Dictionary(uniqueKeysWithValues: PushMutableTable.allCases.map { ($0.wireName, $0) })
        var seen = Set<String>()
        var append = Set<PushAppendTable>()
        var mutable = Set<PushMutableTable>()
        for item in streams {
            guard let name = item as? String else {
                throw PushProtocolException(message:"capability stream names must be strings")
            }
            guard seen.insert(name).inserted else {
                throw PushProtocolException(message:"duplicate capability stream")
            }
            if let table = appendByName[name] {
                append.insert(table)
            } else if let table = mutableByName[name] {
                mutable.insert(table)
            }
        }
        return PushCapabilities(appendTables: append, mutableTables: mutable, protocolVersion: version, receiverStateId: receiverStateId)
    }
}

func document(version: String, streams: [String]) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "type": "capabilities",
        "protocolVersion": version,
        "receiverStateId": receiverId,
        "streams": streams,
    ])
}

func fixtureBytes(_ label: String) -> Data {
    switch label {
    case "allKnownV10": return document(version: "1.0", streams: ["hrSample", "journal", "dailyMetric"])
    case "allKnownV11": return document(version: "1.1", streams: ["hrSample", "journal", "dailyMetric"])
    case "someUnknown": return document(version: "1.0", streams: ["hrSample", "stepSample", "futureStream"])
    case "allUnknown": return document(version: "1.1", streams: ["futureScalarStream", "futureStream"])
    case "emptyStreams": return document(version: "1.0", streams: [])
    case "duplicate": return document(version: "1.0", streams: ["hrSample", "hrSample"])
    case "nonString":
        return try! JSONSerialization.data(withJSONObject: [
            "type": "capabilities", "protocolVersion": "1.0", "receiverStateId": receiverId,
            "streams": ["hrSample", 1],
        ])
    case "missingReceiver":
        return try! JSONSerialization.data(withJSONObject: [
            "type": "capabilities", "protocolVersion": "1.0", "streams": ["hrSample"],
        ])
    case "forbiddenCommand":
        return try! JSONSerialization.data(withJSONObject: [
            "type": "capabilities", "protocolVersion": "1.0", "receiverStateId": receiverId,
            "streams": ["hrSample"], "command": "sync-now",
        ])
    case "unsupportedVersion": return document(version: "2.0", streams: ["hrSample"])
    default: fatalError("unknown fixture \(label)")
    }
}

let okCases = ["allKnownV10", "allKnownV11", "someUnknown", "allUnknown", "emptyStreams"]
let errCases = ["duplicate", "nonString", "missingReceiver", "forbiddenCommand", "unsupportedVersion"]

for label in okCases {
    do {
        let parsed = try PushCapabilities.parse(fixtureBytes(label))
        let append = PushAppendTable.allCases.filter { parsed.appendTables.contains($0) }.map(\.wireName).joined(separator: ",")
        let mutable = PushMutableTable.allCases.filter { parsed.mutableTables.contains($0) }.map(\.wireName).joined(separator: ",")
        print("\(label)|OK|\(parsed.protocolVersion)|\(append)|\(mutable)|\(parsed.isEmpty ? 1 : 0)")
    } catch {
        fputs("unexpected error for \(label): \(error)\n", stderr)
        exit(1)
    }
}

for label in errCases {
    do {
        _ = try PushCapabilities.parse(fixtureBytes(label))
        fputs("expected error for \(label)\n", stderr)
        exit(1)
    } catch let error as PushProtocolException {
        print("\(label)|ERR|\(error.message)")
    } catch {
        fputs("unexpected error type for \(label): \(error)\n", stderr)
        exit(1)
    }
}
