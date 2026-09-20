import XCTest
@testable import NoopPush

final class PushSenderBoundaryTests: XCTestCase {
    private let sourceID = "00000000-0000-4000-8000-000000000001"
    private let base: Int64 = 1_790_000_000

    private func capabilities(_ version: String, validLane: Bool = true) throws -> PushCapabilities {
        try PushCapabilities.parse(JSONSerialization.data(withJSONObject: [
            "type": "capabilities", "protocolVersion": version,
            "receiverStateId": sourceID, "streams": ["ppgWaveformSample"],
            "objectLane": ["endpoint": validLane ? "/api/push/objects" : "https://invalid.example/objects",
                           "maxObjectBytes": PushProtocolLimits.maxObjectWireBytes,
                           "streams": ["ppgWaveformSample"]],
        ]))
    }

    private func row(_ table: PushBinaryTable, id: Int64, ts: Int64, index: Int64? = nil) -> PushBinaryRow {
        switch table {
        case .ppgWaveformSample:
            return .ppgWaveform(.init(rowId: id, ts: ts, burstIndex: nil,
                                      samples: Data([1, 2]), recordIndex: index))
        case .v18AuxSample: return .v18Aux(.init(rowId: id, ts: ts, fields: Data([3, 4])))
        case .rawImuSession:
            return .rawImuSession(.init(rowId: id, ts: ts, columns: Data(count: PushBinaryCodec.imuRecordPayloadBytes)))
        case .rawBatch: fatalError("use raw fixture")
        }
    }

    private func batch(_ table: PushBinaryTable, _ rows: [PushBinaryRow], version: String = "1.3",
                       limit: Int = PushProtocolLimits.maxObjectDecodedBytes) throws -> PushBinaryBatch {
        try PushProtocol.binaryObjectBatch(table: table, sourceId: sourceID, deviceId: "fixture-device",
                                          startCursor: nil, rows: rows, protocolVersion: version, decodedLimit: limit)
    }

