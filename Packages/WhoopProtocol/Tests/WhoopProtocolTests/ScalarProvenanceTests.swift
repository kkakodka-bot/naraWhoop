import XCTest
import CryptoKit
@testable import WhoopProtocol

final class ScalarProvenanceTests: XCTestCase {
    func testLegacyModelsDecodeWithoutInventedProvenance() throws {
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(StepSample.self, from: Data(#"{"ts":1,"counter":65535}"#.utf8)).provenance)
        XCTAssertNil(try decoder.decode(SleepStateSample.self, from: Data(#"{"ts":1,"state":3}"#.utf8)).provenance)
        XCTAssertNil(try decoder.decode(PpgHrSample.self, from: Data(#"{"ts":1,"bpm":60,"conf":0.8}"#.utf8)).provenance)
        XCTAssertNil(try ScalarProvenance.decodeJSON(nil))
    }

    func testV18ExtractionCarriesOriginalFrameDigestAndIndexGolden() throws {
        let hex = "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"
        let characters = Array(hex)
        let bytes = stride(from: 0, to: characters.count, by: 2).map { UInt8(String(characters[$0...($0 + 1)]), radix: 16)! }
        let parsed = parseFrame(bytes, family: .whoop5)
        XCTAssertEqual(parsed.rawHex, "", "do not re-enable whole-frame hex allocation in the fast path")
        XCTAssertEqual(parsed.frameSHA256, "f33c461502c48aa493723f437268fbe88b2d08e25b7c73deedd427544b8a9ade")
        let streams = extractHistoricalStreams([parsed], deviceClockRef: 0, wallClockRef: 0)
        let expected = try ScalarProvenance(origin: .whoopV18, recordIndex: 25_443_699,
            frameSHA256: "f33c461502c48aa493723f437268fbe88b2d08e25b7c73deedd427544b8a9ade")
        XCTAssertEqual(try XCTUnwrap(streams.steps.first).provenance, expected)
        XCTAssertEqual(try XCTUnwrap(streams.sleepState.first).provenance, expected)
        XCTAssertEqual(try expected.canonicalJSON(),
            #"{"frameSHA256":"f33c461502c48aa493723f437268fbe88b2d08e25b7c73deedd427544b8a9ade","origin":"whoop-v18","recordIndex":25443699,"v":1}"#)
    }

    func testPpgInputBytesAndHashCrossPlatformGolden() throws {
        let records = [PpgWaveformSample(ts: 100, samples: [-32768, 0, 32767], recordIndex: 0),
                       PpgWaveformSample(ts: 101, samples: [7, -7])]
        let bytes = try ScalarProvenance.ppgInputBytes(records)
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(),
            "77312d7070672d696e7075742d76310a0200000064000000000000000100000000000000000300000000800000ff7f650000000000000000020000000700f9ff")
        let value = try XCTUnwrap(ScalarProvenance.derivedPPG(records, fs: 24, windowSeconds: 8, subLagInterp: false))
        XCTAssertEqual(value.inputSHA256, "c0c4d0701eb3741fd07bd4a62d2cc23f6caccc91819f927e7df30ab07ef66ac4")
        XCTAssertEqual(value.inputStartTs, 100)
        XCTAssertEqual(value.inputEndTs, 102)
        XCTAssertEqual(try ScalarProvenance.decodeJSON(value.canonicalJSON()), value)
        XCTAssertThrowsError(try ScalarProvenance.ppgInputBytes(records.reversed()))
        XCTAssertThrowsError(try ScalarProvenance.ppgInputBytes([PpgWaveformSample(ts: 1, samples: [32768])]))
    }

    func testPpgDerivationRecordsActualDuplicateSelectionEdgesAndAlgorithm() throws {
        var inputs: [PpgWaveformSample] = []
        for s in 0..<11 {
            let samples: [Int] = (0..<24).map { offset in
                let phase = Double(s * 24 + offset) / 24.0
                return Int(1000.0 * sin(2.0 * Double.pi * (70.0 / 60.0) * phase))
            }
            inputs.append(PpgWaveformSample(ts: 100 + s, samples: samples, recordIndex: s))
        }
        let replacement = PpgWaveformSample(ts: 105, samples: inputs[5].samples, recordIndex: 777)
        inputs.append(replacement)
        let estimates = PpgHr.derivePpgHr(waveforms: inputs)
        let center = try XCTUnwrap(estimates.first { $0.ts == 105 }?.provenance)
        XCTAssertEqual(center.inputStartTs, 101)
        XCTAssertEqual(center.inputEndTs, 110, "the inclusive eight-second setting uses nine records")
        var selected = Array(inputs[1...9]); selected[4] = replacement
        XCTAssertEqual(center, ScalarProvenance.derivedPPG(selected, fs: 24, windowSeconds: 8, subLagInterp: false))
        let edge = try XCTUnwrap(estimates.first?.provenance)
        XCTAssertEqual(edge.inputStartTs, 100)
        XCTAssertEqual(edge.inputEndTs, 105)
        let interpolated = try XCTUnwrap(PpgHr.derivePpgHr(waveforms: inputs, subLagInterp: true)
            .first { $0.ts == 105 }?.provenance)
        XCTAssertEqual(interpolated.algorithm, .ppgACFSubLag)
        XCTAssertEqual(interpolated.inputSHA256, center.inputSHA256)
        XCTAssertEqual(center.algorithm, .ppgACF)
        XCTAssertEqual(center.inputSelection, .lastRecordPerSecond)
    }

    func testSelectionIsOptionalForLegacyAndStrictlyDerivedOnly() throws {
        let base: [String: Any] = ["v": 1, "origin": "whoop-v26-ppg-derived", "algorithm": "ppg-acf-v1",
            "sampleRateHz": 24, "windowSettingSeconds": 8, "inputStartTs": 100, "inputEndTs": 102,
            "inputSHA256": String(repeating: "a", count: 64)]
        func decode(_ object: [String: Any]) throws -> ScalarProvenance? {
            try ScalarProvenance.decodeJSON(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }
        XCTAssertNil(try decode(base)?.inputSelection)
        for selection in [ScalarProvenance.InputSelection.lastRecordPerSecond, .concatenateRecordsPerSecond] {
            var value = base; value["inputSelection"] = selection.rawValue
            XCTAssertEqual(try decode(value)?.inputSelection, selection)
            for origin in ["whoop-v18", "legacy-unknown"] {
                XCTAssertThrowsError(try decode(["v": 1, "origin": origin, "inputSelection": selection.rawValue]))
            }
        }
        let invalidValues: [Any] = [NSNull(), 1, true, "", "unknown", ["last-record-per-second-v1"]]
        for invalid in invalidValues {
            var value = base; value["inputSelection"] = invalid
            XCTAssertThrowsError(try decode(value))
        }
    }

    func testDuplicateFramingRetainsRecordBoundariesAndEncounterOrder() throws {
        let a = PpgWaveformSample(ts: 100, samples: [-32768, 7], recordIndex: 0)
        let b = PpgWaveformSample(ts: 100, samples: [32767, -7], recordIndex: Int(UInt32.max))
        let c = PpgWaveformSample(ts: 101, samples: [1])
        let bytes = try ScalarProvenance.ppgInputBytes([a, b, c])
        XCTAssertNotEqual(bytes, try ScalarProvenance.ppgInputBytes([b, a, c]))
        XCTAssertNotEqual(bytes, try ScalarProvenance.ppgInputBytes([
            PpgWaveformSample(ts: 100, samples: a.samples + b.samples), c]))
        XCTAssertThrowsError(try ScalarProvenance.ppgInputBytes([c, a, b]))
        XCTAssertEqual(try ScalarProvenance.ppgInputBytes([a, b, c]), bytes)
    }

    func testUnknownVersionFieldsInvalidTypesAndOversizeFailClosed() throws {
        for json in [
            #"{"v":2,"origin":"whoop-v18"}"#,
            #"{"v":1,"origin":"whoop-v18","extra":1}"#,
            #"{"v":true,"origin":"whoop-v18"}"#,
            #"{"v":1,"origin":"whoop-v18","recordIndex":-1}"#,
            #"{"v":1,"origin":"whoop-v18","recordIndex":4294967296}"#,
            #"{"v":1,"origin":"whoop-v18","recordIndex":"1"}"#,
            #"{"v":1,"origin":"whoop-v26-ppg-derived"}"#,
            #"{"v":1,"origin":"legacy-unknown","recordIndex":0}"#
        ] { XCTAssertThrowsError(try ScalarProvenance.decodeJSON(json), json) }
        XCTAssertThrowsError(try ScalarProvenance.decodeJSON(String(repeating: " ", count: 1025)))
    }

    func testExplicitNullForEveryKnownMemberIsRejectedButAbsentOptionalsRemainValid() throws {
        let digest = String(repeating: "a", count: 64)
        let objects: [[String: Any]] = [
            ["v": 1, "origin": "whoop-v18"],
            ["v": 1, "origin": "legacy-unknown"],
            ["v": 1, "origin": "whoop-v26-ppg-derived", "algorithm": "ppg-acf-v1",
             "sampleRateHz": 24, "windowSettingSeconds": 8, "inputStartTs": -1,
             "inputEndTs": 1, "inputSHA256": digest]
        ]
        let keys = ["v", "origin", "recordIndex", "frameSHA256", "algorithm", "sampleRateHz",
                    "windowSettingSeconds", "inputStartTs", "inputEndTs", "inputSHA256", "inputSelection"]
        for object in objects {
            let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            XCTAssertNotNil(try ScalarProvenance.decodeJSON(String(decoding: original, as: UTF8.self)))
            for key in keys {
                var invalid = object
                invalid[key] = NSNull()
                let bytes = try JSONSerialization.data(withJSONObject: invalid, options: [.sortedKeys])
                XCTAssertThrowsError(try ScalarProvenance.decodeJSON(String(decoding: bytes, as: UTF8.self)), key)
            }
        }
    }

    func testJSONSafeIntegerBoundariesRoundTripWithoutChangingValues() throws {
        let limit = 9_007_199_254_740_991
        let intervals = [(-limit, -limit + 1), (-1, 0), (0, 1), (limit - 1, limit), (-limit, limit)]
        for rate in [1, limit] {
            for window in [1, limit] {
                for (start, end) in intervals {
                    let value = try ScalarProvenance(origin: .whoopV26PpgDerived, algorithm: .ppgACF,
                        sampleRateHz: rate, windowSettingSeconds: window, inputStartTs: start,
                        inputEndTs: end, inputSHA256: String(repeating: "a", count: 64))
                    let json = try value.canonicalJSON()
                    XCTAssertTrue(json.contains("\"sampleRateHz\":\(rate)"))
                    XCTAssertTrue(json.contains("\"windowSettingSeconds\":\(window)"))
                    XCTAssertTrue(json.contains("\"inputStartTs\":\(start)"))
                    XCTAssertTrue(json.contains("\"inputEndTs\":\(end)"))
                    XCTAssertEqual(try ScalarProvenance.decodeJSON(json), value)
                }
            }
        }
    }

    func testUnsafeIntegersNonpositiveSettingsAndUnorderedBoundsAreRejected() throws {
        let limit = 9_007_199_254_740_991
        let digest = String(repeating: "a", count: 64)
        func derived(rate: Int = 24, window: Int = 8, start: Int = -1, end: Int = 1) throws -> ScalarProvenance {
            try ScalarProvenance(origin: .whoopV26PpgDerived, algorithm: .ppgACF,
                sampleRateHz: rate, windowSettingSeconds: window, inputStartTs: start,
                inputEndTs: end, inputSHA256: digest)
        }
        let constructors: [(String, (Int) throws -> ScalarProvenance)] = [
            ("v", { try ScalarProvenance(v: $0, origin: .whoopV18) }),
            ("recordIndex", { try ScalarProvenance(origin: .whoopV18, recordIndex: $0) }),
            ("sampleRateHz", { try derived(rate: $0) }),
            ("windowSettingSeconds", { try derived(window: $0) }),
            ("inputStartTs", { try derived(start: $0, end: $0 + 1) }),
            ("inputEndTs", { try derived(start: $0 - 1, end: $0) })
        ]
        for invalid in [-limit - 1, limit + 1] {
            for (key, construct) in constructors {
                XCTAssertThrowsError(try construct(invalid), key)
                var object: [String: Any] = ["v": 1, "origin": "whoop-v26-ppg-derived",
                    "algorithm": "ppg-acf-v1", "sampleRateHz": 24, "windowSettingSeconds": 8,
                    "inputStartTs": -1, "inputEndTs": 1, "inputSHA256": digest]
                if key == "inputStartTs" { object["inputEndTs"] = invalid + 1 }
                if key == "inputEndTs" { object["inputStartTs"] = invalid - 1 }
                object[key] = invalid
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                XCTAssertThrowsError(try ScalarProvenance.decodeJSON(String(decoding: bytes, as: UTF8.self)), key)
            }
        }
        for invalid in [Int.min, -1, 0, Int.max] {
            XCTAssertThrowsError(try derived(rate: invalid))
            XCTAssertThrowsError(try derived(window: invalid))
        }
        XCTAssertThrowsError(try derived(start: Int.min, end: 0))
        XCTAssertThrowsError(try derived(start: 0, end: Int.max))
        XCTAssertThrowsError(try derived(start: 1, end: 1))
        XCTAssertThrowsError(try derived(start: 2, end: 1))
    }
}
