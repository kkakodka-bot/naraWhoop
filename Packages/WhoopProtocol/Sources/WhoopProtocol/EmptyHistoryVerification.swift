import Foundation

/// A reset is complete only after a checksum-valid, empty history session. A write
/// acknowledgement alone does not establish that the strap cleared its storage.
public struct EmptyHistoryVerification {
    public enum Outcome: Equatable {
        case waiting
        case acknowledge([UInt8])
        case empty
        case rejected
    }

    private var started = false
    private var rejected = false
    private var finished = false
    private var fragments: [String: [UInt8]] = [:]

    public init() {}

    /// Setup cannot use the normal resynchronizing decoder: silently discarding a
    /// corrupt or incomplete record would turn an unreadable history into "empty".
    public mutating func receiveNotification(_ bytes: [UInt8], characteristic: String,
                                             family: DeviceFamily) -> [Outcome] {
        guard !rejected, !finished else { return [.rejected] }
        var buffer = (fragments[characteristic] ?? []) + bytes
        var outcomes: [Outcome] = []
        while !buffer.isEmpty {
            guard buffer[0] == 0xAA else { rejected = true; return [.rejected] }
            guard buffer.count >= 4 else { break }
            let total = family == .whoop5
                ? Int(buffer[2]) + (Int(buffer[3]) << 8) + 8
                : Int(buffer[1]) + (Int(buffer[2]) << 8) + 4
            guard total >= (family == .whoop5 ? 15 : 11), total <= 8192 else {
                rejected = true
                return [.rejected]
            }
            guard buffer.count >= total else { break }
            let frame = Array(buffer.prefix(total))
            buffer.removeFirst(total)
            let outcome = receive(frame, family: family)
            if outcome == .rejected { return [.rejected] }
            if outcome == .empty {
                guard buffer.isEmpty,
                      fragments.allSatisfy({ $0.key == characteristic || $0.value.isEmpty }) else {
                    rejected = true
                    return [.rejected]
                }
            }
            outcomes.append(outcome)
        }
        fragments[characteristic] = buffer
        return outcomes
    }

    public mutating func receive(_ frame: [UInt8], family: DeviceFamily) -> Outcome {
        guard !rejected, !finished else { return .rejected }
        guard verifyFrame(frame, family: family).ok else {
            rejected = true
            return .rejected
        }
        let offset = family == .whoop5 ? 8 : 4
        guard frame.count > offset + 2 else {
            rejected = true
            return .rejected
        }
        // Events can contain the previous wearer's history too. Neither events nor
        // unknown record layouts may be acknowledged, decoded, or saved in setup.
        if frame[offset] == 47 || frame[offset] == 48 {
            rejected = true
            return .rejected
        }
        guard frame[offset] == 49 else { return .waiting }
        let parsed = parseFrame(frame, family: family)
        switch classifyHistoricalMeta(parsed) {
        case .start:
            guard !started else { rejected = true; return .rejected }
            started = true
            return .waiting
        case .end:
            let endOffset = family == .whoop5 ? 21 : 17
            guard started, frame.count >= endOffset + 8 + 4 else {
                rejected = true
                return .rejected
            }
            return .acknowledge([1] + Array(frame[endOffset..<(endOffset + 8)]))
        case .complete:
            guard started else { rejected = true; return .rejected }
            finished = true
            return .empty
        case .other:
            rejected = true
            return .rejected
        }
    }
}
