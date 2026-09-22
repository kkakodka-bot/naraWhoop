import XCTest
@testable import NoopPush

private let receiverId = "00000000-0000-4000-8000-000000000099"
private let enrolledUserId = "00000000-0000-4000-8000-0000000001aa"
private let enrolledSourceId = "00000000-0000-4000-8000-0000000001bb"

final class PushCapabilitiesParseTests: XCTestCase {
    func testCapabilitiesParseMatchesOracle() throws {
        for row in Self.oracleRows {
            let parts = row.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            let label = parts[0]
            switch parts[1] {
            case "OK":
                let parsed = try PushCapabilities.parse(Self.fixtureBytes(label))
                XCTAssertEqual(parts[2], parsed.protocolVersion, label)
                XCTAssertEqual(receiverId, parsed.receiverStateId, label)
                XCTAssertEqual(
                    parts[3].isEmpty ? [] : parts[3].split(separator: ",").map(String.init),
                    PushAppendTable.allCases.filter { parsed.appendTables.contains($0) }.map(\.wireName),
                    label
                )
                XCTAssertEqual(
                    parts[4].isEmpty ? [] : parts[4].split(separator: ",").map(String.init),
                    PushMutableTable.allCases.filter { parsed.mutableTables.contains($0) }.map(\.wireName),
                    label
                )
                XCTAssertEqual(parts[5] == "1", parsed.isEmpty, label)
            case "ERR":
                XCTAssertThrowsError(try PushCapabilities.parse(Self.fixtureBytes(label))) { error in
                    XCTAssertEqual(parts[2], (error as? PushProtocolException)?.message, label)
                }
            default:
                XCTFail("unknown oracle row kind: \(row)")
            }
        }
    }

    func testObjectLaneV12Parse() throws {
        let parsed = try PushCapabilities.parse(try JSONSerialization.data(withJSONObject: [
            "type": "capabilities",
            "protocolVersion": PushProtocol.objectVersion,
            "receiverStateId": receiverId,
            "streams": ["rawImuSession", "ppgWaveformSample"],
            "objectLane": [
                "endpoint": "/api/push/objects",
                "maxObjectBytes": PushProtocolLimits.maxObjectWireBytes,
                "urlTtlSec": 3600,
                "streams": ["rawImuSession"],
            ],
        ]))
        XCTAssertEqual(PushProtocol.objectVersion, parsed.protocolVersion)
        XCTAssertEqual("/api/push/objects", parsed.objectLane?.endpoint)
        XCTAssertEqual(Set([.rawImuSession]), parsed.objectLane?.streams)
    }

    func testAsyncCompletionRequiresExplicitWellFormedCapability() throws {
        let modes: [Any?] = [nil, ["sync"], ["sync", "async-v1"], ["async-v1"], ["future", "async-v1"],
            ["async-v1", "async-v1"], [true], "async-v1"]
        for (index, value) in modes.enumerated() {
            var lane: [String: Any] = ["endpoint": "/objects", "maxObjectBytes": 8_000_000, "streams": ["rawBatch"]]
            lane["completionModes"] = value
            let parsed = try PushCapabilities.parse(JSONSerialization.data(withJSONObject: [
                "type": "capabilities", "protocolVersion": "1.2", "receiverStateId": receiverId,
                "streams": ["rawBatch"], "objectLane": lane]))
            XCTAssertNotNil(parsed.objectLane)
            XCTAssertEqual(parsed.objectLane?.completionMode, [2, 3].contains(index) ? .asynchronousV1 : nil)
        }
    }

    func testMalformedObjectLaneDisablesLane() throws {
        let parsed = try PushCapabilities.parse(try JSONSerialization.data(withJSONObject: [
            "type": "capabilities",
            "protocolVersion": PushProtocol.objectVersion,
            "receiverStateId": receiverId,
            "streams": ["rawImuSession"],
            "objectLane": [
                "endpoint": "https://bad.example/objects",
                "maxObjectBytes": true,
                "streams": ["rawImuSession"],
            ],
        ]))
        XCTAssertNil(parsed.objectLane)
    }

    func testEnrollmentIdentityParsesWhenPresent() throws {
        let parsed = try PushCapabilities.parse(try JSONSerialization.data(withJSONObject: [
            "type": "capabilities",
            "protocolVersion": PushProtocol.version,
            "receiverStateId": receiverId,
            "userId": enrolledUserId,
            "sourceId": enrolledSourceId,
            "streams": ["hrSample"],
        ]))
        XCTAssertEqual(enrolledUserId, parsed.userId)
        XCTAssertEqual(enrolledSourceId, parsed.sourceId)
    }