    func testNegotiatedIdentityVersionAndLegacyFallback() throws {
        XCTAssertEqual(PushProtocol.capabilitiesAcceptVersions, "1.4,1.3,1.2,1.1,1.0")
        XCTAssertEqual(PushProtocol.objectVersion, "1.2")
        XCTAssertEqual(PushProtocol.identityObjectVersion, "1.3")
        let upgraded = try capabilities("1.3")
        XCTAssertEqual(upgraded.objectLane?.streams, [.ppgWaveformSample])
        let known = [row(.ppgWaveformSample, id: 1, ts: base, index: 11),
                     row(.ppgWaveformSample, id: 2, ts: base, index: 12),
                     row(.ppgWaveformSample, id: 3, ts: base)]
        let v2 = try batch(.ppgWaveformSample, known, version: upgraded.protocolVersion)
        XCTAssertEqual(v2.sampleCount, 3)
        XCTAssertEqual(v2.endCursor?.rowId, 3)
        XCTAssertEqual(v2.contentSha256, PushBinaryCodec.sha256Hex(
            try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: known, ppgIdentityV2: true)))
        let legacy = try capabilities("1.2")
        XCTAssertNotNil(legacy.objectLane)
        XCTAssertThrowsError(try batch(.ppgWaveformSample, known, version: legacy.protocolVersion))
        let unknown = [row(.ppgWaveformSample, id: 1, ts: base)]
        let v1 = try batch(.ppgWaveformSample, unknown, version: legacy.protocolVersion)
        XCTAssertEqual(v1.contentSha256, PushBinaryCodec.sha256Hex(
            try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: unknown)))
        XCTAssertNil(try capabilities("1.3", validLane: false).objectLane)
        XCTAssertEqual(try capabilities("1.4").protocolVersion, "1.4")
        XCTAssertThrowsError(try capabilities("1.5"))
    }

    func testExactFortyEightHourHalfOpenBoundaryForPpgAndAux() throws {
        for table in [PushBinaryTable.ppgWaveformSample, .v18AuxSample] {
            let rows = [row(table, id: 1, ts: base),
                        row(table, id: 2, ts: base + 172_799),
                        row(table, id: 3, ts: base + 172_800)]
            for version in ["1.2", "1.3"] {
                let result = try batch(table, rows, version: version)
                XCTAssertEqual(result.sampleCount, 2)
                XCTAssertEqual(result.startTs, base)
                XCTAssertEqual(result.endTs, base + 172_800)
                XCTAssertEqual(result.endCursor?.rowId, 2)
            }
        }
    }

    func testOutOfOrderTimestampsNeverSkipAnInterveningRowID() throws {
        for table in [PushBinaryTable.ppgWaveformSample, .v18AuxSample] {
            let rows = [row(table, id: 1, ts: base + 10), row(table, id: 2, ts: base),
                        row(table, id: 3, ts: base + 172_800), row(table, id: 4, ts: base + 11)]
            let first = try batch(table, rows)
            let retry = try batch(table, rows)
            XCTAssertEqual(first.sampleCount, 2)
            XCTAssertEqual(first.endCursor?.rowId, 2)
            XCTAssertEqual(first.objectId, retry.objectId)
            XCTAssertEqual(first.manifestJSON, retry.manifestJSON)
            let next = try batch(table, Array(rows.dropFirst(first.sampleCount)))
            XCTAssertEqual(next.sampleCount, 2)
            XCTAssertEqual(next.endCursor?.rowId, 4)
        }
    }

    func testSparseBacklogAdvancesOnlyContiguousPrefixes() throws {
        for table in [PushBinaryTable.ppgWaveformSample, .v18AuxSample] {
            let rows = [row(table, id: 1, ts: base), row(table, id: 2, ts: base + 259_200),
                        row(table, id: 3, ts: base + 1)]
            for offset in 0..<rows.count {
                let result = try batch(table, Array(rows.dropFirst(offset)))
                XCTAssertEqual(result.sampleCount, 1)
                XCTAssertEqual(result.endCursor?.rowId, Int64(offset + 1))
            }
        }
    }

    func testByteLimitAndRowIDValidationDoNotReorder() throws {
        let first = row(.ppgWaveformSample, id: 1, ts: base)
        let second = row(.ppgWaveformSample, id: 2, ts: base)
        let oneRowBytes = PushBinaryCodec.packedHeaderSize(for: .ppgWaveformSample)
            + (try PushBinaryCodec.packedRowSize(first, ppgIdentityV2: true))
        let result = try batch(.ppgWaveformSample, [first, second], limit: oneRowBytes)
        XCTAssertEqual(result.sampleCount, 1)
        XCTAssertEqual(result.endCursor?.rowId, 1)
        XCTAssertThrowsError(try batch(.ppgWaveformSample, [second, first]))
        XCTAssertThrowsError(try batch(.ppgWaveformSample, [first, first]))
        XCTAssertThrowsError(try batch(.ppgWaveformSample, [first], limit: Int.min))
        XCTAssertThrowsError(try batch(.ppgWaveformSample, [row(.v18AuxSample, id: 1, ts: base)]))
        XCTAssertThrowsError(try batch(.ppgWaveformSample, [row(.ppgWaveformSample, id: 1, ts: .max)]))
    }

    func testImuStillUsesOneHourAcrossReversedTimestamps() throws {
        let rows = [row(.rawImuSession, id: 1, ts: base + 3_600), row(.rawImuSession, id: 2, ts: base)]
        let result = try batch(.rawImuSession, rows)
        XCTAssertEqual(result.sampleCount, 1)
        XCTAssertEqual(result.endCursor?.rowId, 1)
    }

    private func raw(start: Int64, end: Int64, count: Int32 = 1) -> PushBinaryRow {
        .rawBatch(.init(rowId: 1, batchId: "stable-raw", capturedAt: base,
                       deviceClockRef: base, wallClockRef: base,
                       startTs: start, endTs: end, frameCount: count, byteSize: 2, framesBlob: Data([1, 2])))
    }

    func testEqualRawBoundsNormalizeManifestWithoutRewritingPayload() throws {
        for count in [Int32(0), Int32(1)] {
            for version in ["1.2", "1.3"] {
                let rows = [raw(start: base, end: base, count: count)]
                let first = try batch(.rawBatch, rows, version: version)
                let retry = try batch(.rawBatch, rows, version: version)
                XCTAssertEqual(first.startTs, base)
                XCTAssertEqual(first.endTs, base + 1)
                XCTAssertEqual(first.contentSha256, PushBinaryCodec.sha256Hex(
                    try PushBinaryCodec.pack(table: .rawBatch, rows: rows)))
                XCTAssertEqual(first.objectId, retry.objectId)
                XCTAssertEqual(first.manifestJSON, retry.manifestJSON)
                XCTAssertEqual(first.payload, retry.payload)
            }
        }
    }

    func testRawPositiveBoundsRetainCompatibilityAndInvalidBoundsFailClosed() throws {
        let result = try batch(.rawBatch, [raw(start: base, end: base + 172_800)])
        XCTAssertEqual(result.endTs, base + 172_800)
        XCTAssertThrowsError(try batch(.rawBatch, [raw(start: base, end: base - 1)]))
        XCTAssertThrowsError(try batch(.rawBatch, [raw(start: base, end: base + 172_801)]))
        XCTAssertThrowsError(try batch(.rawBatch, [raw(start: .max, end: .max)]))
        XCTAssertThrowsError(try batch(.rawBatch, [raw(start: .min, end: .max)]))
    }
}
