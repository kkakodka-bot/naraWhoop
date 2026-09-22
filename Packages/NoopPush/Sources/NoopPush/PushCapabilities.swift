import Foundation

public struct PushCapabilities: Sendable {
    public let appendTables: Set<PushAppendTable>
    public let mutableTables: Set<PushMutableTable>
    public let binaryTables: Set<PushBinaryTable>
    public let protocolVersion: String
    public let receiverStateId: String
    /// Server-resolved enrollment identity. Generic protocol fixtures may omit these, but enrolled
    /// clients must pin both before opening local storage or uploading records.
    public let userId: String?
    public let sourceId: String?
    /// Direct-to-bucket lane advertised at protocol 1.2 and later. `nil` disables binary upload:
    /// raw rows stay local rather than posting inline into a `use_object_lane` refusal.
    public let objectLane: PushObjectLane?

    public var isEmpty: Bool { appendTables.isEmpty && mutableTables.isEmpty && binaryTables.isEmpty }

    public var wireNames: [String] {
        PushAppendTable.allCases.filter { appendTables.contains($0) }.map(\.wireName)
            + PushMutableTable.allCases.filter { mutableTables.contains($0) }.map(\.wireName)
            + PushBinaryTable.allCases.filter { binaryTables.contains($0) }.map(\.wireName)
    }

    public static let unscopedReceiverStateId = "00000000-0000-4000-8000-000000000000"

    public static let all = PushCapabilities(
        appendTables: Set(PushAppendTable.allCases.filter { !$0.isScalarExtension }),
        mutableTables: Set(PushMutableTable.allCases),
        binaryTables: Set(PushBinaryTable.allCases)
    )

    public init(
        appendTables: Set<PushAppendTable>,
        mutableTables: Set<PushMutableTable>,
        binaryTables: Set<PushBinaryTable> = [],
        protocolVersion: String = PushProtocol.version,
        receiverStateId: String = unscopedReceiverStateId,
        objectLane: PushObjectLane? = nil,
        userId: String? = nil,
        sourceId: String? = nil
    ) {
        self.appendTables = appendTables
        self.mutableTables = mutableTables
        self.binaryTables = binaryTables
        self.protocolVersion = protocolVersion
        self.receiverStateId = receiverStateId
        self.objectLane = objectLane
        self.userId = userId
        self.sourceId = sourceId
    }

