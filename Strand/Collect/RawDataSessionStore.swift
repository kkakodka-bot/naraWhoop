import Combine
import Foundation
import WhoopStore

/// Persistent, user-controlled 5/MG capture sessions. This is the iOS/macOS twin of Android's
/// GroundTruthCollector: it records bounded raw-data windows with optional comments.
@MainActor
final class RawDataSessionStore: ObservableObject {
    /// One process-wide owner. BLE lifecycle cleanup and the screen must mutate the same persisted
    /// session state; a view-local store can otherwise remain "active" after background auto-stop.
    static let shared = RawDataSessionStore()
    struct Event: Codable, Identifiable, Equatable {
        var id = UUID()
        var atMs: Int64
        let kind: String
        var markerId: String?
        var markerType: String?
        var text: String?
    }

    struct Session: Codable, Identifiable, Equatable {
        let id: String
        let deviceId: String
        /// CoreBluetooth source identity used to correlate a persisted stop-first cleanup debt.
        let peripheralId: String?
        let startedAtMs: Int64
        var endedAtMs: Int64?
        var capturedStartedAtMs: Int64?
        var capturedEndedAtMs: Int64?
        var comment: String
        var exported: Bool
        var lastExportedAtMs: Int64?
        var events: [Event]

        var active: Bool { endedAtMs == nil }
    }

    @Published private(set) var sessions: [Session] = []
    var active: Session? { sessions.first(where: \.active) }

