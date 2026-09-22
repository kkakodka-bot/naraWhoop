import Foundation
import NoopPush

// Synthetic subset of W5ReceiptFixture in StrandTests/CloudPushReceiptIntegrationTests.swift.
enum W5ReceiptFixture {
    static let owner = "11111111-1111-4111-8111-111111111111"
    static let source = "44444444-4444-4444-8444-444444444444"
    static func objectKey(owner: String, device: String, stream: String) -> String {
        "v3/core/users/\(owner)/devices/\(PushDurabilityReceipt.canonicalDevice(owner: owner, device: device))/\(stream)/fixture/verified-object"
    }
    static func receipt(owner: String, device: String, object: String, batch: String, source: String,
                        stream: String, decoded: String, wire: String, decodedBytes: Int, wireBytes: Int,
                        key: String? = nil, schema: Int = 1) -> [String: Any] {
        ["version": 1, "state": "verified_indexed", "receiptId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
         "ownerUserId": owner, "deviceId": PushDurabilityReceipt.canonicalDevice(owner: owner, device: device),
         "objectId": object, "batchId": batch, "sourceId": source, "stream": stream, "schemaVersion": schema,
         "objectKey": key ?? objectKey(owner: owner, device: device, stream: stream), "contentSha256": decoded, "wireSha256": wire, "compressedBytes": wireBytes,
         "uncompressedBytes": decodedBytes, "verifiedAt": "2026-09-18T00:00:00Z", "indexedAt": "2026-09-18T00:00:01Z"]
    }
    static func inline(_ batch: PushBatch, owner: String) -> [String: Any] {
        var cursor: Any = NSNull()
        if let end = batch.endCursor { cursor = ["rowId": end.rowId, "keySha256": end.naturalKeyFingerprint] }
        return ["protocolVersion": batch.protocolVersion, "batchId": batch.batchId, "stream": batch.table.wireName,
                "deviceId": batch.deviceId, "endCursor": cursor, "acceptedRows": batch.recordCount, "status": "accepted",
                "durabilityReceipt": receipt(owner: owner, device: batch.deviceId, object: batch.batchId,
                    batch: batch.batchId, source: batch.sourceId, stream: batch.table.wireName,
                    decoded: PushDurabilityReceipt.sha256(batch.body), wire: String(repeating: "a", count: 64),
                    decodedBytes: batch.body.count, wireBytes: 100,
                    schema: PushProtocol.schemaVersion(stream: batch.table.wireName, protocolVersion: batch.protocolVersion))]
    }
    static func bytes(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
