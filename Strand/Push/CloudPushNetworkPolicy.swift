import Foundation
#if canImport(Network)
import Network
#endif

/// Wi‑Fi-only and connectivity gates for cloud push. Pure helpers mirror Android
/// `isPushNetworkAvailable` / `canStartPushConnectionTest`.
enum CloudPushNetworkPolicy {
    static func isPushNetworkAvailable(
        wifiOnly: Bool,
        isConnected: Bool,
        isWifi: Bool,
        isUnmetered: Bool
    ) -> Bool {
        isConnected && (!wifiOnly || (isWifi && isUnmetered))
    }

    static func canStartConnectionTest(
        networkAvailable: Bool,
        endpointValid: Bool,
        tokenAvailable: Bool
    ) -> Bool {
        networkAvailable && endpointValid && tokenAvailable
    }

    #if os(iOS)
    private static let path = CloudPushPathObserver()
    static func isNetworkAvailable(wifiOnly: Bool) -> Bool {
        let snapshot = path.snapshot
        return isPushNetworkAvailable(
            wifiOnly: wifiOnly,
            isConnected: snapshot.connected,
            isWifi: snapshot.wifi,
            isUnmetered: snapshot.unmetered
        )
    }
    #endif
}

#if os(iOS)
private final class CloudPushPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var value = (connected: false, wifi: false, unmetered: false)
    var snapshot: (connected: Bool, wifi: Bool, unmetered: Bool) {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.value = (path.status == .satisfied, path.usesInterfaceType(.wifi), !path.isExpensive && !path.isConstrained)
            self.lock.unlock()
            NotificationCenter.default.post(name: ResourceBudget.changed, object: nil)
        }
        monitor.start(queue: DispatchQueue(label: "com.noop.cloudpush.network"))
    }
}
#endif