    func testEnrollmentIdentityMustBeCanonicalWhenPresent() throws {
        for (key, value) in [
            ("userId", enrolledUserId.uppercased()),
            ("sourceId", "not-a-uuid"),
        ] {
            var object: [String: Any] = [
                "type": "capabilities",
                "protocolVersion": PushProtocol.version,
                "receiverStateId": receiverId,
                "userId": enrolledUserId,
                "sourceId": enrolledSourceId,
                "streams": ["hrSample"],
            ]
            object[key] = value
            XCTAssertThrowsError(try PushCapabilities.parse(
                try JSONSerialization.data(withJSONObject: object)
            ))
        }
    }

    func testAllUnknownStreamsParseEmptyAndCoordinatorNoOps() async throws {
        let capabilities = try PushCapabilities.parse(Self.fixtureBytes("allUnknown"))
        XCTAssertTrue(capabilities.isEmpty)

        let source = FailingIfOpenedPushSource()
        let transport = PostingPushTransport()
        let result = await PushCoordinator(
            source: source,
            transport: transport,
            progress: EmptyPushProgress(),
            sourceId: "3a3486dd-5030-4e17-a00d-a781399890f9"
        ).pushKnownDevices(capabilities: capabilities)

        XCTAssertEqual(0, result.acceptedBatches)
        XCTAssertEqual(0, result.rejectedBatches)
        XCTAssertFalse(result.hasMoreAppendRows)
        XCTAssertEqual(0, transport.postCount)
    }

    /// Verbatim stdout of `Tools/push_capabilities_oracle.swift`.
    private static let oracleRows = """
    allKnownV10|OK|1.0|hrSample|dailyMetric,journal|0
    allKnownV11|OK|1.1|hrSample|dailyMetric,journal|0
    someUnknown|OK|1.0|hrSample||0
    allUnknown|OK|1.1|||1
    emptyStreams|OK|1.0|||1
    duplicate|ERR|duplicate capability stream
    nonString|ERR|capability stream names must be strings
    missingReceiver|ERR|capabilities are missing required protocol 1.0 members
    forbiddenCommand|ERR|capabilities contain forbidden remote-control metadata
    unsupportedVersion|ERR|unsupported capability document
    """.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").map(String.init)

    private static func fixtureBytes(_ label: String) -> Data {
        switch label {
        case "allKnownV10":
            return document(version: "1.0", streams: ["hrSample", "journal", "dailyMetric"])
        case "allKnownV11":
            return document(version: "1.1", streams: ["hrSample", "journal", "dailyMetric"])
        case "someUnknown":
            return document(version: "1.0", streams: ["hrSample", "stepSample", "futureStream"])
        case "allUnknown":
            return document(version: "1.1", streams: ["futureScalarStream", "futureStream"])
        case "emptyStreams":
            return document(version: "1.0", streams: [])
        case "duplicate":
            return document(version: "1.0", streams: ["hrSample", "hrSample"])
        case "nonString":
            return try! JSONSerialization.data(withJSONObject: [
                "type": "capabilities", "protocolVersion": "1.0", "receiverStateId": receiverId,
                "streams": ["hrSample", 1],
            ])
        case "missingReceiver":
            return try! JSONSerialization.data(withJSONObject: [
                "type": "capabilities", "protocolVersion": "1.0",
                "streams": ["hrSample"],
            ])
        case "forbiddenCommand":
            return try! JSONSerialization.data(withJSONObject: [
                "type": "capabilities", "protocolVersion": "1.0", "receiverStateId": receiverId,
                "streams": ["hrSample"], "command": "sync-now",
            ])
        case "unsupportedVersion":
            return document(version: "2.0", streams: ["hrSample"])
        default:
            fatalError("unknown fixture \(label)")
        }
    }

    private static func document(version: String, streams: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "capabilities",
            "protocolVersion": version,
            "receiverStateId": receiverId,
            "streams": streams,
        ])
    }
}

private struct FailingIfOpenedPushSource: PushSnapshotSource {
    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] {
        XCTFail("Room must stay unopened when capabilities are empty")
        return []
    }

    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? { nil }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] { [] }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] { [] }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {}
}

private final class PostingPushTransport: PushTransport, @unchecked Sendable {
    var postCount = 0
    func capabilities() async throws -> PushCapabilitiesResult { .available(.all) }
    func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        postCount += 1
        return PushTransportResponse(statusCode: 200, body: Data())
    }

    func postBinary(_ batch: PushBinaryBatch) async throws -> PushTransportResponse {
        PushTransportResponse(statusCode: 200, body: Data())
    }
}

private struct EmptyPushProgress: PushProgressStore {
    func knownDeviceIds() async throws -> Set<String> { [] }
    func rememberDeviceId(_ deviceId: String) async throws {}
    func cursor(table: PushAppendTable, deviceId: String) async throws -> PushCursor? { nil }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async throws {}
    func binaryCursor(table: PushBinaryTable, deviceId: String) async throws -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) async throws {}
    func window(table: PushMutableTable, deviceId: String) async throws -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async throws {}
}
