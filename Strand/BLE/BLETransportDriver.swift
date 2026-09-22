import Foundation

@MainActor
protocol BLEPeripheralTransport: AnyObject {
    associatedtype Service
    associatedtype Characteristic
    var identifier: UUID { get }
    var linkState: BLEConnectionOwner.LinkState { get }
    func owns(service: Service) -> Bool
    func owns(characteristic: Characteristic) -> Bool
    func discoverServices(_ uuids: [String])
    func discoverCharacteristics(_ uuids: [String]?, for service: Service)
    func setNotify(_ enabled: Bool, for characteristic: Characteristic)
    func read(_ characteristic: Characteristic)
    func write(_ bytes: Data, for characteristic: Characteristic, withResponse: Bool)
}

@MainActor
protocol BLECentralTransport {
    associatedtype Peripheral: BLEPeripheralTransport
    var poweredOn: Bool { get }
    func retrieve(_ identifiers: [UUID]) -> [Peripheral]
    func retrieveConnected(_ services: [String]) -> [Peripheral]
    func scan(_ services: [String], allowDuplicates: Bool)
    func stopScan()
    func connect(_ peripheral: Peripheral, request: BLEConnectionOwner.Request)
    func cancel(_ peripheral: Peripheral)
}

/// Executes the connection owner's effects and admits delegate events at the same boundary.
/// Native Core Bluetooth central callbacks have no generation identifier; callers may supply
/// one only when their event source actually retained it, never by relabeling a native callback.
@MainActor
final class BLETransportDriver<Central: BLECentralTransport> {
    typealias Peripheral = Central.Peripheral
    typealias Token = BLEConnectionOwner.Token
    enum Event {
        case connected(Peripheral, Token)
        case restored(Peripheral, Token)
        case setupExpired(Peripheral)
        case disconnected(Peripheral, Error?, isReconnecting: Bool, retryDelay: TimeInterval?)
        case failedToConnect(Peripheral, Error?, retryDelay: TimeInterval?)
        case services(Peripheral, Token, Error?)
        case characteristics(Peripheral, Token, Peripheral.Service, Error?)
        case notification(Peripheral, Token, Peripheral.Characteristic, Bool, Error?)
        case value(Peripheral, Token, Peripheral.Characteristic, Data?, Error?)
        case write(Peripheral, Token, Peripheral.Characteristic, Error?)
        case restorationRejected
    }

    let central: Central
    let owner: BLEConnectionOwner
    private(set) var peripheral: Peripheral?
    var onEvent: ((Event) -> Void)?
    var willSubmit: ((Peripheral, Token) -> Void)?
    /// The manager's account/device approval and temporary bond-pause fences still apply
    /// to synchronous fallback effects; a delegate teardown may change them reentrantly.
    var admitRequest: ((Peripheral) -> Bool)?
    private var lastDisconnectTimestamp: TimeInterval?
    private var intentionalDisconnectDelivered = false
    private var setupCancellationPending: (peripheral: Peripheral, retiredToken: Token)?

    init(central: Central, owner: BLEConnectionOwner) {
        self.central = central
        self.owner = owner
    }

    @discardableResult
    func request(_ peripheral: Peripheral, startDelay: TimeInterval = 0) -> Bool {
        submitRequest(peripheral, startDelay: startDelay, cancelledLocalLink: false)
    }

    private func submitRequest(_ peripheral: Peripheral, startDelay: TimeInterval,
                               cancelledLocalLink: Bool) -> Bool {
        guard central.poweredOn, admitRequest?(peripheral) ?? true else { return false }
        return owner.request(peripheral.identifier, link: cancelledLocalLink ? .disconnected : peripheral.linkState,
                             startDelay: startDelay) { request in
            if self.peripheral !== peripheral { lastDisconnectTimestamp = nil }
            self.peripheral = peripheral
            intentionalDisconnectDelivered = false
            willSubmit?(peripheral, request.token)
            central.connect(peripheral, request: request)
        }
    }

