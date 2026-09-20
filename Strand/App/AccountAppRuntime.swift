import Combine
import Foundation
import NoopPush
#if os(iOS)
import WidgetKit
#endif

/// A writer, BLE central and presentation tree never change owners in place.
@MainActor
final class AccountAppRuntime: ObservableObject {
    static let shared = AccountAppRuntime()

    struct ModelRequest {
        let context: AccountSessionContext?
        let layout: AccountStorageLayout?
        let captureAllowed: Bool
        let isCurrent: (AccountSessionContext?) -> Bool
    }

    @MainActor
    struct Dependencies {
        enum ExternalEffects { case live, inert }
        var snapshot: () -> AccountIdentitySnapshot
        var observeIdentity: (@escaping @MainActor () -> Void) -> AnyCancellable
        var layout: (AccountScope?) throws -> AccountStorageLayout
        var makeModel: (ModelRequest) -> AppModel = { request in
            AccountAppRuntime.buildModel(context: request.context, layout: request.layout,
                captureAllowed: request.captureAllowed, isCurrent: request.isCurrent)
        }
        var retireModel: (AppModel) -> (@MainActor () async -> Bool) = { model in
            let capturedGeneric = model.shutdownForAccountChange()
            let capturedBLE = model.ble
            return {
                let bleDrained = await capturedBLE.drainCaptureAfterAccountChange()
                let genericDrained = await capturedGeneric?.drain() ?? true
                return bleDrained && genericDrained
            }
        }
        var externalEffects: ExternalEffects

        static var live: Self {
            Self(snapshot: { CloudAuthClient.identitySnapshot() }, observeIdentity: { changed in
                NotificationCenter.default.publisher(for: CloudAuthClient.identityDidChange)
                    .receive(on: DispatchQueue.main).sink { _ in changed() }
            }, layout: { try StorePaths.accountLayout(scope: $0) }, externalEffects: .live)
        }
    }

    @Published private(set) var model: AppModel
    @Published private(set) var generation: UUID
    @Published private(set) var storageError: String?
    #if os(iOS)
    private var healthBridge: HealthKitBridge?
    var health: HealthKitBridge {
        guard let healthBridge else { preconditionFailure("HealthKit is unavailable in an inert runtime") }
        return healthBridge
    }
    #endif
    private var identity: AccountIdentitySnapshot
    private var subscription: AnyCancellable?
    private var policySubscription: AnyCancellable?
    private var preparation: Task<Void, Never>?
    private var retirement: Task<Void, Never>?
    private var background: CloudPushBackgroundRuntime?
    private var foreground = false
    private var drainingBackground: [String: CloudPushBackgroundRuntime] = [:]
    private let dependencies: Dependencies
    private let retiredCapture: RetiredCaptureDrain
    private var backgroundStorageError: String?
    private var lastPolicyKey = ""
    private var lastScoringConfigurationKey = ""
    private var replacementPending = false

    private convenience init() { self.init(dependencies: .live) }

    init(dependencies: Dependencies, retiredCapture: RetiredCaptureDrain? = nil) {
        self.dependencies = dependencies
        self.retiredCapture = retiredCapture ?? RetiredCaptureDrain()
        let identity = dependencies.snapshot()
        self.identity = identity
        self.generation = identity.generation
        let layout = try? dependencies.layout(identity.scope)
        let snapshot = dependencies.snapshot
        let candidate = dependencies.makeModel(ModelRequest(context: identity.context, layout: layout,
            captureAllowed: self.retiredCapture.pendingCount == 0,
            isCurrent: { snapshot().context == $0 }))
        let initialIsCurrent = dependencies.snapshot() == identity
        let rejectedDrain: (@MainActor () async -> Bool)?
        let model: AppModel
        if initialIsCurrent {
            rejectedDrain = nil
            model = candidate
        } else {
            let drain = dependencies.retireModel(candidate)
            rejectedDrain = candidate.captureAdmissionEnabled ? drain : nil
            // Never publish the rejected account's settings, even for the first synchronous read.
            model = dependencies.makeModel(ModelRequest(context: nil, layout: nil,
                captureAllowed: false, isCurrent: { _ in false }))
            replacementPending = true
        }
        self.model = model
        #if os(iOS)
        if dependencies.externalEffects == .live {
            self.healthBridge = HealthKitBridge(repo: model.repo, appleDeviceId: model.appleDeviceId,
                                      noopDeviceId: model.deviceId, defaults: model.accountDefaults,
                                      accountNamespace: model.accountStorage?.scope?.namespace, accountConsentRequired: true,
                                      caffeineLog: model.caffeineLog)
            if !initialIsCurrent { self.healthBridge?.shutdownForAccountChange() }
        }
        #endif
        self.retiredCapture.didChange = { [weak self] count in
            self?.refreshStorageError()
            if count == 0 { Task { [weak self] in self?.replaceIfNeeded() } }
        }
        if let rejectedDrain { self.retiredCapture.retain(id: identity.generation, drain: rejectedDrain) }
        subscription = dependencies.observeIdentity { [weak self] in self?.replaceIfNeeded() }
        if dependencies.externalEffects == .live {
            policySubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reconcilePolicyIfChanged() }
        }
        if initialIsCurrent { configureRuntime() }
        // An auth transition may occur between capture and observer installation.
        Task { [weak self] in self?.replaceIfNeeded() }
    }

    static func buildModel(context: AccountSessionContext?, layout: AccountStorageLayout?,
                           captureAllowed: Bool = true,
                           isCurrent: @escaping (AccountSessionContext?) -> Bool = { $0 == CloudAuthClient.currentContext() },
                           beforeConstruction: (() -> Void)? = nil) -> AppModel {
        beforeConstruction?()
        return AppModel(storageLayout: layout, context: context,
                        presentationAllowed: context != nil && layout != nil,
                        captureAllowed: captureAllowed, isCurrent: isCurrent)
    }

    private func replaceIfNeeded() {
        let next = dependencies.snapshot()
        let resumeCapture = !model.captureAdmissionEnabled && next.context != nil
            && retiredCapture.pendingCount == 0 && model.accountStorage?.scope == next.scope
        guard next != identity || resumeCapture || replacementPending else { return }
        replacementPending = false
        let previousPreparation = preparation
        previousPreparation?.cancel()
        retireCapture(of: model, generation: generation)
        #if os(iOS)
        healthBridge?.shutdownForAccountChange()
        #endif
        if dependencies.externalEffects == .live, let old = CloudPushBackgroundRuntime.install(nil) {
            drainingBackground[old.identifier] = old
            let previousRetirement = retirement
            retirement = Task { [weak self] in
                await previousRetirement?.value
                await old.retire()
                if self?.drainingBackground[old.identifier] === old {
                    self?.drainingBackground.removeValue(forKey: old.identifier)
                }
            }
        }
        background = nil
        identity = next
        let layout = try? dependencies.layout(next.scope)
        // Only one capture-enabled generation can await a failed final write. Further account
        // changes remain presentation-only until that exact old writer reports durable success.
        let snapshot = dependencies.snapshot
        let replacement = dependencies.makeModel(ModelRequest(context: next.context, layout: layout,
            captureAllowed: retiredCapture.pendingCount == 0, isCurrent: { snapshot().context == $0 }))
        guard dependencies.snapshot() == next else {
            retireCapture(of: replacement, generation: next.generation)
            let neutral = dependencies.makeModel(ModelRequest(context: nil, layout: nil,
                captureAllowed: false, isCurrent: { _ in false }))
            #if os(iOS)
            if dependencies.externalEffects == .live {
                healthBridge = HealthKitBridge(repo: neutral.repo, appleDeviceId: neutral.appleDeviceId,
                    noopDeviceId: neutral.deviceId, defaults: neutral.accountDefaults,
                    accountNamespace: nil, accountConsentRequired: true, caffeineLog: neutral.caffeineLog)
                healthBridge?.shutdownForAccountChange()
            }
            #endif
            // Retirement fences writes, but does not erase the old model's private presentation.
            // Publish neutral state now; a fresh view identity also discards retained screen state.
            model = neutral
            generation = UUID()
            replacementPending = true
            Task { [weak self] in self?.replaceIfNeeded() }
            return
        }
        #if os(iOS)
        if dependencies.externalEffects == .live {
            healthBridge = HealthKitBridge(repo: replacement.repo, appleDeviceId: replacement.appleDeviceId,
                                 noopDeviceId: replacement.deviceId, defaults: replacement.accountDefaults,
                                 accountNamespace: next.scope?.namespace, accountConsentRequired: true,
                                 caffeineLog: replacement.caffeineLog)
        }
        #endif
        model = replacement
        generation = next.generation
        configureRuntime(after: previousPreparation)
    }

    private func configureRuntime(after previousPreparation: Task<Void, Never>? = nil) {
        guard dependencies.externalEffects == .live else { return }
        ScheduledDebugExport.configureAccount(model.accountStorage)
        guard !AppRuntimeMode.isUnitTesting else { return }
        model.setForeground(foreground)
        #if os(iOS)
        WidgetSnapshot.activateAccount(namespace: identity.scope?.namespace)
        WidgetCenter.shared.reloadAllTimelines()
        let health = self.health
        model.healthWriteBack = { [weak health] admission in
            await health?.writeBackAfterNewData(dependentAdmission: admission) ?? false
        }
        #endif
        guard let context = identity.context, let layout = model.accountStorage else { return }
        let pendingRetirement = retirement
        preparation = Task { [weak self] in
            do {
                // Cancelled construction may already own this stable session identifier.
                await previousPreparation?.value
                await pendingRetirement?.value
                guard !Task.isCancelled, CloudAuthClient.isCurrent(context) else { return }
                let runtime = try await Task.detached(priority: .utility) {
                    try layout.prepare()
                    return try CloudPushBackgroundRuntime(context: context, layout: layout,
                        authorize: { captured in
                            let authorized = try await CloudAuthClient.authorizedSession()
                            guard authorized.context == captured else { throw AccountAuthError.staleOperation }
                            return authorized.accessToken
                        }, isCurrent: { CloudAuthClient.isCurrent($0) },
                        policy: { .current(wifiOnly: CloudPushSettings.wifiOnly,
                            enabled: CloudPushSettings.isEnabled && CloudPushSettings.termsAccepted) })
                }.value
                guard let self, !Task.isCancelled, CloudAuthClient.isCurrent(context),
                      self.identity.context == context else {
                    await runtime.retire()
                    return
                }
                if let previous = CloudPushBackgroundRuntime.install(runtime) {
                    await previous.retire()
                }
                guard !Task.isCancelled, CloudAuthClient.isCurrent(context),
                      self.identity.context == context else {
                    await runtime.retire()
                    return
                }
                self.background = runtime
                self.backgroundStorageError = nil
                self.refreshStorageError()
                try await runtime.reconcile()
            } catch {
                guard let self, CloudAuthClient.isCurrent(context) else { return }
                self.backgroundStorageError = "Account transfer storage is unavailable. Pending data was retained."
                self.refreshStorageError()
            }
        }
    }

    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        if dependencies.externalEffects == .live { model.setForeground(foreground) }
        if foreground { Task { await retiredCapture.retry() } }
    }

    private func retireCapture(of model: AppModel, generation: UUID) {
        let drain = dependencies.retireModel(model)
        guard model.captureAdmissionEnabled else { return }
        retiredCapture.retain(id: generation, drain: drain)
    }

    private func refreshStorageError() {
        storageError = retiredCapture.pendingCount > 0
            ? "Capture is paused while previously captured data waits for local storage. Accounts remain isolated."
            : backgroundStorageError
    }

    private func reconcilePolicyIfChanged() {
        // Algorithm preferences can change without a network-policy change. Compare only the
        // relevant values: high-frequency diagnostic defaults must not keep resetting the debounce.
        let configuration = model.scoringConfigurationKey
        if configuration != lastScoringConfigurationKey {
            lastScoringConfigurationKey = configuration
            model.scheduleScoringProfileInputs()
        }
        let key = "\(CloudPushSettings.isEnabled):\(CloudPushSettings.termsAccepted):\(CloudPushSettings.wifiOnly)"
        guard key != lastPolicyKey else { return }
        lastPolicyKey = key
        model.scoringInputs?.policyChanged()
        model.scheduleScoringProfileInputs()
        Task { await CloudPushBackgroundRuntime.reconcileActive() }
    }

    #if os(iOS)
    /// Unknown/previous owners are never rebound to the current account. Their files remain on disk.
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard dependencies.externalEffects == .live else { completion(); return }
        if let background, background.handleEvents(identifier: identifier, completionHandler: completion) { return }
        if let previous = drainingBackground[identifier],
           previous.handleEvents(identifier: identifier, completionHandler: completion) { return }
        Task {
            await preparation?.value
            await retirement?.value
            if let background, background.handleEvents(identifier: identifier, completionHandler: completion) { return }
            if !CloudPushBackgroundRuntime.drainEvents(identifier: identifier, completionHandler: completion) {
                completion()
            }
        }
    }
    #endif
}
