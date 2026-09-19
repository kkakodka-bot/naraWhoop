import XCTest
@testable import NoopPush

final class PortableZstdTests: XCTestCase {
    /// The reference decoder is deliberately independent of the frame writer under test.
    private func referenceDecode(_ frame: Data) throws -> Data {
        #if os(macOS)
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("Requires the independent zstd CLI for portable-frame interoperability")
        }
        // Foundation's macOS temporaryDirectory can ignore TMPDIR. Keep the 64 MiB
        // reference fixtures on an explicitly selected test volume when host storage is full.
        let temporaryRoot = ProcessInfo.processInfo.environment["NOOP_TEST_TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = temporaryRoot.appendingPathComponent("portable-zstd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.zst")
        let output = directory.appendingPathComponent("output.bin")
        try frame.write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--decompress", "--quiet", input.path, "-o", output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: output)
        #else
        throw XCTSkip("The independent CLI decoder runs on the macOS test host")
        #endif
    }

    func testPortableFramesRoundTripEmptyAndBlockBoundariesWithReferenceDecoder() throws {
        for count in [0, 1, 255, 256, 65_535, 65_536, 131_071, 131_072, 131_073, 4 * 1024 * 1024] {
            let source = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 37) })
            let frame = try PushBinaryCompression.zstdRawFrame(source,
                maxDecoded: PushProtocolLimits.maxBodyBytes, maxWire: PushProtocolLimits.maxWireBodyBytes)
            XCTAssertEqual(try referenceDecode(frame), source, "\(count) bytes")
            XCTAssertEqual(try PushBinaryCompression.zstdRawFrame(source,
                maxDecoded: PushProtocolLimits.maxBodyBytes, maxWire: PushProtocolLimits.maxWireBodyBytes), frame)
        }
    }

    func testPortableMaximumObjectRoundTripsAndHonorsWireAndDecodedLimits() throws {
        let source = Data(repeating: 0xa5, count: PushProtocolLimits.maxObjectDecodedBytes)
        let frame = try PushBinaryCompression.zstdRawFrame(source,
            maxDecoded: PushProtocolLimits.maxObjectDecodedBytes, maxWire: PushProtocolLimits.maxObjectWireBytes)
        XCTAssertEqual(try referenceDecode(frame), source)
        XCTAssertThrowsError(try PushBinaryCompression.zstdRawFrame(source,
            maxDecoded: source.count - 1, maxWire: PushProtocolLimits.maxObjectWireBytes))
        XCTAssertThrowsError(try PushBinaryCompression.zstdRawFrame(source,
            maxDecoded: source.count, maxWire: frame.count - 1))
        XCTAssertEqual(try PushBinaryCompression.zstdRawFrame(source,
            maxDecoded: source.count, maxWire: frame.count), frame)
    }

    func testPortableFramesRetainSharedBinaryFixturesAndIdentity() throws {
        let imuColumns = Data((0..<600).flatMap { value -> [UInt8] in
            let sample = Int16(value - 1)
            return [UInt8(truncatingIfNeeded: sample), UInt8(truncatingIfNeeded: sample >> 8)]
        })
        let fixtures: [(PushBinaryTable, [PushBinaryRow])] = [
            (.rawImuSession, [.rawImuSession(PushRawImuRecord(rowId: 1_700_000_000, ts: 1_700_000_000, columns: imuColumns))]),
            (.rawBatch, [.rawBatch(PushRawBatchRecord(rowId: 1, batchId: "batch-1", capturedAt: 100,
                deviceClockRef: 90, wallClockRef: 100, startTs: 100, endTs: 200,
                frameCount: 2, byteSize: 4, framesBlob: Data([1, 2, 3, 4])))]),
            (.ppgWaveformSample, [
                .ppgWaveform(PushPpgWaveformRecord(rowId: 10, ts: 100, burstIndex: 2, samples: Data([1, 2]), recordIndex: 10)),
                .ppgWaveform(PushPpgWaveformRecord(rowId: 11, ts: 100, burstIndex: 2, samples: Data([3, 4]), recordIndex: 11)),
            ]),
        ]
        for (table, rows) in fixtures {
            let decoded = try PushBinaryCodec.pack(table: table, rows: rows)
            let frame = try PushBinaryCompression.zstdRawFrame(decoded,
                maxDecoded: PushProtocolLimits.maxObjectDecodedBytes, maxWire: PushProtocolLimits.maxObjectWireBytes)
            XCTAssertEqual(try referenceDecode(frame), decoded, table.rawValue)
        }
    }
}
