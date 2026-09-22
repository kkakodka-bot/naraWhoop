import Foundation
import CryptoKit
import XCTest
@testable import WhoopProtocol

final class ScalarProvenanceWordSizeTests: XCTestCase {
    private let jsonSafeLimit: Int64 = 9_007_199_254_740_991
    private let digest = String(repeating: "a", count: 64)

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Array($0) }
    }

    private func assertInvalid<T>(_ operation: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? ScalarProvenanceError, .invalidValue, file: file, line: line)
        }
    }

    func testObservedIndexKeepsExactUInt32DomainWithinPlatformInt() throws {
        let upper = try XCTUnwrap(Int(exactly: min(Int64(Int.max), Int64(UInt32.max))))
        for index in [0, Int(Int32.max), upper] {
            let value = try ScalarProvenance(origin: .whoopV18, recordIndex: index, frameSHA256: digest)
            let expected = "{\"frameSHA256\":\"\(digest)\",\"origin\":\"whoop-v18\",\"recordIndex\":\(index),\"v\":1}"
            XCTAssertEqual(try value.canonicalJSON(), expected)
            XCTAssertEqual(try ScalarProvenance.decodeJSON(expected), value)
        }
        for index in [Int.min, -1] {
            assertInvalid { try ScalarProvenance(origin: .whoopV18, recordIndex: index) }
        }
        if let aboveUInt32 = Int(exactly: Int64(UInt32.max) + 1) {
            assertInvalid { try ScalarProvenance(origin: .whoopV18, recordIndex: aboveUInt32) }
        }
        XCTAssertThrowsError(try ScalarProvenance.decodeJSON(#"{"v":1,"origin":"whoop-v18","recordIndex":4294967296}"#))
    }

    func testRecordAndSampleCountsAndIndexKeepExactWireWidths() throws {
        let upper = try XCTUnwrap(Int(exactly: min(Int64(Int.max), Int64(UInt32.max))))
        for index in [0, Int(Int32.max), upper] {
            let record = PpgWaveformSample(ts: 1, samples: [-32768, 0, 32767], recordIndex: index)
            var expected = Array("w1-ppg-input-v1\n".utf8)
            expected += littleEndian(UInt32(1))
            expected += littleEndian(Int64(1))
            expected.append(1)
            expected += littleEndian(Int64(index))
            expected += littleEndian(UInt32(3))
            expected += [0x00, 0x80, 0x00, 0x00, 0xff, 0x7f]
            XCTAssertEqual(try ScalarProvenance.ppgInputBytes([record]), Data(expected))
        }
        assertInvalid { try ScalarProvenance.ppgInputBytes([]) }
        for index in [Int.min, -1] {
            assertInvalid { try ScalarProvenance.ppgInputBytes([PpgWaveformSample(ts: 1, samples: [], recordIndex: index)]) }
        }
        if let aboveUInt32 = Int(exactly: Int64(UInt32.max) + 1) {
            assertInvalid { try ScalarProvenance.ppgInputBytes([PpgWaveformSample(ts: 1, samples: [], recordIndex: aboveUInt32)]) }
        }
    }

    func testFramingSignExtendsTimestampAndPreservesAbsentIndexAndEmptySamples() throws {
        let records = [PpgWaveformSample(ts: Int.min, samples: []), PpgWaveformSample(ts: Int.max, samples: [])]
        var expected = Array("w1-ppg-input-v1\n".utf8)
        expected += littleEndian(UInt32(2))
        for ts in [Int.min, Int.max] {
            expected += littleEndian(Int64(ts))
            expected.append(0)
            expected += littleEndian(UInt32(0))
        }
        XCTAssertEqual(try ScalarProvenance.ppgInputBytes(records), Data(expected))
        assertInvalid { try ScalarProvenance.ppgInputBytes(records.reversed()) }
    }

    func testJSONSafeBoundsRetainAllRepresentableSignedValuesWithoutNarrowing() throws {
        let lower = try XCTUnwrap(Int(exactly: max(Int64(Int.min), -jsonSafeLimit)))
        let upper = try XCTUnwrap(Int(exactly: min(Int64(Int.max), jsonSafeLimit)))
        for (start, end) in [(lower, lower + 1), (-1, 0), (upper - 1, upper), (lower, upper)] {
            let value = try ScalarProvenance(origin: .whoopV26PpgDerived, algorithm: .ppgACF,
                sampleRateHz: upper, windowSettingSeconds: upper, inputStartTs: start, inputEndTs: end,
                inputSHA256: digest, inputSelection: .lastRecordPerSecond)
            let json = try value.canonicalJSON()
            XCTAssertTrue(json.contains("\"sampleRateHz\":\(upper)"))
            XCTAssertTrue(json.contains("\"windowSettingSeconds\":\(upper)"))
            XCTAssertTrue(json.contains("\"inputStartTs\":\(start)"))
            XCTAssertTrue(json.contains("\"inputEndTs\":\(end)"))
            XCTAssertEqual(try ScalarProvenance.decodeJSON(json), value)
        }
        for unsafe in [-jsonSafeLimit - 1, jsonSafeLimit + 1] {
            if let representable = Int(exactly: unsafe) {
                assertInvalid {
                    try ScalarProvenance(origin: .whoopV26PpgDerived, algorithm: .ppgACF,
                        sampleRateHz: representable, windowSettingSeconds: 1, inputStartTs: -1, inputEndTs: 0,
                        inputSHA256: digest)
                }
            }
            let json = "{\"v\":1,\"origin\":\"whoop-v26-ppg-derived\",\"algorithm\":\"ppg-acf-v1\",\"sampleRateHz\":\(unsafe),\"windowSettingSeconds\":1,\"inputStartTs\":-1,\"inputEndTs\":0,\"inputSHA256\":\"\(digest)\"}"
            XCTAssertThrowsError(try ScalarProvenance.decodeJSON(json))
        }
    }

    func testLegacyHexLengthRejectsOverflowingAndMalformedCountsWithoutAllocating() throws {
        func frame(_ length: Int, _ hex: String) -> ParsedFrame {
            ParsedFrame(ok: true, typeName: "historical", seq: nil, cmdName: nil, crcOK: nil,
                lenBytes: length, rawHex: hex, fields: [], parsed: ["hist_version": .int(18), "record_index": .int(0)])
        }
        for length in [Int.min, -1, 0, 1, 3, Int.max / 2 + 1, Int.max] {
            XCTAssertNil(ScalarProvenance.observedV18(frame(length, "aBcd")))
        }
        for hex in ["", "a", "abc", "abcde", "agcd"] {
            XCTAssertNil(ScalarProvenance.observedV18(frame(2, hex)))
        }
        let frameDigest = SHA256.hash(data: Data([0xab, 0xcd])).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ScalarProvenance.observedV18(frame(2, "aBcd")),
            try ScalarProvenance(origin: .whoopV18, recordIndex: 0, frameSHA256: frameDigest))
    }

    func testDerivedEndGuardStillRefusesIntMaxAndPreservesSafeUpperBoundary() throws {
        let upper = try XCTUnwrap(Int(exactly: min(Int64(Int.max) - 1, jsonSafeLimit - 1)))
        let records = [PpgWaveformSample(ts: upper, samples: [1], recordIndex: 0)]
        let value = try XCTUnwrap(ScalarProvenance.derivedPPG(records, fs: 24, windowSeconds: 8, subLagInterp: false))
        XCTAssertEqual(value.inputStartTs, upper)
        XCTAssertEqual(value.inputEndTs, upper + 1)
        XCTAssertEqual(try ScalarProvenance.decodeJSON(value.canonicalJSON()), value)
        XCTAssertNil(ScalarProvenance.derivedPPG([PpgWaveformSample(ts: Int.max, samples: [1])],
            fs: 24, windowSeconds: 8, subLagInterp: false))
    }
}
