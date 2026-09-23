import Foundation
import WhoopProtocol
import WhoopStore

/// A protocol-tagged archive in the existing rawBatch lane. Receipt time is not a
/// sample clock; the server's waveform decoder does not accept this archive kind.
struct GenericNotificationEnvelope: Encodable {
    let format = "nara.generic-notification.v1"
    let family: String
    let serviceUUID: String
    let characteristicUUID: String
    let sessionID: String
    let sequence: Int64
    let receivedUnixSeconds: Int
    let receivedUptime: Double
    let clockQuality = "host_receipt_unverified"
    let rrProjectionStatus = "unqualified"
    let rrProjectionReason = "producer_not_implemented"
    let payload: Data
}

@MainActor
final class GenericRawCaptureEntry {
    let capture: HistoricalRawCapture
    let scope: DurableIngestScope
    static let reservationBytes = 65_536
    var streams = Streams()
    var projectionBytes = 0
    var committed = false
    var cursorCompletion: (() -> Void)?
    init(capture: HistoricalRawCapture, scope: DurableIngestScope) {
        self.capture = capture; self.scope = scope
    }
}

struct WeakGenericRawCaptureSink { weak var value: GenericRawCaptureSink? }

/// Owns the exact callback bytes before invoking the decoder. The journal owns each
/// frozen projection until the captured account's raw/decoded/debt transaction commits.
@MainActor
public final class GenericRawCaptureSink {
    private weak var journal: GenericCaptureJournal?
    let deviceID: String
    let family: String
    let sessionID: UUID
    let scope: DurableIngestScope
    private var sequence: Int64 = 0
    private var sealed = false
    private var current: GenericRawCaptureEntry?
    private var last: GenericRawCaptureEntry?
    var isOpen: Bool { !sealed && journal?.canReserveRawNotification == true }
    var cursorScope: String { scope.key }

    init(journal: GenericCaptureJournal, deviceID: String, family: String,
         sessionID: UUID, scope: DurableIngestScope) {
        self.journal = journal; self.deviceID = deviceID; self.family = family
        self.sessionID = sessionID; self.scope = scope
    }

    @discardableResult
    func capture(_ bytes: Data, serviceUUID: String, characteristicUUID: String,
                 at timestamp: Int, uptime: Double = ProcessInfo.processInfo.systemUptime,
                 decode: () -> Void) -> Bool {
        guard isOpen, let journal, current == nil, sequence < Int64.max,
              !bytes.isEmpty, bytes.count <= 512, timestamp < Int.max,
              !serviceUUID.isEmpty, serviceUUID.utf8.count <= 64,
              !characteristicUUID.isEmpty, characteristicUUID.utf8.count <= 64 else { return false }
        let envelope = GenericNotificationEnvelope(family: family, serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID, sessionID: sessionID.uuidString.lowercased(),
            sequence: sequence, receivedUnixSeconds: timestamp, receivedUptime: uptime, payload: bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(envelope) else { return false }
        let meta = RawBatchMeta(batchId: UUID().uuidString.lowercased(), deviceId: deviceID,
            clockRef: ClockRef(device: timestamp, wall: timestamp), capturedAt: timestamp,
            startTs: timestamp, endTs: timestamp + 1, frameCount: 1, byteSize: encoded.count,
            captureScope: scope)
        let entry = GenericRawCaptureEntry(capture: HistoricalRawCapture(meta: meta,
            frames: [[UInt8](encoded)]), scope: scope)
        guard journal.reserveRawNotification(entry) else { return false }
        sequence += 1
        last = entry; current = entry
        defer { current = nil }
        decode()
        return true
    }

    /// Delayed reassembly uses the last original notification as its archive dependency.
    /// Earlier fragments remain ahead of it in the same journal; no payload is manufactured.
    @discardableResult
    func persist(_ input: Streams) -> Bool {
        guard input.rrPackets.isEmpty, input.standardHrReceipts.isEmpty else { return false }
        // Frozen-v1 consumes legacy RR without a qualified beat-clock filter. A ring record
        // anchor or callback time cannot qualify individual beats. Retain the exact words
        // in the raw envelope until the generic beat adapter is implemented and validated.
        var streams = input
        streams.rr = []
        guard !streams.isEmpty else { return true }
        guard let size = try? JSONEncoder().encode(streams).count, size <= 49_152 else { return false }
        if let current {
            guard current.projectionBytes <= 49_152 - size else { return false }
            current.streams.appendCaptured(streams)
            current.projectionBytes += size
            return true
        }
        guard let last, let journal, !sealed || journal.isDrainingAcceptedBuffer else { return false }
        let entry = GenericRawCaptureEntry(capture: last.capture, scope: scope)
        entry.streams = streams
        entry.projectionBytes = size
        guard journal.reserveRawNotification(entry, acceptedProjection: true) else { return false }
        self.last = entry
        return true
    }

    /// Cursor persistence follows the entire accepted prefix. A crash after SQLite but
    /// before this callback causes a safe replay; it cannot skip uncommitted samples.
    /// One cursor writer replaces its pending value, including an explicit zero reset,
    /// so a stalled transaction cannot accumulate completion closures without bound.
    @discardableResult
    func setCursorAfterDurablePrefix(_ completion: @escaping () -> Void) -> Bool {
        guard let last else { return false }
        if last.committed { completion() } else { last.cursorCompletion = completion }
        return true
    }

    func sealIntake() { sealed = true }
}

private extension Streams {
    mutating func appendCaptured(_ other: Streams) {
        hr += other.hr; rr += other.rr; rrPackets += other.rrPackets
        standardHrReceipts += other.standardHrReceipts
        spo2 += other.spo2; skinTemp += other.skinTemp; resp += other.resp
        gravity += other.gravity; steps += other.steps; sleepState += other.sleepState
        ppgHr += other.ppgHr; ppgWaveform += other.ppgWaveform; v18Aux += other.v18Aux
        events += other.events; battery += other.battery
    }
}