    public static func parse(_ bytes: Data) throws -> PushCapabilities {
        guard bytes.count <= PushProtocolLimits.maxAckBytes else {
            throw PushProtocolException("capabilities exceed size limit")
        }
        guard let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw PushProtocolException("capabilities are not valid JSON")
        }
        let required = Set(["type", "protocolVersion", "receiverStateId", "streams"])
        let actual = Set(obj.keys)
        guard required.isSubset(of: actual) else {
            throw PushProtocolException("capabilities are missing required protocol 1.0 members")
        }
        if actual.contains(where: { PushProtocol.forbiddenRemoteControlMembers.contains($0) }) {
            throw PushProtocolException("capabilities contain forbidden remote-control metadata")
        }
        guard obj["type"] as? String == "capabilities" else {
            throw PushProtocolException("unsupported capability document")
        }
        let version = obj["protocolVersion"] as? String ?? ""
        guard version == PushProtocol.version || version == PushProtocol.binaryVersion || PushProtocol.isObjectVersion(version) else {
            throw PushProtocolException("unsupported capability document")
        }
        guard let receiverStateId = obj["receiverStateId"] as? String, isCanonicalUuid(receiverStateId) else {
            throw PushProtocolException("capabilities.receiverStateId must be a canonical UUID")
        }
        let userId = try optionalCanonicalUuid(obj, key: "userId")
        let sourceId = try optionalCanonicalUuid(obj, key: "sourceId")
        guard let streams = obj["streams"] as? [Any] else {
            throw PushProtocolException("capabilities.streams must be an array")
        }
        let appendByName = Dictionary(uniqueKeysWithValues: PushAppendTable.allCases.map { ($0.wireName, $0) })
        let mutableByName = Dictionary(uniqueKeysWithValues: PushMutableTable.allCases.map { ($0.wireName, $0) })
        let binaryByName = Dictionary(uniqueKeysWithValues: PushBinaryTable.allCases.map { ($0.wireName, $0) })
        var seen = Set<String>()
        var append = Set<PushAppendTable>()
        var mutable = Set<PushMutableTable>()
        var binary = Set<PushBinaryTable>()
        for item in streams {
            guard let name = item as? String else {
                throw PushProtocolException("capability stream names must be strings")
            }
            guard seen.insert(name).inserted else {
                throw PushProtocolException("duplicate capability stream")
            }
            if let table = appendByName[name] {
                if !table.isScalarExtension || version != PushProtocol.version { append.insert(table) }
            } else if let table = mutableByName[name] {
                mutable.insert(table)
            } else if let table = binaryByName[name] {
                binary.insert(table)
            }
        }
        // A malformed object-lane block disables the lane (rows are
        // retained) rather than failing the whole capability negotiation.
        let objectLane: PushObjectLane?
        if PushProtocol.isObjectVersion(version), let laneObject = obj["objectLane"] as? [String: Any] {
            objectLane = parseObjectLane(laneObject, binaryByName: binaryByName)
        } else {
            objectLane = nil
        }
        return PushCapabilities(
            appendTables: append,
            mutableTables: mutable,
            binaryTables: binary,
            protocolVersion: version,
            receiverStateId: receiverStateId,
            objectLane: objectLane,
            userId: userId,
            sourceId: sourceId
        )
    }

    private static func parseObjectLane(
        _ obj: [String: Any],
        binaryByName: [String: PushBinaryTable]
    ) -> PushObjectLane? {
        guard let endpoint = obj["endpoint"] as? String,
              endpoint.count <= 256,
              endpoint.hasPrefix("/"), !endpoint.hasPrefix("//"),
              endpoint.range(of: #"\s"#, options: .regularExpression) == nil else { return nil }
        guard let maxObjectBytes = jsonInt64(obj["maxObjectBytes"]),
              maxObjectBytes > 0, maxObjectBytes <= Int64(PushProtocolLimits.maxObjectWireBytes) else { return nil }
        var urlTtlSec: Int64? = nil
        if let ttl = jsonInt64(obj["urlTtlSec"]) {
            guard ttl > 0 else { return nil }
            urlTtlSec = ttl
        }
        guard let streamItems = obj["streams"] as? [Any] else { return nil }
        var laneStreams = Set<PushBinaryTable>()
        for item in streamItems {
            guard let name = item as? String else { return nil }
            guard let table = binaryByName[name] else { continue } // unknown stream names are ignored
            guard laneStreams.insert(table).inserted else { return nil }
        }
        guard !laneStreams.isEmpty else { return nil }
        let completionMode: PushObjectCompletionMode?
        if let modes = obj["completionModes"] as? [String], modes.count <= 2,
           Set(modes).count == modes.count, modes.allSatisfy({ ["sync", "async-v1"].contains($0) }),
           modes.contains("async-v1") { completionMode = .asynchronousV1 }
        else { completionMode = nil }
        return PushObjectLane(
            endpoint: endpoint,
            maxObjectBytes: maxObjectBytes,
            urlTtlSec: urlTtlSec,
            streams: laneStreams,
            completionMode: completionMode
        )
    }

    /// JSONSerialization bridges JSON booleans to NSNumber as well; a lane cap encoded as `true`
    /// is malformed, not 1.
    private static func jsonInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, double >= Double(Int64.min), double <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func isCanonicalUuid(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func optionalCanonicalUuid(_ object: [String: Any], key: String) throws -> String? {
        guard let raw = object[key] else { return nil }
        guard let value = raw as? String, isCanonicalUuid(value) else {
            throw PushProtocolException("capabilities.\(key) must be a canonical UUID")
        }
        return value
    }
}

public enum PushCapabilitiesResult: Sendable {
    case available(PushCapabilities)
    case rejected(reason: String, retryable: Bool, failure: PushFailure?)
}

extension PushTransport {
    public func capabilities() async throws -> PushCapabilitiesResult {
        .available(.all)
    }

    public func postBinary(_ batch: PushBinaryBatch) async throws -> PushTransportResponse {
        throw PushTransportException(PushFailure(code: .localData))
    }
}