    private let directory: URL
    private let imuStore: ImuSessionFileStore
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directory override: URL? = nil, fileManager: FileManager = .default,
         imuStore: ImuSessionFileStore = .shared) {
        self.imuStore = imuStore
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        directory = override ?? base.appendingPathComponent("OpenWhoop/RawDataSessions", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil)) ?? []
        sessions = urls.filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(Session.self, from: $0) }
            .sorted { $0.startedAtMs > $1.startedAtMs }
    }

    @discardableResult
    func start(deviceId: String, peripheralId: String? = nil, now: Date = Date()) -> Session? {
        guard active == nil else { return nil }
        let millis = Int64(now.timeIntervalSince1970 * 1_000)
        let started = Event(atMs: millis, kind: "start")
        let session = Session(id: String(millis), deviceId: deviceId, peripheralId: peripheralId,
                              startedAtMs: millis,
                              endedAtMs: nil, capturedStartedAtMs: millis, capturedEndedAtMs: nil,
                              comment: "", exported: false, lastExportedAtMs: nil, events: [started])
        sessions.insert(session, at: 0)
        guard persist(session) else {
            sessions.removeAll { $0.id == session.id }
            return nil
        }
        imuStore.start(id: session.id, deviceId: deviceId, fromMs: millis)
        return session
    }

    @discardableResult
    func stop(sessionId: String? = nil,
              peripheralId: String? = nil,
              now: Date = Date()) -> Bool {
        guard let index = sessions.firstIndex(where: { session in
            guard session.active else { return false }
            if let sessionId, session.id != sessionId { return false }
            if let peripheralId {
                if sessionId == nil { return session.peripheralId == peripheralId }
                // Current-format rows carry the physical identity. Legacy rows may not; an exact
                // session id still identifies them without closing some other active capture.
                if let recorded = session.peripheralId, recorded != peripheralId { return false }
            }
            return true
        }) else { return false }
        let millis = Int64(now.timeIntervalSince1970 * 1_000)
        let active = sessions[index]
        // Flush the final high-rate block before publishing the terminal metadata. If it cannot be made
        // durable, leave the session active so the BLE lifecycle retains debt and a later Stop can retry.
        guard imuStore.complete(id: active.id, toMs: millis) else { return false }
        sessions[index].endedAtMs = millis
        sessions[index].capturedEndedAtMs = millis
        sessions[index].events.append(Event(atMs: millis, kind: "stop"))
        let stopped = sessions[index]
        guard persist(stopped) else {
            sessions[index] = active
            return false
        }
        return true
    }

    /// Idempotent lifecycle reconciliation used after the BLE controller has proved the stock producer
    /// stopped. Unlike the user-facing `stop`, an already-closed matching row is success: relaunch and
    /// reconnect cleanup must be able to publish the same terminal fact more than once without losing the
    /// producer debt. A mismatched physical source, unknown exact id, or unattributable legacy active row
    /// fails closed.
    @discardableResult
    func reconcileProducerStopped(sessionId: String? = nil,
                                  peripheralId: String,
                                  now: Date = Date()) -> Bool {
        if stop(sessionId: sessionId, peripheralId: peripheralId, now: now) { return true }
        if let sessionId {
            guard let session = sessions.first(where: { $0.id == sessionId }), !session.active else {
                return false
            }
            guard session.peripheralId == nil || session.peripheralId == peripheralId,
                  let endedAtMs = session.endedAtMs else { return false }
            // Also repairs a process that reached the older metadata-first close path: do not clear BLE
            // cleanup debt until any still-pending final IMU block has been flushed successfully.
            return imuStore.complete(id: session.id, toMs: endedAtMs)
        }
        // A peripheral-only recovery may legitimately have no UI session (for example, after a process
        // interruption left producer cleanup debt). It may
        // not declare success while any active row remains because legacy rows lack a physical identity.
        return active == nil
    }

    @discardableResult
    func createHistorical(deviceId: String, from: Date, to: Date) -> Session? {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        guard validRange(fromMs, toMs) else { return nil }
        let id = String(Int64(Date().timeIntervalSince1970 * 1_000))
        let events = [Event(atMs: fromMs, kind: "start"), Event(atMs: toMs, kind: "stop")]
        let session = Session(id: id, deviceId: deviceId, peripheralId: nil,
                              startedAtMs: fromMs, endedAtMs: toMs,
                              capturedStartedAtMs: nil, capturedEndedAtMs: nil, comment: "",
                              exported: false, lastExportedAtMs: nil, events: events)
        sessions.insert(session, at: 0); persist(session)
        imuStore.register(id: id, deviceId: deviceId, fromMs: fromMs, toMs: toMs)
        return session
    }

    func setRange(sessionId: String, from: Date, to: Date) {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        guard validRange(fromMs, toMs) else { return }
        mutate(sessionId) { session in
            guard !session.active else { return }
            session = Session(id: session.id, deviceId: session.deviceId,
                              peripheralId: session.peripheralId, startedAtMs: fromMs,
                              endedAtMs: toMs, capturedStartedAtMs: session.capturedStartedAtMs,
                              capturedEndedAtMs: session.capturedEndedAtMs, comment: session.comment,
                              exported: false, lastExportedAtMs: nil, events: session.events)
        }
        if let session = sessions.first(where: { $0.id == sessionId }) {
            imuStore.register(id: sessionId, deviceId: session.deviceId, fromMs: fromMs, toMs: toMs)
        }
    }

    func setComment(_ comment: String, sessionId: String) {
        mutate(sessionId) { $0.comment = String(comment.prefix(4_000)) }
    }

    @discardableResult
    func addMarker(sessionId: String, at: Date, type: String, text: String) -> Event? {
        guard Self.markerTypes.contains(type) else { return nil }
        var added: Event?
        mutate(sessionId) { session in
            let atMs = Self.clamp(Int64(at.timeIntervalSince1970 * 1_000), to: session)
            let marker = Event(atMs: atMs, kind: "marker", markerId: UUID().uuidString,
                               markerType: type, text: String(text.prefix(500)))
            session.events.append(marker)
            added = marker
        }
        return added
    }

    func updateMarker(sessionId: String, markerId: String, at: Date, type: String, text: String) {
        guard Self.markerTypes.contains(type) else { return }
        mutate(sessionId) { session in
            guard let index = session.events.firstIndex(where: { $0.markerId == markerId }) else { return }
            session.events[index].atMs = Self.clamp(Int64(at.timeIntervalSince1970 * 1_000), to: session)
            session.events[index].markerType = type
            session.events[index].text = String(text.prefix(500))
        }
    }

    func deleteMarker(sessionId: String, markerId: String) {
        mutate(sessionId) { $0.events.removeAll { $0.kind == "marker" && $0.markerId == markerId } }
    }

    func markExported(_ sessionId: String, now: Date = Date()) {
        mutate(sessionId) {
            $0.exported = true
            $0.lastExportedAtMs = Int64(now.timeIntervalSince1970 * 1_000)
        }
    }

    @discardableResult
    func removeMetadata(_ sessionId: String,
                        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Bool {
        guard sessions.first(where: { $0.id == sessionId })?.active == false else { return false }
        guard imuStore.deleteFiles(sessionId, removeItem: removeItem) else { return false }
        imuStore.remove(id: sessionId)
        do {
            let metadata = file(sessionId)
            if FileManager.default.fileExists(atPath: metadata.path) { try removeItem(metadata) }
        } catch { return false }
        sessions.removeAll { $0.id == sessionId }
        return true
    }

    private func mutateActive(_ body: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: \.active) else { return }
        body(&sessions[index])
        persist(sessions[index])
    }

    private func mutate(_ id: String, _ body: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        body(&sessions[index])
        persist(sessions[index])
    }

    @discardableResult
    private func persist(_ session: Session) -> Bool {
        do {
            let data = try encoder.encode(session)
            try data.write(to: file(session.id), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("session-\(id).json") }

    private func validRange(_ from: Int64, _ to: Int64) -> Bool {
        from > 0 && from <= to && to - from <= 7 * 24 * 60 * 60 * 1_000
    }

    static let markerTypes = ["moment", "start", "end", "issue"]

    private static func clamp(_ atMs: Int64, to session: Session) -> Int64 {
        min(max(atMs, session.startedAtMs), session.endedAtMs ?? Int64(Date().timeIntervalSince1970 * 1_000))
    }

    func exportEntries(for session: Session, sensorAvailable: Bool = false) -> [FileExport.BundleEntry] {
        var meta: [String: Any] = [
            "schema_version": 3, "capture_kind": "whoop_5mg_raw_data",
            "session_id": session.id, "device_id": session.deviceId,
            "started_at_ms": session.startedAtMs, "ended_at_ms": session.endedAtMs ?? session.startedAtMs,
            "comment": session.comment,
            "sensor_export_available": sensorAvailable,
            "device_family": "iOS",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "markers": session.events.filter {
                $0.kind == "marker" && $0.atMs >= session.startedAtMs
                    && $0.atMs <= (session.endedAtMs ?? session.startedAtMs)
            }.map { marker in
                ["id": marker.markerId ?? "", "at_ms": marker.atMs,
                 "type": marker.markerType ?? "moment", "text": marker.text ?? ""] as [String: Any]
            },
        ]
        if let value = session.capturedStartedAtMs { meta["captured_started_at_ms"] = value }
        if let value = session.capturedEndedAtMs { meta["captured_ended_at_ms"] = value }
        let metaData = (try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let endMs = session.endedAtMs ?? session.startedAtMs
        let publicEvents = [Event(atMs: session.startedAtMs, kind: "start")]
            + session.events.filter {
                $0.kind == "marker" && $0.atMs >= session.startedAtMs && $0.atMs <= endMs
            }.sorted { $0.atMs < $1.atMs }
            + [Event(atMs: endMs, kind: "stop")]
        let eventData = publicEvents.compactMap { event -> Data? in
            var row: [String: Any] = ["at_ms": event.atMs, "kind": event.kind]
            if event.kind == "marker" {
                if let value = event.markerId { row["marker_id"] = value }
                if let value = event.markerType { row["marker_type"] = value }
                if let value = event.text { row["text"] = value }
            }
            return try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        return [
            .init(name: "meta.json", data: metaData),
            .init(name: "events.jsonl", data: eventData),
        ]
    }
}
