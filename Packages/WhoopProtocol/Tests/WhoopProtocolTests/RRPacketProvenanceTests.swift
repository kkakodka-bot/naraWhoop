import XCTest
@testable import WhoopProtocol

final class RRPacketProvenanceTests: XCTestCase {
    struct Oracle: Decodable {
        struct Case: Decodable { let hex: String; let packetId: String; let sensorTs: Int; let recordIndex: Int; let rawTicks: [Int]; let wordIndices: [Int]; let rrMs: [Int] }
        let cases: [Case]
    }
    func testSharedPacketIdentityAndZeroWordPositionsSurviveHotDecoderAndStreams() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rr_packet_provenance_oracle", withExtension: "json"))
        for c in try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url)).cases {
            let bytes = try XCTUnwrap(RRPacketProvenance.bytes(c.hex))
            let frame = parseFrame(bytes, family: .whoop5, collectFields: false)
            XCTAssertTrue(frame.rawHex.isEmpty, "diagnostic strings remain off on the hot path")
            let packet = try XCTUnwrap(frame.rrPacketProvenance)
            XCTAssertEqual(packet.packetId, c.packetId); XCTAssertEqual(packet.sensorTs, c.sensorTs)
            XCTAssertEqual(packet.recordIndex, c.recordIndex); XCTAssertEqual(packet.rawHex, c.hex)
            XCTAssertEqual(packet.words.map(\.index), c.wordIndices)
            XCTAssertEqual(packet.words.map(\.rawTicks), c.rawTicks); XCTAssertEqual(packet.words.map(\.rrMs), c.rrMs)
            let streams = extractHistoricalStreams([frame], deviceClockRef: 0, wallClockRef: 0)
            XCTAssertEqual(streams.rrPackets, [packet])
            XCTAssertEqual(try JSONDecoder().decode(Streams.self, from: JSONEncoder().encode(streams)), streams)
            var corrupt = bytes; corrupt[24] ^= 1
            XCTAssertNil(RRPacketProvenance.checked(corrupt))
            var header = bytes; header[4] ^= 1
            let crc = crc16Modbus(Array(header[0..<6])); header[6] = UInt8(crc & 255); header[7] = UInt8(crc >> 8)
            XCTAssertEqual(RRPacketProvenance.checked(header)?.packetId, packet.packetId, "transport envelope is not sensor identity")
            let remapped = try XCTUnwrap(packet.mapped(to: packet.ts + 300))
            XCTAssertEqual(remapped.packetId, packet.packetId); XCTAssertEqual(remapped.sensorTs, packet.sensorTs)
            XCTAssertEqual(remapped.timestampPrecisionSeconds, 300); XCTAssertEqual(remapped.clockOffsetSeconds, 300)
        }
    }
}
