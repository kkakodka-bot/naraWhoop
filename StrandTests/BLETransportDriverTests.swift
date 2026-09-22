import XCTest
@testable import Strand

@MainActor
final class BLETransportDriverTests: XCTestCase {
    @MainActor
    private final class Peripheral: BLEPeripheralTransport {
        final class Service {}
        final class Characteristic {}
        let identifier: UUID
        var linkState: BLEConnectionOwner.LinkState = .disconnected
        let service = Service()
        let characteristic = Characteristic()
        var effects: [String] = []
        var writes: [(Data, Bool)] = []
        init(_ identifier: UUID = UUID()) { self.identifier = identifier }
        func owns(service: Service) -> Bool { service === self.service }
        func owns(characteristic: Characteristic) -> Bool { characteristic === self.characteristic }
        func discoverServices(_ uuids: [String]) { effects.append("services:\(uuids.joined(separator: ","))") }
        func discoverCharacteristics(_ uuids: [String]?, for service: Service) { effects.append("characteristics") }
        func setNotify(_ enabled: Bool, for characteristic: Characteristic) { effects.append("notify:\(enabled)") }
        func read(_ characteristic: Characteristic) { effects.append("read") }
        func write(_ bytes: Data, for characteristic: Characteristic, withResponse: Bool) {
            effects.append("write")
            writes.append((bytes, withResponse))
        }
    }

    @MainActor
    private final class Central: BLECentralTransport {
        var poweredOn = true
        var known: [Peripheral] = []
        var connected: [Peripheral] = []
        var requests: [(Peripheral, BLEConnectionOwner.Request)] = []
        var cancelled: [Peripheral] = []
        var effects: [String] = []
        func retrieve(_ identifiers: [UUID]) -> [Peripheral] {
            effects.append("retrieve")
            return known.filter { identifiers.contains($0.identifier) }
        }
        func retrieveConnected(_ services: [String]) -> [Peripheral] {
            effects.append("retrieveConnected")
            return connected
        }
        func scan(_ services: [String], allowDuplicates: Bool) { effects.append("scan:\(services.joined(separator: ",")):\(allowDuplicates)") }
        func stopScan() { effects.append("stopScan") }
        func connect(_ peripheral: Peripheral, request: BLEConnectionOwner.Request) {
            effects.append("connect")
            requests.append((peripheral, request))
        }
        func cancel(_ peripheral: Peripheral) { cancelled.append(peripheral) }
    }

    private typealias Driver = BLETransportDriver<Central>
    private func makeReady(_ driver: Driver, _ peripheral: Peripheral) -> BLEConnectionOwner.Token {
        XCTAssertTrue(driver.request(peripheral))
        peripheral.linkState = .connected
        XCTAssertTrue(driver.connected(peripheral))
        driver.owner.subscribing()
        driver.owner.ready()
        return driver.owner.token!
    }

