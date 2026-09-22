import Foundation
import NoopPush

// Companion to the existing synthetic ReceiptFixture. The export itself uses actual production
// files and codec bytes; this helper only lets the rest of its original XCTest source compile.
extension W5ReceiptFixture {
    static func object(_ batch: PushBinaryBatch, owner: String, key: String = "archive/verified-object") -> [String: Any] {
        ["type": "objectAck", "protocolVersion": batch.protocolVersion, "objectId": batch.objectId,
         "objectKey": key, "status": "ready", "duplicate": false,
         "durabilityReceipt": receipt(owner: owner, device: batch.deviceId, object: batch.objectId,
            batch: batch.batchId, source: batch.sourceId, stream: batch.wireName, decoded: batch.contentSha256,
            wire: batch.wireSHA256, decodedBytes: batch.uncompressedBytes,
            wireBytes: batch.wireBytes, key: key,
            schema: PushProtocol.schemaVersion(stream: batch.wireName, protocolVersion: batch.protocolVersion))]
    }
}