    /// Ownership is resolved by the account's registry before this method is called.
    /// Exact selection and rejection are shared by the native and scripted transports.
    @discardableResult
    func restore(_ candidates: [Peripheral], registeredID: UUID?, accountApproved: Bool) -> Peripheral? {
        guard owner.phase == .restoring || owner.beginRestoration() else { return nil }
        guard accountApproved, let registeredID,
              let selected = candidates.first(where: { $0.identifier == registeredID }) else {
            for candidate in candidates { central.cancel(candidate) }
            owner.restorationFailed()
            onEvent?(.restorationRejected)
            return nil
        }
        for candidate in candidates where candidate !== selected { central.cancel(candidate) }
        peripheral = selected
        if selected.linkState == .disconnecting {
            guard let token = owner.adoptRestoredTeardown(selected.identifier) else { return nil }
            intentionalDisconnectDelivered = false
            willSubmit?(selected, token)
            // Adopt and fence the restored teardown, then leave the standing request now.
            // A missing cancellation callback cannot consume the only restored wake.
            _ = expireSetup(on: selected, token: token)
        } else if selected.linkState == .connected {
            guard let token = owner.attachRestored(selected.identifier) else { return nil }
            intentionalDisconnectDelivered = false
            willSubmit?(selected, token)
            onEvent?(.restored(selected, token))
        } else if central.poweredOn {
            guard request(selected) else {
                owner.restorationFailed()
                onEvent?(.restorationRejected)
                return nil
            }
        } else { owner.radioUnavailable() }
        return selected
    }

    /// Registered/system retrieval precedes a single filtered scan. Policy authorization stays
    /// with the account owner; a nil registered identifier cannot adopt an arbitrary device.
    @discardableResult
    func retrieveRegistered(_ identifier: UUID, services: [String]) -> Peripheral? {
        if let connected = central.retrieveConnected(services).first(where: { $0.identifier == identifier }) {
            return connected
        }
        return central.retrieve([identifier]).first(where: { $0.identifier == identifier })
    }

    func scan(services: [String], allowDuplicates: Bool = false) {
        guard central.poweredOn, !owner.intentionallyStopped else { return }
        central.scan(Array(Set(services)).sorted(), allowDuplicates: allowDuplicates)
    }

    func stop() {
        owner.stop()
        central.stopScan()
        if let peripheral { central.cancel(peripheral) }
    }

    func radioUnavailable() { setupCancellationPending = nil; owner.radioUnavailable() }

    @discardableResult
    func connected(_ peripheral: Peripheral, originatingToken: Token? = nil) -> Bool {
        // Validate the actual object before advancing ownership. A stale same-UUID object
        // must not leave the current owner stuck in discovery.
        guard peripheral === self.peripheral, peripheral.linkState == .connected,
              originatingToken == nil || originatingToken == owner.token,
              owner.connected(peripheral.identifier), let token = owner.token else { return false }
        intentionalDisconnectDelivered = false
        setupCancellationPending = nil
        onEvent?(.connected(peripheral, token))
        return true
    }

    @discardableResult
    func disconnected(_ peripheral: Peripheral, error: Error? = nil, timestamp: TimeInterval? = nil,
                      isReconnecting: Bool, originatingToken: Token? = nil) -> Bool {
        let cancelledSetup = setupCancellationPending.map {
            $0.peripheral === peripheral && (originatingToken == nil || originatingToken == $0.retiredToken)
        } ?? false
        guard peripheral === self.peripheral, peripheral.linkState != .connected,
              originatingToken == nil || originatingToken == owner.token || cancelledSetup else { return false }
        // On supported systems the modern callback is authoritative about automatic
        // reconnect. A duplicate legacy callback has no timestamp or reconnect flag
        // and must not replace an OS-owned reconnect with a manual connection.
        if timestamp == nil, owner.automaticReconnectPending { return false }
        if let timestamp {
            guard lastDisconnectTimestamp.map({ timestamp > $0 }) ?? true else { return false }
            lastDisconnectTimestamp = timestamp
        }
        if owner.intentionallyStopped {
            setupCancellationPending = nil
            guard !intentionalDisconnectDelivered else { return false }
            intentionalDisconnectDelivered = true
            onEvent?(.disconnected(peripheral, error, isReconnecting: false, retryDelay: nil))
            return true
        }
        if cancelledSetup {
            // cancelPeripheralConnection is nonblocking. Its eventual callback acknowledges
            // the old local cancellation; it must not consume the replacement standing request.
            setupCancellationPending = nil
            return false
        }
        guard owner.token?.peripheralID == peripheral.identifier,
              owner.phase != .bluetoothUnavailable else { return false }
        let delay = owner.disconnected(peripheral.identifier, isReconnecting: isReconnecting)
        // Teardown is synchronous. It may stop the owner for logout, approval failure, or
        // a bounded bond-loop pause; request then respects that fence before touching CB.
        onEvent?(.disconnected(peripheral, error, isReconnecting: isReconnecting, retryDelay: delay))
        if let delay { request(peripheral, startDelay: delay) }
        return true
    }

    @discardableResult
    func failedToConnect(_ peripheral: Peripheral, error: Error? = nil, originatingToken: Token? = nil) -> Bool {
        guard peripheral === self.peripheral, peripheral.linkState != .connected,
              originatingToken == nil || originatingToken == owner.token,
              [.pendingConnection, .connecting].contains(owner.phase),
              owner.token?.peripheralID == peripheral.identifier else { return false }
        let delay = owner.disconnected(peripheral.identifier, isReconnecting: false)
        onEvent?(.failedToConnect(peripheral, error, retryDelay: delay))
        if let delay { request(peripheral, startDelay: delay) }
        return true
    }

