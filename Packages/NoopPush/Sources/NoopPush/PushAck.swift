import Foundation

public struct PushAck: Sendable {
    public let protocolVersion: String
    public let batchId: String
    public let stream: String
    public let deviceId: String
    public let endCursor: PushCursor?
    public let acceptedRows: Int
    public let status: String
    public let durabilityReceipt: PushDurabilityReceipt?

    public init(
        protocolVersion: String,
        batchId: String,
        stream: String,
        deviceId: String,
        endCursor: PushCursor?,
        acceptedRows: Int,
        status: String,
        durabilityReceipt: PushDurabilityReceipt? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.batchId = batchId
        self.stream = stream
        self.deviceId = deviceId
        self.endCursor = endCursor
        self.acceptedRows = acceptedRows
        self.status = status
        self.durabilityReceipt = durabilityReceipt
    }

    public func exactlyMatches(_ batch: PushBatch) -> Bool {
        protocolVersion == batch.protocolVersion
            && batchId == batch.batchId
            && stream == batch.table.wireName
            && deviceId == batch.deviceId
            && endCursor == batch.endCursor
            && acceptedRows == batch.recordCount
            && status == "accepted"
    }

    public func exactlyMatches(_ batch: PushBinaryBatch) -> Bool {
        protocolVersion == batch.protocolVersion
            && batchId == batch.batchId
            && stream == batch.wireName
            && deviceId == batch.deviceId
            && endCursor == batch.endCursor
            && acceptedRows == batch.sampleCount
            && status == "accepted"
    }

    public static func fromBatch(_ batch: PushBatch) -> PushAck {
        PushAck(
            protocolVersion: batch.protocolVersion,
            batchId: batch.batchId,
            stream: batch.table.wireName,
            deviceId: batch.deviceId,
            endCursor: batch.endCursor,
            acceptedRows: batch.recordCount,
            status: "accepted"
        )
    }

    public static func parse(_ bytes: Data) throws -> PushAck {
        guard bytes.count <= PushProtocolLimits.maxAckBytes else {
            throw PushProtocolException("ack exceeds size limit")
        }
        guard let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw PushProtocolException("ack is not valid JSON")
        }
        let required = Set([
            "protocolVersion", "batchId", "stream", "deviceId", "endCursor", "acceptedRows", "status",
        ])
        let actual = Set(obj.keys)
        guard required.isSubset(of: actual) else {
            throw PushProtocolException("ack is missing required protocol 1.0 members")
        }
        if actual.contains(where: { PushProtocol.forbiddenRemoteControlMembers.contains($0) }) {
            throw PushProtocolException("ack contains forbidden remote-control metadata")
        }

        func string(_ name: String) throws -> String {
            guard let value = obj[name] as? String, !value.isEmpty else {
                throw PushProtocolException("ack.\(name) must be a non-empty string")
            }
            return value
        }

        func nonnegativeInteger(_ value: Any?, name: String, maximum: Int64 = Int64.max) throws -> Int64 {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.compare(NSNumber(value: 0)) != .orderedAscending,
                  number.compare(NSNumber(value: maximum)) != .orderedDescending else {
                throw PushProtocolException("ack.\(name) must be a bounded nonnegative integer")
            }
            return number.int64Value
        }

        let rawCursor = obj["endCursor"]
        let cursor: PushCursor?
        if rawCursor == nil || rawCursor is NSNull {
            cursor = nil
        } else if let raw = rawCursor as? [String: Any] {
            guard Set(raw.keys).isSuperset(of: ["rowId", "keySha256"]) else {
                throw PushProtocolException("ack.endCursor is missing required protocol 1.0 members")
            }
            let rowId = try nonnegativeInteger(raw["rowId"], name: "endCursor.rowId")
            guard let sha = raw["keySha256"] as? String,
                  sha.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            else { throw PushProtocolException("ack.endCursor.keySha256 must be lowercase SHA-256") }
            cursor = PushCursor(rowId: rowId, naturalKeyFingerprint: sha)
        } else {
            throw PushProtocolException("ack.endCursor must be an object or null")
        }

        return PushAck(
            protocolVersion: try string("protocolVersion"),
            batchId: try string("batchId"),
            stream: try string("stream"),
            deviceId: try string("deviceId"),
            endCursor: cursor,
            acceptedRows: Int(try nonnegativeInteger(obj["acceptedRows"], name: "acceptedRows", maximum: Int64(PushProtocolLimits.maxRecords))),
            status: try string("status"),
            durabilityReceipt: try parseDurabilityReceipt(obj)
        )
    }
}

extension PushObjectIntent {
    /// Parses the receiver's intent response. `expectedObjectId` pins the reply to the request so a
    /// confused or malicious receiver cannot steer the upload onto a different object.
    public static func parse(_ bytes: Data, expectedObjectId: String,
                             expectedVersion: String = PushProtocol.objectVersion) throws -> PushObjectIntent {
        guard bytes.count <= PushProtocolLimits.maxAckBytes else {
            throw PushProtocolException("object intent exceeds size limit")
        }
        guard let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw PushProtocolException("object intent is not valid JSON")
        }
        let required: Set<String> = ["type", "protocolVersion", "objectId", "objectKey", "duplicate"]
        guard required.isSubset(of: Set(obj.keys)) else {
            throw PushProtocolException("object intent is missing required protocol 1.2 members")
        }
        if Set(obj.keys).contains(where: { PushProtocol.forbiddenRemoteControlMembers.contains($0) }) {
            throw PushProtocolException("object intent contains forbidden remote-control metadata")
        }
        guard obj["type"] as? String == "objectIntent",
              PushProtocol.isObjectVersion(expectedVersion), obj["protocolVersion"] as? String == expectedVersion else {
            throw PushProtocolException("unsupported object intent document")
        }
        guard let objectId = obj["objectId"] as? String, isCanonicalObjectUuid(objectId) else {
            throw PushProtocolException("object intent.objectId must be a canonical UUID")
        }
        guard objectId == expectedObjectId else {
            throw PushProtocolException("object intent.objectId does not match the request")
        }
        guard let objectKey = obj["objectKey"] as? String, isValidObjectKey(objectKey) else {
            throw PushProtocolException("object intent.objectKey must be a non-empty key")
        }
        let duplicate = try objectLaneBool(obj, "duplicate")
        let expiresAt: String?
        if let raw = obj["expiresAt"], !(raw is NSNull) {
            guard let value = raw as? String, value.count <= 64 else {
                throw PushProtocolException("object intent.expiresAt must be a string")
            }
            expiresAt = value
        } else {
            expiresAt = nil
        }

        var uploadUrl: String? = nil
        var requiredHeaders: [String: String] = [:]
        if let rawUrl = obj["uploadUrl"], !(rawUrl is NSNull) {
            guard let url = rawUrl as? String, url.count <= 8192 else {
                throw PushProtocolException("object intent.uploadUrl must be a string")
            }
            // The presigned URL points at the bucket, not the receiver: https, or http only for a
            // local literal host (the same policy the configured endpoint follows).
            guard case .valid = PushEndpointPolicy.validate(url) else {
                throw PushProtocolException("object intent.uploadUrl is not an allowed URL")
            }
            uploadUrl = url
        }
        if let rawHeaders = obj["requiredHeaders"], !(rawHeaders is NSNull) {
            guard let headers = rawHeaders as? [String: Any], headers.count <= 32 else {
                throw PushProtocolException("object intent.requiredHeaders must be an object")
            }
            for (name, value) in headers {
                guard name.count <= 64,
                      name.range(of: #"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$"#, options: .regularExpression) != nil,
                      let headerValue = value as? String, headerValue.count <= 512 else {
                    throw PushProtocolException("object intent.requiredHeaders are invalid")
                }
                requiredHeaders[name.lowercased()] = headerValue
            }
        }
        if !duplicate {
            guard uploadUrl != nil else {
                throw PushProtocolException("object intent without uploadUrl must be marked duplicate")
            }
        }
        return PushObjectIntent(
            objectId: objectId,
            objectKey: objectKey,
            uploadUrl: uploadUrl,
            requiredHeaders: requiredHeaders,
            expiresAt: expiresAt,
            duplicate: duplicate
        )
    }
}

extension PushObjectAck {
    public static func parse(_ bytes: Data, expectedObjectId: String,
                             expectedVersion: String = PushProtocol.objectVersion) throws -> PushObjectAck {
        guard bytes.count <= PushProtocolLimits.maxAckBytes else {
            throw PushProtocolException("object ack exceeds size limit")
        }
        guard let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw PushProtocolException("object ack is not valid JSON")
        }
        let required: Set<String> = ["type", "protocolVersion", "objectId", "status", "objectKey", "duplicate"]
        guard required.isSubset(of: Set(obj.keys)) else {
            throw PushProtocolException("object ack is missing required protocol 1.2 members")
        }
        if Set(obj.keys).contains(where: { PushProtocol.forbiddenRemoteControlMembers.contains($0) }) {
            throw PushProtocolException("object ack contains forbidden remote-control metadata")
        }
        guard obj["type"] as? String == "objectAck",
              PushProtocol.isObjectVersion(expectedVersion), obj["protocolVersion"] as? String == expectedVersion else {
            throw PushProtocolException("unsupported object ack document")
        }
        guard let objectId = obj["objectId"] as? String, isCanonicalObjectUuid(objectId) else {
            throw PushProtocolException("object ack.objectId must be a canonical UUID")
        }
        guard objectId == expectedObjectId else {
            throw PushProtocolException("object ack.objectId does not match the request")
        }
        guard let status = obj["status"] as? String, !status.isEmpty, status.count <= 64 else {
            throw PushProtocolException("object ack.status must be a non-empty string")
        }
        guard let objectKey = obj["objectKey"] as? String, isValidObjectKey(objectKey) else {
            throw PushProtocolException("object ack.objectKey must be a non-empty key")
        }
        let duplicate = try objectLaneBool(obj, "duplicate")
        return PushObjectAck(objectId: objectId, status: status, objectKey: objectKey, duplicate: duplicate,
                             durabilityReceipt: try parseDurabilityReceipt(obj), protocolVersion: obj["protocolVersion"] as! String)
    }
}

private func parseDurabilityReceipt(_ object: [String: Any]) throws -> PushDurabilityReceipt? {
    guard let raw = object["durabilityReceipt"], !(raw is NSNull) else { return nil }
    let receipt = try JSONDecoder().decode(PushDurabilityReceipt.self, from: JSONSerialization.data(withJSONObject: raw))
    guard receipt.isValid else { throw PushProtocolException("invalid durability receipt") }
    return receipt
}

private func isCanonicalObjectUuid(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
}

private func isValidObjectKey(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 1024
        && value.range(of: #"\s"#, options: .regularExpression) == nil
}

/// JSONSerialization bridges JSON `1`/`0` to NSNumber just like `true`/`false`; only a genuine
/// JSON boolean is accepted here.
private func objectLaneBool(_ obj: [String: Any], _ name: String) throws -> Bool {
    guard let number = obj[name] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw PushProtocolException("object lane response.\(name) must be a boolean")
    }
    return number.boolValue
}
