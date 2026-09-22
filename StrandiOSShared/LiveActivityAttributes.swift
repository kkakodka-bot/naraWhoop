#if os(iOS)
import Foundation
import ActivityKit
import StrandDesign

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?
        public var finalHosted: Bool?
        public var canonicalLedger: CanonicalConsumerLedger?
        public var displayedRecovery: Int? {
            guard Bundle.main.object(forInfoDictionaryKey: "NOOPFinalHostedCompute") as? Bool == true else { return recovery }
            return finalHosted == true && canonicalLedger?.isValid == true && canonicalLedger?.permitsRead == true
                && canonicalLedger?.families["recovery"]?.permitsValue == true ? recovery : nil
        }
        public var displayedEffort: Int? {
            guard Bundle.main.object(forInfoDictionaryKey: "NOOPFinalHostedCompute") as? Bool == true else { return effort }
            return finalHosted == true && canonicalLedger?.isValid == true && canonicalLedger?.permitsRead == true
                && canonicalLedger?.families["strain_energy"]?.permitsValue == true ? effort : nil
        }

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil,
                    finalHosted: Bool? = nil, canonicalLedger: CanonicalConsumerLedger? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.finalHosted = finalHosted
            self.canonicalLedger = canonicalLedger
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif
