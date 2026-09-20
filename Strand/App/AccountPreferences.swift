import Combine
import Foundation

/// Account-scoped choices. Server context authorization remains in ScoringContextConsent.
@MainActor
final class AccountPreferences: @MainActor ObservableObject {
    static let cycleAwarenessKey = "noopCycleAwareness"
    static let cycleAwarenessHiddenKey = "noopCycleAwarenessHidden"
    static let hrvWindowKey = "hrv.window"

    let objectWillChange = ObservableObjectPublisher()
    private let defaults: UserDefaults
    private let isCurrent: () -> Bool
    private var active = true
    private var values: [String: Bool] = [:]
    private var hrvWindow = "whole"
    private let domainName: String
    private weak var scoringPreferences: ScoringPreferenceRuntime?
    private var scoringBound = false
    private var scoringSubscription: AnyCancellable?

    init(defaults: UserDefaults, domainName: String, isCurrent: @escaping () -> Bool) {
        self.defaults = defaults
        self.domainName = domainName
        self.isCurrent = isCurrent
        guard isCurrent() else { return }
        // Read only this account's persisted choices, never registration defaults or another suite.
        let domain = defaults.persistentDomain(forName: domainName) ?? [:]
        for key in [Self.cycleAwarenessKey, Self.cycleAwarenessHiddenKey] {
            values[key] = domain[key] as? Bool ?? false
        }
        hrvWindow = domain[Self.hrvWindowKey] as? String == "deep" ? "deep" : "whole"
    }

    var cycleAwarenessEnabled: Bool {
        get { canAccess && values[Self.cycleAwarenessKey] == true }
        set { set(newValue, forKey: Self.cycleAwarenessKey) }
    }

    var cycleAwarenessHidden: Bool {
        get { canAccess && values[Self.cycleAwarenessHiddenKey] == true }
        set { set(newValue, forKey: Self.cycleAwarenessHiddenKey) }
    }

    var hrvWindowRaw: String {
        get {
            guard canAccess else { return "whole" }
            return scoringBound ? scoringPreferences?.accepted?.hrvWindowRaw ?? "whole" : hrvWindow
        }
        set {
            guard !scoringBound, canAccess, ["whole", "deep"].contains(newValue), hrvWindow != newValue else { return }
            objectWillChange.send()
            guard canAccess else { return }
            defaults.set(newValue, forKey: Self.hrvWindowKey)
            hrvWindow = newValue
        }
    }

    var algorithmChoices: ScoringAlgorithmChoices {
        if canAccess, scoringBound, let snapshot = scoringPreferences?.accepted { return snapshot.algorithmChoices }
        let domain = canAccess && !scoringBound ? defaults.persistentDomain(forName: domainName) ?? [:] : [:]
        func flag(_ key: String, _ fallback: Bool) -> Bool { domain[key] as? Bool ?? fallback }
        return .init(banisterEffortEnabled: flag("noopBanisterEffort", false),
                     useSleepStagerV2: flag("noopExperimentalSleepV2", true),
                     useMotionAwareWake: flag("noopMotionAwareWake", false),
                     daytimePersonalBaselineEnabled: flag("noopStressPersonalBaseline", false),
                     spo2CandidateDisplayEnabled: flag("noopSpo2CandidateDisplay", true))
    }

    func bindScoringPreferences(_ runtime: ScoringPreferenceRuntime) {
        guard canAccess, !scoringBound else { return }
        scoringBound = true; scoringPreferences = runtime
        scoringSubscription = runtime.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    @discardableResult
    func clearMoments() -> Bool {
        guard canAccess else { return false }
        defaults.removeObject(forKey: "moments")
        return true
    }

    func retire() {
        guard active else { return }
        active = false
        scoringSubscription = nil
        scoringPreferences = nil
        values.removeAll()
        hrvWindow = "whole"
        objectWillChange.send()
    }

    private var canAccess: Bool { active && isCurrent() }

    private func set(_ value: Bool, forKey key: String) {
        guard canAccess, values[key] != value else { return }
        objectWillChange.send()
        // A synchronous observer can replace the account while handling this notification.
        guard canAccess else { return }
        defaults.set(value, forKey: key)
        values[key] = value
    }
}
