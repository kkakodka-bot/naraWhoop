#if os(iOS) && canImport(MetricKit)
import Foundation
import MetricKit

/// Local, bounded OS performance evidence. This never uploads diagnostics or health records.
/// MetricKit's scroll-only ratio is not the aggregate all-animation Hitches release gate.
final class SyncMetricKitCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = SyncMetricKitCollector()
    private let writer = DispatchQueue(label: "com.frwhoop.performance-evidence", qos: .utility)
    private let lock = NSLock()
    private var started = false
    private let maximumPayloadBytes = 2 * 1024 * 1024
    private let maximumFiles = 16
    private let maximumTotalBytes = 8 * 1024 * 1024

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        writer.async { [self] in
            for payload in payloads.suffix(maximumFiles) {
                retain(payload.jsonRepresentation(), kind: "metrics",
                       begin: payload.timeStampBegin, end: payload.timeStampEnd)
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        writer.async { [self] in
            for payload in payloads.suffix(maximumFiles) {
                retain(payload.jsonRepresentation(), kind: "diagnostics",
                       begin: payload.timeStampBegin, end: payload.timeStampEnd)
            }
        }
    }

    private func retain(_ bytes: Data, kind: String, begin: Date, end: Date) {
        guard bytes.count <= maximumPayloadBytes else { return }
        let fm = FileManager.default
        do {
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            let directory = caches.appendingPathComponent("SyncPerformanceEvidence", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                 ofItemAtPath: directory.path)
            let name = "\(Int(begin.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))-\(kind).json"
            try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let entries = try fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                .compactMap { url -> (URL, Date, Int)? in
                    guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: keys),
                          values.isRegularFile == true else { return nil }
                    return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
                }.sorted { $0.1 > $1.1 }
            var used = 0
            for (index, entry) in entries.enumerated() {
                used += entry.2
                if index >= maximumFiles || used > maximumTotalBytes {
                    try fm.removeItem(at: entry.0)
                }
            }
        } catch {
            // Optional diagnostics never block BLE durability or schedule a retry loop.
        }
    }
}
#endif
