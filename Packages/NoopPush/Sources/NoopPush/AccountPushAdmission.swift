import Foundation

public enum AccountVerifiedCapabilities {
    public static func parse(_ data: Data, scope: AccountScope) throws -> PushCapabilities {
        guard data.count <= PushProtocolLimits.maxAckBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let owner = object["userId"] as? String,
              let actual = try? AccountScope(projectURL: scope.projectURL, userID: owner), actual == scope else {
            throw AccountAuthError.invalidIdentity
        }
        return try PushCapabilities.parse(data)
    }
}

public struct AccountPushAdmission: Sendable {
    public let context: AccountSessionContext
    public let sourceID: String
    private let current: @Sendable (AccountSessionContext) -> Bool

    public init(context: AccountSessionContext, captureScope: AccountScope, sourceID: String,
                isCurrent: @escaping @Sendable (AccountSessionContext) -> Bool) throws {
        guard context.scope == captureScope, UUID(uuidString: sourceID) != nil else {
            throw AccountAuthError.unboundCapture
        }
        self.context = context; self.sourceID = sourceID; self.current = isCurrent
        try check()
    }

    public func check() throws {
        guard current(context) else { throw AccountAuthError.staleOperation }
    }

    public func namespace(endpoint: String, protocolVersion: String, receiverStateID: String) -> String {
        AccountScope.digest("push-v2\u{0}\(context.scope.namespace)\u{0}\(sourceID)\u{0}\(endpoint)\u{0}\(protocolVersion)\u{0}\(receiverStateID)")
    }
}

/// The underlying source must already be bound to an immutable account-owned database/file root.
public struct AccountFencedSnapshot: PushSnapshotSource {
    private let source: any PushSnapshotSource
    private let admission: AccountPushAdmission
    public init(source: any PushSnapshotSource, admission: AccountPushAdmission) {
        self.source = source; self.admission = admission
    }
    public func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] {
        try admission.check(); let value = try await source.knownDeviceIds(capabilities: capabilities)
        try admission.check(); return value
    }
    public func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? {
        try admission.check(); let value = try await source.appendRecordAt(table: table, deviceId: deviceId, rowId: rowId)
        try admission.check(); return value
    }
    public func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] {
        try admission.check(); let value = try await source.appendRows(table: table, deviceId: deviceId, afterRowId: afterRowId, limit: limit)
        try admission.check(); return value
    }
    public func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] {
        try admission.check(); let value = try await source.mutableRows(table: table, deviceId: deviceId, window: window, limit: limit)
        try admission.check(); return value
    }
    public func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? {
        try admission.check(); let value = try await source.binaryRecordAt(table: table, deviceId: deviceId, rowId: rowId)
        try admission.check(); return value
    }
    public func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] {
        try admission.check(); let value = try await source.binaryRows(table: table, deviceId: deviceId, afterRowId: afterRowId, limit: limit)
        try admission.check(); return value
    }
    public func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {
        try admission.check(); try await source.acknowledgeBinary(table: table, deviceId: deviceId, rows: rows)
        try admission.check()
    }
}

public struct AccountFencedProgress: PushProgressStore {
    private let progress: any PushProgressStore
    private let admission: AccountPushAdmission
    public init(progress: any PushProgressStore, admission: AccountPushAdmission) {
        self.progress = progress; self.admission = admission
    }
    public func knownDeviceIds() async throws -> Set<String> {
        try admission.check(); let value = try await progress.knownDeviceIds(); try admission.check(); return value
    }
    public func rememberDeviceId(_ deviceId: String) async throws {
        try admission.check(); try await progress.rememberDeviceId(deviceId); try admission.check()
    }
    public func cursor(table: PushAppendTable, deviceId: String) async throws -> PushCursor? {
        try admission.check(); let value = try await progress.cursor(table: table, deviceId: deviceId)
        try admission.check(); return value
    }
    public func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async throws {
        try admission.check(); try await progress.saveCursor(table: table, deviceId: deviceId, cursor: cursor); try admission.check()
    }
    public func binaryCursor(table: PushBinaryTable, deviceId: String) async throws -> PushCursor? {
        try admission.check(); let value = try await progress.binaryCursor(table: table, deviceId: deviceId)
        try admission.check(); return value
    }
    public func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) async throws {
        try admission.check(); try await progress.saveBinaryCursor(table: table, deviceId: deviceId, cursor: cursor); try admission.check()
    }
    public func window(table: PushMutableTable, deviceId: String) async throws -> PushWindowProgress? {
        try admission.check(); let value = try await progress.window(table: table, deviceId: deviceId)
        try admission.check(); return value
    }
    public func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async throws {
        try admission.check(); try await self.progress.saveWindow(table: table, deviceId: deviceId, progress: progress); try admission.check()
    }
    public func inFlightObject(table: PushBinaryTable, deviceId: String) async throws -> PushInFlightObject? {
        try admission.check(); let value = try await progress.inFlightObject(table: table, deviceId: deviceId)
        try admission.check(); return value
    }
    public func saveInFlightObject(table: PushBinaryTable, deviceId: String, object: PushInFlightObject?) async throws {
        try admission.check(); try await progress.saveInFlightObject(table: table, deviceId: deviceId, object: object); try admission.check()
    }
}

public struct AccountFencedTransport: PushTransport {
    private let transport: any PushTransport
    private let admission: AccountPushAdmission
    public init(transport: any PushTransport, admission: AccountPushAdmission) {
        self.transport = transport; self.admission = admission
    }
    public func capabilities() async throws -> PushCapabilitiesResult {
        try admission.check(); let value = try await transport.capabilities(); try admission.check(); return value
    }
    public func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        try admission.check(); let value = try await transport.post(batch); try admission.check(); return value
    }
    public func postBinary(_ batch: PushBinaryBatch) async throws -> PushTransportResponse {
        try admission.check(); let value = try await transport.postBinary(batch); try admission.check(); return value
    }
    public func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) async throws -> PushObjectIntent {
        try admission.check(); let value = try await transport.createObjectIntent(manifest, lane: lane)
        try admission.check(); return value
    }
    public func uploadObject(_ intent: PushObjectIntent, body: Data) async throws {
        try admission.check(); try await transport.uploadObject(intent, body: body); try admission.check()
    }
    public func completeObject(objectId: String, lane: PushObjectLane) async throws -> PushObjectAck {
        try admission.check(); let value = try await transport.completeObject(objectId: objectId, lane: lane)
        try admission.check(); return value
    }
}