    func testEveryScriptedConnectUsesOwnerRequestAndAttachesBeforeEffect() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        var attachments = 0
        driver.willSubmit = { selected, token in
            XCTAssertTrue(selected === peripheral)
            XCTAssertEqual(token, owner.token)
            XCTAssertEqual(central.requests.count, 0)
            attachments += 1
        }
        XCTAssertTrue(driver.request(peripheral))
        XCTAssertFalse(driver.request(peripheral))
        XCTAssertEqual(attachments, 1)
        XCTAssertEqual(central.requests.count, 1)
        XCTAssertEqual(central.requests[0].1.token, owner.token)
        XCTAssertTrue(central.requests[0].1.automaticReconnect)
        XCTAssertEqual(owner.phase, .pendingConnection)
    }

    func testImmediateAndDelayedFailureLeaveStandingRequestBeforeReturn() {
        var time: TimeInterval = 0
        let central = Central(), owner = BLEConnectionOwner(clock: { time }), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        driver.request(peripheral)
        time = 0.25
        XCTAssertTrue(driver.failedToConnect(peripheral))
        XCTAssertEqual(central.requests.count, 2)
        XCTAssertEqual(central.requests.last?.1.startDelay, 29.75)
        XCTAssertEqual(owner.phase, .pendingConnection)
        time = 100
        XCTAssertTrue(driver.failedToConnect(peripheral))
        XCTAssertEqual(central.requests.count, 3)
        XCTAssertEqual(central.requests.last?.1.startDelay, 0)
    }

    func testAutomaticReconnectHasNoCompetingRequest() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        let prior = makeReady(driver, peripheral)
        peripheral.linkState = .connecting
        XCTAssertTrue(driver.disconnected(peripheral, timestamp: 10, isReconnecting: true))
        XCTAssertFalse(driver.request(peripheral))
        XCTAssertEqual(central.requests.count, 1)
        XCTAssertFalse(driver.accepts(peripheral, token: prior))
        peripheral.linkState = .connected
        XCTAssertTrue(driver.connected(peripheral))
        XCTAssertEqual(owner.phase, .discovering)
    }

    func testOutOfRangeManualFallbackAndDuplicateModernDisconnect() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        _ = makeReady(driver, peripheral)
        peripheral.linkState = .disconnected
        XCTAssertTrue(driver.disconnected(peripheral, timestamp: 20, isReconnecting: false))
        let token = owner.token
        XCTAssertEqual(central.requests.count, 2)
        XCTAssertFalse(driver.disconnected(peripheral, timestamp: 20, isReconnecting: false))
        XCTAssertFalse(driver.disconnected(peripheral, timestamp: 19, isReconnecting: false))
        XCTAssertEqual(central.requests.count, 2)
        XCTAssertEqual(token, owner.token)
    }

    func testLegacyDuplicateCannotCancelModernAutomaticReconnect() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        _ = makeReady(driver, peripheral)
        peripheral.linkState = .connecting
        XCTAssertTrue(driver.disconnected(peripheral, timestamp: 20, isReconnecting: true))
        let token = owner.token
        XCTAssertFalse(driver.disconnected(peripheral, isReconnecting: false))
        XCTAssertEqual(owner.token, token)
        XCTAssertTrue(owner.automaticReconnectPending)
        XCTAssertEqual(central.requests.count, 1)
        // A newer modern callback can authoritatively end the OS reconnect.
        peripheral.linkState = .disconnected
        XCTAssertTrue(driver.disconnected(peripheral, timestamp: 21, isReconnecting: false))
        XCTAssertEqual(central.requests.count, 2)
        XCTAssertFalse(owner.automaticReconnectPending)
    }

    func testIntentionalDisconnectCleansUpOnceAndRemainsDown() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        _ = makeReady(driver, peripheral)
        var disconnects = 0
        driver.onEvent = { if case .disconnected = $0 { disconnects += 1 } }
        driver.stop()
        peripheral.linkState = .disconnected
        XCTAssertTrue(driver.disconnected(peripheral, timestamp: 1, isReconnecting: true))
        XCTAssertFalse(driver.disconnected(peripheral, timestamp: 2, isReconnecting: false))
        XCTAssertEqual(disconnects, 1)
        XCTAssertEqual(central.cancelled.count, 1)
        XCTAssertFalse(driver.request(peripheral))
        XCTAssertFalse(driver.connected(peripheral))
        driver.scan(services: ["a"])
        XCTAssertEqual(central.effects, ["connect", "stopScan"])
        XCTAssertEqual(owner.phase, .intentionallyDisconnected)
    }

    func testSynchronousTeardownCanFenceAccountShutdownBeforeFallback() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        _ = makeReady(driver, peripheral)
        driver.onEvent = { if case .disconnected = $0 { driver.stop() } }
        peripheral.linkState = .disconnected
        XCTAssertTrue(driver.disconnected(peripheral, isReconnecting: false))
        XCTAssertEqual(central.requests.count, 1)
        XCTAssertEqual(owner.phase, .intentionallyDisconnected)
    }

    func testFailureSinkPreservesErrorAndCanApplyTemporaryBondPause() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        var allowed = true
        driver.admitRequest = { _ in allowed }
        driver.request(peripheral)
        let error = NSError(domain: "synthetic", code: 10)
        driver.onEvent = { event in
            guard case let .failedToConnect(selected, actual, delay) = event else { return XCTFail() }
            XCTAssertTrue(selected === peripheral)
            XCTAssertEqual(actual as NSError?, error)
            XCTAssertNotNil(delay)
            allowed = false
        }
        XCTAssertTrue(driver.failedToConnect(peripheral, error: error))
        XCTAssertEqual(central.requests.count, 1)
        XCTAssertFalse(driver.request(peripheral))
        allowed = true
        XCTAssertTrue(driver.request(peripheral))
    }

    func testSinkSpecificStandingDelayIsNotReplacedOrDoubleSubmitted() {
        var time: TimeInterval = 0
        let central = Central(), owner = BLEConnectionOwner(clock: { time }), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        driver.request(peripheral)
        time = 100
        driver.onEvent = { event in
            if case .failedToConnect = event { XCTAssertTrue(driver.request(peripheral, startDelay: 30)) }
        }
        XCTAssertTrue(driver.failedToConnect(peripheral))
        XCTAssertEqual(central.requests.count, 2)
        XCTAssertEqual(central.requests.last?.1.startDelay, 30)
        XCTAssertEqual(owner.phase, .pendingConnection)
    }

    func testBluetoothOffOnRequiresFreshAuthorizedRequest() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        let old = makeReady(driver, peripheral)
        central.poweredOn = false
        driver.radioUnavailable()
        peripheral.linkState = .disconnected
        XCTAssertFalse(driver.request(peripheral))
        XCTAssertFalse(driver.disconnected(peripheral, isReconnecting: false))
        XCTAssertFalse(driver.accepts(peripheral, token: old))
        central.poweredOn = true
        XCTAssertTrue(driver.request(peripheral))
        XCTAssertEqual(central.requests.count, 2)
    }

    func testRestorationSelectsOnlyRegisteredObjectAndDoesNotDoubleAttach() {
        let central = Central(), owner = BLEConnectionOwner()
        let driver = Driver(central: central, owner: owner)
        let wrong = Peripheral(), selected = Peripheral()
        selected.linkState = .connected
        var restored = 0
        driver.onEvent = { event in
            if case let .restored(peripheral, token) = event {
                restored += 1
                driver.discoverServices(["a", "b"], on: peripheral, token: token)
            }
        }
        XCTAssertTrue(driver.restore([wrong, selected], registeredID: selected.identifier, accountApproved: true) === selected)
        let token = owner.token
        XCTAssertNil(driver.restore([wrong, selected], registeredID: selected.identifier, accountApproved: true))
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(owner.token, token)
        XCTAssertEqual(selected.effects, ["services:a,b"])
        XCTAssertTrue(central.cancelled.first === wrong)
        XCTAssertTrue(central.requests.isEmpty)
    }

    func testRestoredDisconnectedPeripheralGetsStandingConnection() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        XCTAssertTrue(driver.restore([peripheral], registeredID: peripheral.identifier, accountApproved: true) === peripheral)
        XCTAssertEqual(central.requests.count, 1)
        XCTAssertEqual(owner.phase, .pendingConnection)
    }

    func testRestorationLookupOrApprovalFailureDoesNotLatchRestoring() {
        for registered in [false, true] {
            let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
            let driver = Driver(central: central, owner: owner)
            XCTAssertNil(driver.restore([peripheral], registeredID: registered ? peripheral.identifier : nil,
                                        accountApproved: !registered))
            XCTAssertEqual(owner.phase, .idle)
            XCTAssertEqual(central.cancelled.count, 1)
            XCTAssertTrue(driver.request(peripheral))
        }
    }

    func testDisconnectingRestorationCallbackCreatesStandingRequestWithoutManualRetry() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        peripheral.linkState = .disconnecting
        XCTAssertTrue(driver.restore([peripheral], registeredID: peripheral.identifier, accountApproved: true) === peripheral)
        XCTAssertEqual(owner.phase, .reconnecting)
        let waiting = owner.token!
        XCTAssertFalse(owner.accepts(waiting))
        XCTAssertEqual(central.cancelled.count, 1)
        XCTAssertTrue(central.requests.isEmpty)
        XCTAssertNil(driver.restore([peripheral], registeredID: peripheral.identifier, accountApproved: true))
        XCTAssertEqual(central.cancelled.count, 1)
        peripheral.linkState = .disconnected
        XCTAssertTrue(driver.disconnected(peripheral, timestamp: 1, isReconnecting: false))
        XCTAssertEqual(central.requests.count, 1)
        XCTAssertEqual(owner.phase, .pendingConnection)
        XCTAssertNotEqual(waiting, central.requests[0].1.token)
        XCTAssertEqual(central.requests[0].1.startDelay, 0)
    }

    func testIntentionalShutdownDuringRestoredDisconnectNeverReconnects() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        peripheral.linkState = .disconnecting
        driver.restore([peripheral], registeredID: peripheral.identifier, accountApproved: true)
        driver.stop()
        peripheral.linkState = .disconnected
        XCTAssertTrue(driver.disconnected(peripheral, timestamp: 1, isReconnecting: true))
        XCTAssertTrue(central.requests.isEmpty)
        XCTAssertEqual(owner.phase, .intentionallyDisconnected)
    }

    func testAccountAdmissionRetirementDuringRestoredDisconnectBlocksFallback() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        var accountActive = true
        driver.admitRequest = { _ in accountActive }
        peripheral.linkState = .disconnecting
        driver.restore([peripheral], registeredID: peripheral.identifier, accountApproved: true)
        accountActive = false
        peripheral.linkState = .disconnected
        driver.disconnected(peripheral, timestamp: 1, isReconnecting: false)
        XCTAssertTrue(central.requests.isEmpty)
    }

    func testRestoredPendingTeardownCanAdvanceOnAuthoritativeConnectAndRecoverGatt() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        peripheral.linkState = .disconnecting
        driver.restore([peripheral], registeredID: peripheral.identifier, accountApproved: true)
        peripheral.linkState = .connected
        XCTAssertTrue(driver.connected(peripheral))
        let token = owner.token!
        var retries = 0
        driver.recover(stage: "services", on: peripheral, token: token) { retries += 1 }
        XCTAssertEqual(retries, 1)
        XCTAssertFalse(driver.disconnected(peripheral, timestamp: 1, isReconnecting: false))
        XCTAssertEqual(owner.phase, .discovering)
    }

    func testSystemConnectedAndRegisteredRetrievalPrecedeSingleFilteredScan() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        central.connected = [Peripheral()]
        central.known = [peripheral]
        XCTAssertTrue(driver.retrieveRegistered(peripheral.identifier, services: ["b", "a"]) === peripheral)
        XCTAssertEqual(central.effects, ["retrieveConnected", "retrieve"])
        driver.scan(services: ["b", "a", "b"])
        XCTAssertEqual(central.effects.last, "scan:a,b:false")
        central.effects.removeAll()
        central.connected = [peripheral]
        XCTAssertTrue(driver.retrieveRegistered(peripheral.identifier, services: ["a"]) === peripheral)
        XCTAssertEqual(central.effects, ["retrieveConnected"])
    }

    func testStaleSameIdentifierObjectCannotAdvanceConnectionOwner() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let stale = Peripheral(peripheral.identifier)
        let driver = Driver(central: central, owner: owner)
        driver.request(peripheral)
        stale.linkState = .connected
        XCTAssertFalse(driver.connected(stale))
        XCTAssertEqual(owner.phase, .pendingConnection)
        peripheral.linkState = .connected
        XCTAssertTrue(driver.connected(peripheral))
        XCTAssertFalse(driver.connected(peripheral))
    }

    func testCapturedGenerationAndForeignGattObjectsCannotDeliverEventsOrEffects() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let foreign = Peripheral()
        let driver = Driver(central: central, owner: owner)
        let old = makeReady(driver, peripheral)
        peripheral.linkState = .disconnected
        driver.disconnected(peripheral, timestamp: 1, isReconnecting: false)
        peripheral.linkState = .connected
        XCTAssertFalse(driver.connected(peripheral, originatingToken: old))
        XCTAssertTrue(driver.connected(peripheral))
        let current = owner.token!
        var events = 0
        driver.onEvent = { _ in events += 1 }
        driver.discoveredServices(peripheral, token: old, error: nil)
        driver.discoveredCharacteristics(peripheral, token: current, service: foreign.service, error: nil)
        driver.notificationChanged(peripheral, token: old, characteristic: peripheral.characteristic, notifying: true, error: nil)
        driver.valueChanged(peripheral, token: current, characteristic: foreign.characteristic, value: Data([1]), error: nil)
        driver.writeCompleted(peripheral, token: old, characteristic: peripheral.characteristic, error: nil)
        XCTAssertFalse(driver.discoverServices(["a"], on: peripheral, token: old))
        XCTAssertFalse(driver.discoverCharacteristics(nil, for: foreign.service, on: peripheral, token: current))
        XCTAssertFalse(driver.setNotify(true, for: foreign.characteristic, on: peripheral, token: current))
        XCTAssertFalse(driver.read(foreign.characteristic, on: peripheral, token: current))
        XCTAssertFalse(driver.write(Data([1]), for: peripheral.characteristic, on: peripheral, token: old, withResponse: true))
        XCTAssertEqual(events, 0)
        XCTAssertTrue(peripheral.effects.isEmpty)
    }

    func testDiscoveryErrorsExecuteBoundedRealEffectsThenOneCancel() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        _ = makeReady(driver, peripheral)
        let token = owner.token!
        driver.onEvent = { event in
            if case let .services(peripheral, token, error) = event, error != nil {
                driver.recover(stage: "services", on: peripheral, token: token) {
                    driver.discoverServices(["a"], on: peripheral, token: token)
                }
            }
        }
        for _ in 0..<10 { driver.discoveredServices(peripheral, token: token, error: NSError(domain: "synthetic", code: 1)) }
        XCTAssertEqual(peripheral.effects, ["services:a", "services:a"])
        XCTAssertEqual(central.cancelled.count, 1)
        XCTAssertEqual(owner.phase, .failed)
        peripheral.linkState = .disconnected
        driver.disconnected(peripheral, isReconnecting: false)
        XCTAssertEqual(central.requests.count, 2)
    }

    func testNotificationErrorsHaveSameBoundedRecoveryEffects() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        _ = makeReady(driver, peripheral)
        let token = owner.token!
        driver.onEvent = { event in
            if case let .notification(peripheral, token, characteristic, _, error) = event, error != nil {
                driver.recover(stage: "notify", on: peripheral, token: token) {
                    driver.setNotify(true, for: characteristic, on: peripheral, token: token)
                }
            }
        }
        for _ in 0..<10 {
            driver.notificationChanged(peripheral, token: token, characteristic: peripheral.characteristic,
                                       notifying: false, error: NSError(domain: "synthetic", code: 1))
        }
        XCTAssertEqual(peripheral.effects, ["notify:true", "notify:true"])
        XCTAssertEqual(central.cancelled.count, 1)
    }

    func testCharacteristicDiscoveryRetriesAreBoundedForCurrentService() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        _ = makeReady(driver, peripheral)
        let token = owner.token!
        driver.onEvent = { event in
            if case let .characteristics(peripheral, token, service, error) = event, error != nil {
                driver.recover(stage: "characteristics", on: peripheral, token: token) {
                    driver.discoverCharacteristics(["command", "history"], for: service, on: peripheral, token: token)
                }
            }
        }
        for _ in 0..<10 {
            driver.discoveredCharacteristics(peripheral, token: token, service: peripheral.service,
                                             error: NSError(domain: "synthetic", code: 1))
        }
        XCTAssertEqual(peripheral.effects, ["characteristics", "characteristics"])
        XCTAssertEqual(central.cancelled.count, 1)
        XCTAssertEqual(owner.phase, .failed)
    }

    func testHistoryWriteEffectRequiresOwnerReadiness() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        driver.request(peripheral)
        peripheral.linkState = .connected
        driver.connected(peripheral)
        let token = owner.token!
        func history() -> Bool {
            driver.write(Data([22]), for: peripheral.characteristic, on: peripheral,
                         token: token, withResponse: true, requiresHistoryReady: true)
        }
        XCTAssertFalse(history())
        owner.subscribing()
        XCTAssertFalse(history())
        XCTAssertTrue(driver.setNotify(true, for: peripheral.characteristic, on: peripheral, token: token))
        XCTAssertFalse(history())
        // The manager alone determines its firmware's complete confirmed notification set.
        // The transport enforces the resulting ready boundary on actual history writes.
        owner.ready()
        XCTAssertTrue(history())
        XCTAssertEqual(peripheral.writes.count, 1)
        XCTAssertEqual(peripheral.writes[0].0, Data([22]))
        XCTAssertTrue(peripheral.writes[0].1)
    }

    func testWriteBookkeepingRunsOnlyAfterFinalAdmissionAndBeforeNativeEffect() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral(), foreign = Peripheral()
        let driver = Driver(central: central, owner: owner)
        let token = makeReady(driver, peripheral)
        var queued = 0
        let before: () -> Void = {
            XCTAssertTrue(peripheral.writes.isEmpty)
            queued += 1
        }
        XCTAssertFalse(driver.write(Data([1]), for: foreign.characteristic, on: peripheral, token: token,
                                    withResponse: true, beforeSubmission: before))
        XCTAssertEqual(queued, 0)
        XCTAssertTrue(driver.write(Data([1]), for: peripheral.characteristic, on: peripheral, token: token,
                                   withResponse: true, beforeSubmission: before))
        XCTAssertEqual(queued, 1)
        XCTAssertEqual(peripheral.writes.count, 1)
        driver.stop()
        XCTAssertFalse(driver.write(Data([2]), for: peripheral.characteristic, on: peripheral, token: token,
                                    withResponse: true, beforeSubmission: { queued += 1 }))
        XCTAssertEqual(queued, 1)
        XCTAssertEqual(peripheral.writes.count, 1)
    }

    func testProductionNotificationControllerRearmsThroughDriverBeforeHistoryEffect() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        let subscriptions = BLENotificationController<String>()
        driver.request(peripheral)
        peripheral.linkState = .connected
        driver.connected(peripheral)
        owner.subscribing()
        let token = owner.token!
        let submit: (Bool) -> Bool = { enabled in
            driver.setNotify(enabled, for: peripheral.characteristic, on: peripheral, token: token)
        }
        driver.onEvent = { event in
            guard case let .notification(_, callbackToken, _, notifying, error) = event else { return }
            let observation = subscriptions.observed("history", isNotifying: notifying,
                succeeded: error == nil, token: callbackToken, submit: submit)
            if observation == .confirmed { owner.ready() }
        }
        func history() -> Bool {
            driver.write(Data([22]), for: peripheral.characteristic, on: peripheral, token: token,
                         withResponse: true, requiresHistoryReady: true)
        }
        subscriptions.request("history", isNotifying: true, token: token, submit: submit)
        driver.notificationChanged(peripheral, token: token, characteristic: peripheral.characteristic, notifying: true, error: nil)
        XCTAssertFalse(history())
        driver.notificationChanged(peripheral, token: token, characteristic: peripheral.characteristic, notifying: false, error: nil)
        driver.notificationChanged(peripheral, token: token, characteristic: peripheral.characteristic, notifying: false, error: nil)
        XCTAssertFalse(history())
        XCTAssertEqual(peripheral.effects, ["notify:false", "notify:true"])
        driver.notificationChanged(peripheral, token: token, characteristic: peripheral.characteristic, notifying: true, error: nil)
        XCTAssertTrue(history())
        XCTAssertEqual(peripheral.writes.count, 1)
    }

    func testDelegateEventsPreserveArrivalOrderValuesAndErrors() {
        let central = Central(), owner = BLEConnectionOwner(), peripheral = Peripheral()
        let driver = Driver(central: central, owner: owner)
        let token = makeReady(driver, peripheral)
        var arrivals: [String] = []
        let error = NSError(domain: "synthetic", code: 7)
        driver.onEvent = { event in
            switch event {
            case let .services(_, _, actual):
                XCTAssertEqual(actual as NSError?, error); arrivals.append("services")
            case let .characteristics(_, _, service, _):
                XCTAssertTrue(service === peripheral.service); arrivals.append("characteristics")
            case let .notification(_, _, _, notifying, _):
                XCTAssertTrue(notifying); arrivals.append("notification")
            case let .value(_, _, _, value, _):
                XCTAssertEqual(value, Data([1, 2])); arrivals.append("value")
            case let .write(_, _, _, actual):
                XCTAssertEqual(actual as NSError?, error); arrivals.append("write")
            default: XCTFail("unexpected event")
            }
        }
        driver.discoveredServices(peripheral, token: token, error: error)
        driver.discoveredCharacteristics(peripheral, token: token, service: peripheral.service, error: nil)
        driver.notificationChanged(peripheral, token: token, characteristic: peripheral.characteristic, notifying: true, error: nil)
        driver.valueChanged(peripheral, token: token, characteristic: peripheral.characteristic, value: Data([1, 2]), error: nil)
        driver.writeCompleted(peripheral, token: token, characteristic: peripheral.characteristic, error: error)
        XCTAssertEqual(arrivals, ["services", "characteristics", "notification", "value", "write"])
    }

    func testAccountDeviceReplacementRejectsOldObjectAndCallbacks() {
        let central = Central(), owner = BLEConnectionOwner(), old = Peripheral(), replacement = Peripheral()
        let driver = Driver(central: central, owner: owner)
        let oldToken = makeReady(driver, old)
        driver.stop()
        owner.allowExplicitConnection()
        XCTAssertTrue(driver.request(replacement))
        XCTAssertFalse(driver.connected(old))
        old.linkState = .disconnected
        XCTAssertFalse(driver.disconnected(old, timestamp: 1, isReconnecting: true))
        XCTAssertFalse(driver.accepts(old, token: oldToken))
        replacement.linkState = .connected
        XCTAssertTrue(driver.connected(replacement))
        XCTAssertTrue(driver.accepts(replacement, token: owner.token!))
    }
}
