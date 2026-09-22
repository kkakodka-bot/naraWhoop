import Foundation

/// WHOOP 5 type-40 and v18 interval words use the same 1/1024-second ticks as BLE 0x2A37.
/// Verified by matching complete native/standard beat arrays on firmware 50.41.1.0.
/// Keep this separate from WHOOP 4 decoding, whose existing millisecond contract is unchanged.
public enum Whoop5RR {
    public static func milliseconds(ticks: UInt16) -> Int {
        (Int(ticks) * 1000 + 512) / 1024
    }

    /// Labelled wire observations resolve an unknown registry entry, but cannot override another family.
    public static func usesCanonicalSource(model: String?, brand: String?, hasTaggedIntervals: Bool) -> Bool {
        if let brand, !brand.isEmpty, brand.caseInsensitiveCompare("WHOOP") != .orderedSame { return false }
        switch DeviceFamily.confirmedRegistryFamily(model: model, brand: brand) {
        case .whoop4: return false
        case .whoop5: return true
        case nil: return hasTaggedIntervals
        }
    }

}
