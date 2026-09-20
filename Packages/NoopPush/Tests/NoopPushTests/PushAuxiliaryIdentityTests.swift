import Foundation
import XCTest
@testable import NoopPush

final class PushAuxiliaryIdentityTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"
    private let device = "fixture-device"
    private var rows: [PushBinaryRow] {
        [
            .v18Aux(.init(rowId: 1, ts: 100, fields: Data([2, 1, 0, 0, 0, 0, 0, 0, 0]), recordIndex: 0)),
            .v18Aux(.init(rowId: 2, ts: 100, fields: Data([2, 1, 0, 0, 0, 255, 255, 255, 255]), recordIndex: Int64(UInt32.max))),
            .v18Aux(.init(rowId: 3, ts: 100, fields: Data([2, 2, 0, 0, 0, 1])))
        ]
    }
    private func batch(_ values: [PushBinaryRow], version: String = "1.4", limit: Int = 4_194_304) throws -> PushBinaryBatch {
        try PushProtocol.binaryObjectBatch(table: .v18AuxSample, sourceId: source, deviceId: device,
            startCursor: nil, rows: values, protocolVersion: version, decodedLimit: limit)
    }

    func testExactAuxiliaryFormatTwoGoldenPreservesSameSecondAndUnknownIndex() throws {
        let data = try PushBinaryCodec.pack(table: .v18AuxSample, rows: rows, v18IdentityV2: true)
        let expected = """
        4e504231020203000000
        0100000000000000640000000000000001000000000000000009000000020100000000000000
        0200000000000000640000000000000001ffffffff00000000090000000201000000ffffffff
        030000000000000064000000000000000006000000020200000001
        """.split(separator: "\n").joined()
        XCTAssertEqual(data.map { String(format: "%02x", $0) }.joined(), expected)
        let first = try batch(rows), retry = try batch(rows)
        XCTAssertEqual(first.contentSha256, PushBinaryCodec.sha256Hex(data))
        XCTAssertEqual(first.startTs, 100); XCTAssertEqual(first.endTs, 101); XCTAssertEqual(first.sampleCount, 3)
        XCTAssertEqual(first.batchId, retry.batchId); XCTAssertEqual(first.objectId, retry.objectId)
        XCTAssertEqual(first.payload, retry.payload)
        let fingerprints = try rows.map { try PushProtocol.binaryKeyFingerprint(table: .v18AuxSample,
            deviceId: device, row: $0, v18IdentityV2: true) }
        XCTAssertEqual(Set(fingerprints).count, 3)
        XCTAssertEqual(first.endCursor?.naturalKeyFingerprint, fingerprints.last)
        XCTAssertEqual(fingerprints.last, PushDurabilityReceipt.sha256(Data("v18AuxSample-v2\nfixture-device\n100\nunknown".utf8)))

        if let path = ProcessInfo.processInfo.environment["NOOP_EXPORT_AUX_FIXTURE"] {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent("payload.npb1"), options: .atomic)
            try first.payload.write(to: root.appendingPathComponent("payload.gz"), options: .atomic)
            try PushObjectManifest(batch: first).encode().write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
            try JSONSerialization.data(withJSONObject: ["fingerprints": fingerprints,
                "hex": expected, "schemaVersion": 2], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("golden.json"), options: .atomic)
        }
    }

    func testLegacyPrefixStopsAtKnownIndexWithoutSkippingItOrLosingOldBytes() throws {
        let unknown = PushBinaryRow.v18Aux(.init(rowId: 1, ts: 100, fields: Data([2, 2, 0, 0, 0, 1])))
        let known = PushBinaryRow.v18Aux(.init(rowId: 2, ts: 100, fields: Data([2, 1, 0, 0, 0, 1, 0, 0, 0]), recordIndex: 1))
        let following = PushBinaryRow.v18Aux(.init(rowId: 3, ts: 101, fields: Data([2, 2, 0, 0, 0, 2])))
        for version in ["1.1", "1.2", "1.3"] {
            let value = try batch([unknown, known, following], version: version)
            XCTAssertEqual(value.sampleCount, 1); XCTAssertEqual(value.endCursor?.rowId, 1)
            XCTAssertEqual(value.contentSha256, PushBinaryCodec.sha256Hex(try PushBinaryCodec.pack(table: .v18AuxSample, rows: [unknown])))
            XCTAssertThrowsError(try batch([known, following], version: version))
        }
        XCTAssertThrowsError(try PushBinaryCodec.pack(table: .v18AuxSample, rows: [known]))
    }

    func testActualPlausibleTimeFixtureForWholeReceiverIntake() throws {
        let plausible: [PushBinaryRow] = rows.map { row in
            guard case .v18Aux(let value) = row else { preconditionFailure("aux fixture") }
            return .v18Aux(.init(rowId: value.rowId, ts: 1_800_000_000, fields: value.fields, recordIndex: value.recordIndex))
        }
        let object = try batch(plausible)
        let packed = try PushBinaryCodec.pack(table: .v18AuxSample, rows: plausible, v18IdentityV2: true)
        XCTAssertEqual(object.sampleCount, 3)
        XCTAssertEqual(object.startTs, 1_800_000_000); XCTAssertEqual(object.endTs, 1_800_000_001)
        XCTAssertEqual(object.contentSha256, PushBinaryCodec.sha256Hex(packed))
        let fingerprints = try plausible.map { try PushProtocol.binaryKeyFingerprint(table: .v18AuxSample,
            deviceId: device, row: $0, v18IdentityV2: true) }
        XCTAssertEqual(Set(fingerprints).count, 3)
        if let path = ProcessInfo.processInfo.environment["NOOP_EXPORT_AUX_INTAKE_FIXTURE"] {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: root.path) else {
                throw PushProtocolException("fixture destination exists; use a fresh evidence directory")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try packed.write(to: root.appendingPathComponent("payload.npb1"), options: .atomic)
            try object.payload.write(to: root.appendingPathComponent("payload.gz"), options: .atomic)
            try PushObjectManifest(batch: object).encode().write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
            try JSONSerialization.data(withJSONObject: ["fingerprints": fingerprints,
                "hex": packed.map { String(format: "%02x", $0) }.joined(), "schemaVersion": 2], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("golden.json"), options: .atomic)
        }
    }

    func testAuxiliaryIdentityRangePrefixSizeAndWindowAreBounded() throws {
        for index: Int64 in [-1, Int64(UInt32.max) + 1] {
            XCTAssertThrowsError(try batch([.v18Aux(.init(rowId: 1, ts: 100, fields: Data([2]), recordIndex: index))]))
        }
        let firstSize = try PushBinaryCodec.packedRowSize(rows[0], v18IdentityV2: true)
        let one = try batch(rows, limit: 10 + firstSize)
        XCTAssertEqual(one.sampleCount, 1); XCTAssertEqual(one.endCursor?.rowId, 1)
        let outside = PushBinaryRow.v18Aux(.init(rowId: 2, ts: 100 + 172_800, fields: Data([2]), recordIndex: 2))
        let later = PushBinaryRow.v18Aux(.init(rowId: 3, ts: 100, fields: Data([2]), recordIndex: 3))
        let prefix = try batch([rows[0], outside, later])
        XCTAssertEqual(prefix.sampleCount, 1); XCTAssertEqual(prefix.endCursor?.rowId, 1)
        XCTAssertThrowsError(try batch([rows[1], rows[0]]))
    }

    func testPPGIdentityAndReceiptSchemaArePreservedUnderOnePointFour() throws {
        let values: [PushBinaryRow] = [.ppgWaveform(.init(rowId: 1, ts: 100, burstIndex: nil,
            samples: Data([1, 0]), recordIndex: 123))]
        let old = try PushProtocol.binaryObjectBatch(table: .ppgWaveformSample, sourceId: source, deviceId: device,
            startCursor: nil, rows: values, protocolVersion: "1.3")
        let new = try PushProtocol.binaryObjectBatch(table: .ppgWaveformSample, sourceId: source, deviceId: device,
            startCursor: nil, rows: values, protocolVersion: "1.4")
        XCTAssertEqual(new.contentSha256, old.contentSha256)
        XCTAssertEqual(new.payload, old.payload); XCTAssertEqual(new.endCursor, old.endCursor)
        XCTAssertEqual(PushProtocol.schemaVersion(stream: "ppgWaveformSample", protocolVersion: "1.4"), 2)
        XCTAssertEqual(PushProtocol.schemaVersion(stream: "v18AuxSample", protocolVersion: "1.4"), 2)
        XCTAssertEqual(PushProtocol.schemaVersion(stream: "v18AuxSample", protocolVersion: "1.3"), 1)
        XCTAssertEqual(PushProtocol.schemaVersion(stream: "rawImuSession", protocolVersion: "1.4"), 1)
    }

    func testScalarCapabilityNegotiationAndCompatibleHeaderVersions() throws {
        for version in ["1.0", "1.1", "1.2", "1.3", "1.4"] {
            let caps = try PushCapabilities.parse(JSONSerialization.data(withJSONObject: [
                "type": "capabilities", "protocolVersion": version,
                "receiverStateId": "00000000-0000-4000-8000-000000000099",
                "streams": ["stepSample", "sleepStateSample", "ppgHrSample", "unknownFuture"]]))
            XCTAssertEqual(caps.appendTables.count, version == "1.0" ? 0 : 3)
            for table in [PushAppendTable.stepSample, .sleepStateSample, .ppgHrSample] {
                let row = scalar(table)
                if version == "1.0" {
                    XCTAssertThrowsError(try PushProtocol.appendBatch(table: table, sourceId: source,
                        deviceId: device, startCursor: nil, records: [row], protocolVersion: version))
                } else {
                    let value = try PushProtocol.appendBatch(table: table, sourceId: source, deviceId: device,
                        startCursor: nil, records: [row], protocolVersion: version)
                    XCTAssertEqual(value.protocolVersion, version)
                    let header = try JSONSerialization.jsonObject(with: value.body.split(separator: 10).first!) as? [String: Any]
                    XCTAssertEqual(header?["protocolVersion"] as? String, version)
                    XCTAssertEqual(value.recordCount, 1)
                }
            }
        }
    }

    func testScalarValidationDoesNotCoerceBooleanNullOrOutOfRangeValues() throws {
        let invalid: [(PushAppendTable, String, PushJSONValue)] = [
            (.stepSample, "counter", .bool(true)), (.stepSample, "counter", .null),
            (.stepSample, "counter", .int(65536)), (.stepSample, "activityClass", .int(3)),
            (.sleepStateSample, "state", .int(4)), (.sleepStateSample, "rawByte", .int(0)),
            (.ppgHrSample, "bpm", .double(65.5)), (.ppgHrSample, "bpm", .int(0)),
            (.ppgHrSample, "conf", .double(1.1)), (.ppgHrSample, "conf", .bool(true))
        ]
        for (table, key, value) in invalid {
            let original = scalar(table)
            var fields = original.data; fields[key] = value
            XCTAssertThrowsError(try PushProtocol.appendBatch(table: table, sourceId: source, deviceId: device,
                startCursor: nil, records: [.init(rowId: 1, key: original.key, data: fields)], protocolVersion: "1.4"))
        }
    }

    func testKnownProvenanceCannotBeStrippedForAnOlderReceiver() throws {
        var fields = scalar(.stepSample).data
        fields["provenance"] = .map(["v": .int(1), "origin": .string("whoop-v18")])
        let row = PushAppendRecord(rowId: 1, key: ["ts": .int(100)], data: fields)
        XCTAssertThrowsError(try PushProtocol.appendBatch(table: .stepSample, sourceId: source, deviceId: device,
            startCursor: nil, records: [row], protocolVersion: "1.3"))
        let accepted = try PushProtocol.appendBatch(table: .stepSample, sourceId: source, deviceId: device,
            startCursor: nil, records: [row], protocolVersion: "1.4")
        XCTAssertTrue(String(decoding: accepted.body, as: UTF8.self).contains("whoop-v18"))
    }

    func testProvenanceRequiresExactTypesKnownSchemaAndCompleteObservedDerivation() throws {
        let hash = String(repeating: "a", count: 64)
        let derived: [String: PushJSONValue] = ["v": .int(1), "origin": .string("whoop-v26-ppg-derived"),
            "algorithm": .string("ppg-acf-v1"), "sampleRateHz": .int(25), "windowSettingSeconds": .int(8),
            "inputStartTs": .int(92), "inputEndTs": .int(101), "inputSHA256": .string(hash)]
        func encode(_ provenance: PushJSONValue) throws -> PushBatch {
            var fields = scalar(.ppgHrSample).data; fields["provenance"] = provenance
            return try PushProtocol.appendBatch(table: .ppgHrSample, sourceId: source, deviceId: device,
                startCursor: nil, records: [.init(rowId: 1, key: ["ts": .int(100)], data: fields)], protocolVersion: "1.4")
        }
        XCTAssertNoThrow(try encode(.map(derived)))
        XCTAssertNoThrow(try encode(.map(["v": .int(1), "origin": .string("legacy-unknown")])))
        XCTAssertNoThrow(try encode(.map(["v": .int(1), "origin": .string("whoop-v18"),
            "recordIndex": .int(Int64(UInt32.max)), "frameSHA256": .string(hash)])))
        let invalid: [(String, PushJSONValue)] = [
            ("v", .bool(true)), ("v", .double(1)), ("v", .int(2)), ("origin", .int(1)),
            ("origin", .string("future")), ("future", .int(1)), ("algorithm", .string("guessed")),
            ("sampleRateHz", .double(25)), ("sampleRateHz", .int(0)), ("windowSettingSeconds", .bool(true)),
            ("inputStartTs", .int(101)), ("inputEndTs", .int(9_007_199_254_740_992)),
            ("inputSHA256", .string(hash.uppercased())), ("inputSHA256", .string("a")),
            ("inputSHA256", .map([:])), ("recordIndex", .int(0)), ("frameSHA256", .string(hash)),
            ("inputStartTs", .null), ("origin", .string(String(repeating: "a", count: 1025)))
        ]
        for (key, value) in invalid {
            var changed = derived; changed[key] = value
            XCTAssertThrowsError(try encode(.map(changed)), key)
        }
        for key in derived.keys {
            var missing = derived; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try encode(.map(missing)), key)
        }
        for index in [Int64(-1), Int64(UInt32.max) + 1] {
            XCTAssertThrowsError(try encode(.map(["v": .int(1), "origin": .string("whoop-v18"), "recordIndex": .int(index)])))
        }
        XCTAssertThrowsError(try encode(.map(["v": .int(1), "origin": .string("legacy-unknown"), "recordIndex": .int(0)])))
        XCTAssertThrowsError(try encode(.map(["v": .int(1), "origin": .string("whoop-v18"), "algorithm": .string("ppg-acf-v1")])))
        XCTAssertThrowsError(try encode(.array([])))
        XCTAssertThrowsError(try encode(.string("{}")))
    }

    func testStoredProvenanceDecoderDoesNotCoerceJSONTypesOrDropMembers() throws {
        XCTAssertEqual(try PushProtocol.scalarProvenanceJSON(Data(#"{"v":1,"origin":"whoop-v18","recordIndex":0}"#.utf8)),
            .map(["v": .int(1), "origin": .string("whoop-v18"), "recordIndex": .int(0)]))
        for json in [#"{"v":true,"origin":"whoop-v18"}"#, #"{"v":1,"origin":"whoop-v18","recordIndex":true}"#,
                     #"{"v":1,"origin":"whoop-v18","recordIndex":"1"}"#, #"{"v":1,"origin":"whoop-v18","recordIndex":1.5}"#,
                     #"{"v":1,"origin":"whoop-v18","recordIndex":null}"#, #"{"v":1,"origin":"whoop-v18","nested":{}}"#,
                     #"{"v":1,"origin":"whoop-v18","future":[]}"#, "null", "[]", "{}", "false"] {
            XCTAssertThrowsError(try PushProtocol.scalarProvenanceJSON(Data(json.utf8)), json)
        }
    }

    func testInlineAcknowledgementNumbersAreTypedAndBounded() throws {
        func ack(rows: String = "1", cursor: String = "1") -> Data {
            Data("""
            {"protocolVersion":"1.4","batchId":"\(source)","stream":"stepSample","deviceId":"fixture-device","endCursor":{"rowId":\(cursor),"keySha256":"\(String(repeating: "a", count: 64))"},"acceptedRows":\(rows),"status":"accepted"}
            """.utf8)
        }
        XCTAssertEqual(try PushAck.parse(ack()).acceptedRows, 1)
        XCTAssertEqual(try PushAck.parse(ack(cursor: "9223372036854775807")).endCursor?.rowId, Int64.max)
        for invalid in ["true", "false", "null", "\"1\"", "-1", "1.5", "1e100", "9223372036854775808"] {
            XCTAssertThrowsError(try PushAck.parse(ack(cursor: invalid)), invalid)
            XCTAssertThrowsError(try PushAck.parse(ack(rows: invalid)), invalid)
        }
        XCTAssertThrowsError(try PushAck.parse(ack(rows: String(PushProtocolLimits.maxRecords + 1))))
    }

    func testActualScalarBodiesMatchAndroidGoldenVectors() throws {
        let hash = String(repeating: "a", count: 64)
        let tables: [PushAppendTable] = [.stepSample, .sleepStateSample, .ppgHrSample]
        let metadata: [[String: PushJSONValue]] = [
            ["v": .int(1), "origin": .string("whoop-v18"), "recordIndex": .int(4_294_967_295), "frameSHA256": .string(hash)],
            ["v": .int(1), "origin": .string("legacy-unknown")],
            ["v": .int(1), "origin": .string("whoop-v26-ppg-derived"), "algorithm": .string("ppg-acf-v1"),
             "sampleRateHz": .int(25), "windowSettingSeconds": .int(8), "inputStartTs": .int(92),
             "inputEndTs": .int(101), "inputSHA256": .string(hash)]
        ]
        let ids = ["0dfb4099-7fe3-584d-af1c-964d998bef3a", "6c4d130b-29a9-522a-97dd-bbbdf8fd65d4", "11c243e8-3013-54d0-91e4-121c01a95252"]
        let hashes = ["2632c3f890c5fd77f16bc8d1b7295dcdb39d5c05407a361be0165b25d9db8555",
                      "085e920304afca1a5e664a2966f047a9874562900e9a769c937c02b986c6a3cd",
                      "6bd50a151956e59b014aab9a2b0ea315b95973d183fb8804011bc07a4e918337"]
        let sizes = [577, 468, 652]
        let destination = ProcessInfo.processInfo.environment["NOOP_EXPORT_SCALAR_FIXTURE"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let destination {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw PushProtocolException("fixture destination exists; use a fresh evidence directory")
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        for (index, table) in tables.enumerated() {
            let base = scalar(table)
            var fields = base.data; fields["provenance"] = .map(metadata[index])
            let batch = try PushProtocol.appendBatch(table: table, sourceId: source, deviceId: device,
                startCursor: nil, records: [.init(rowId: base.rowId, key: base.key, data: fields)], protocolVersion: "1.4")
            XCTAssertEqual(batch.batchId, ids[index])
            XCTAssertEqual(PushDurabilityReceipt.sha256(batch.body), hashes[index])
            XCTAssertEqual(batch.body.count, sizes[index])
            if let destination {
                try batch.body.write(to: destination.appendingPathComponent(table.wireName + ".ndjson"), options: .atomic)
            }
        }
    }

    private func scalar(_ table: PushAppendTable) -> PushAppendRecord {
        let values: [String: PushJSONValue]
        switch table {
        case .stepSample: values = ["counter": .int(65535), "activityClass": .null]
        case .sleepStateSample: values = ["state": .int(2), "rawByte": .int(32)]
        case .ppgHrSample: values = ["bpm": .int(65), "conf": .null]
        default: preconditionFailure("scalar fixture only")
        }
        return .init(rowId: 1, key: ["ts": .int(100)], data: values)
    }
}