    func recover(stage: String, on peripheral: Peripheral, token: Token, retry: () -> Void) {
        guard accepts(peripheral, token: token) else { return }
        owner.recover(stage: stage, retry: retry) { _ = expireSetup(on: peripheral, token: token) }
    }

    @discardableResult
    func expireSetup(on peripheral: Peripheral, token: Token) -> Bool {
        guard peripheral === self.peripheral, owner.cancelSetup(token) else { return false }
        setupCancellationPending = (peripheral, token)
        central.cancel(peripheral)
        onEvent?(.setupExpired(peripheral))
        // Apple defines a cancelled local link as effectively disconnected even while the
        // physical link/state is still disconnecting. One delayed request belongs to the OS;
        // no app timer is needed, and repeated assertion denial cannot create a tight loop.
        return submitRequest(peripheral, startDelay: 30, cancelledLocalLink: true)
    }

    func accepts(_ peripheral: Peripheral, token: Token) -> Bool {
        peripheral === self.peripheral && peripheral.identifier == token.peripheralID && owner.accepts(token)
    }

    @discardableResult
    func discoverServices(_ uuids: [String], on peripheral: Peripheral, token: Token) -> Bool {
        guard accepts(peripheral, token: token) else { return false }
        peripheral.discoverServices(uuids)
        return true
    }

    @discardableResult
    func discoverCharacteristics(_ uuids: [String]?, for service: Peripheral.Service,
                                 on peripheral: Peripheral, token: Token) -> Bool {
        guard accepts(peripheral, token: token), peripheral.owns(service: service) else { return false }
        peripheral.discoverCharacteristics(uuids, for: service)
        return true
    }

    @discardableResult
    func setNotify(_ enabled: Bool, for characteristic: Peripheral.Characteristic,
                   on peripheral: Peripheral, token: Token) -> Bool {
        guard accepts(peripheral, token: token), peripheral.owns(characteristic: characteristic) else { return false }
        peripheral.setNotify(enabled, for: characteristic)
        return true
    }

    @discardableResult
    func read(_ characteristic: Peripheral.Characteristic, on peripheral: Peripheral, token: Token) -> Bool {
        guard accepts(peripheral, token: token), peripheral.owns(characteristic: characteristic) else { return false }
        peripheral.read(characteristic)
        return true
    }

    @discardableResult
    func write(_ bytes: Data, for characteristic: Peripheral.Characteristic,
               on peripheral: Peripheral, token: Token, withResponse: Bool,
               requiresHistoryReady: Bool = false, beforeSubmission: (() -> Void)? = nil) -> Bool {
        guard accepts(peripheral, token: token), peripheral.owns(characteristic: characteristic),
              !requiresHistoryReady || owner.phase == .ready else { return false }
        // Queue bookkeeping belongs after final admission but before the native effect, so
        // a refused write cannot leave a phantom entry for a later ATT completion to consume.
        beforeSubmission?()
        peripheral.write(bytes, for: characteristic, withResponse: withResponse)
        return true
    }

    func discoveredServices(_ peripheral: Peripheral, token: Token, error: Error?) {
        guard accepts(peripheral, token: token) else { return }
        onEvent?(.services(peripheral, token, error))
    }

    func discoveredCharacteristics(_ peripheral: Peripheral, token: Token,
                                  service: Peripheral.Service, error: Error?) {
        guard accepts(peripheral, token: token), peripheral.owns(service: service) else { return }
        onEvent?(.characteristics(peripheral, token, service, error))
    }

    func notificationChanged(_ peripheral: Peripheral, token: Token,
                             characteristic: Peripheral.Characteristic, notifying: Bool, error: Error?) {
        guard accepts(peripheral, token: token), peripheral.owns(characteristic: characteristic) else { return }
        onEvent?(.notification(peripheral, token, characteristic, notifying, error))
    }

    func valueChanged(_ peripheral: Peripheral, token: Token,
                      characteristic: Peripheral.Characteristic, value: Data?, error: Error?) {
        guard accepts(peripheral, token: token), peripheral.owns(characteristic: characteristic) else { return }
        onEvent?(.value(peripheral, token, characteristic, value, error))
    }

    func writeCompleted(_ peripheral: Peripheral, token: Token,
                        characteristic: Peripheral.Characteristic, error: Error?) {
        guard accepts(peripheral, token: token), peripheral.owns(characteristic: characteristic) else { return }
        onEvent?(.write(peripheral, token, characteristic, error))
    }
}
