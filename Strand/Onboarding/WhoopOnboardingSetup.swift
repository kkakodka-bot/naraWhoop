import Foundation
import Combine

/// Persists the erase intent before sending it. Relaunches verify an interrupted
/// attempt; only an explicit retry may issue another erase.
@MainActor
final class WhoopOnboardingSetup: ObservableObject {
    enum Phase: Equatable {
        case chooseDevice, pairing, resetting, verifying, ready, failed(String)
    }
    enum Action: Equatable { case erase, verify }
    private struct Checkpoint: Codable {
        var peripheralID: String
        var name: String
        var eraseIssued = false
        var verified = false
        var onboardingFinished = false
    }

    @Published private(set) var phase: Phase
    private(set) var required: Bool
    private var checkpoint: Checkpoint?
    private let checkpointURL: URL

    var selectedID: String? { checkpoint?.peripheralID }
    var selectedName: String { checkpoint?.name ?? "WHOOP" }
    var blocksData: Bool { required && phase != .ready }
    var mayConnect: Bool { !required || phase == .pairing || phase == .ready }
    var busy: Bool { phase == .pairing || phase == .resetting || phase == .verifying }

    static func hasSerialInName(_ name: String) -> Bool {
        name.uppercased().replacingOccurrences(of: "WHOOP", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .contains { $0.count >= 6 && $0.contains(where: \.isNumber) }
    }

    func permitsWrite(opcode: UInt8, payload: [UInt8]) -> Bool {
        guard required else { return false }
        switch opcode {
        case 25: return phase == .resetting && payload == Array(repeating: 0xFE, count: 8)
        case 22: return phase == .verifying && payload == [0]
        case 23: return phase == .verifying && payload.count == 9 && payload.first == 1
        default: return false
        }
    }

    init(required: Bool = !UserDefaults.standard.bool(forKey: "noop.onboarded"),
         checkpointURL: URL? = nil) {
        self.required = required
        self.checkpointURL = checkpointURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "NARA", isDirectory: true)
            .appendingPathComponent("whoop-onboarding-reset.json")
        if required, let bytes = try? Data(contentsOf: self.checkpointURL),
           let saved = try? JSONDecoder().decode(Checkpoint.self, from: bytes),
           !saved.onboardingFinished {
            checkpoint = saved
            phase = saved.verified ? .ready : .failed("Setup was interrupted. Keep your WHOOP nearby and retry to finish checking its storage.")
        } else {
            phase = required ? .chooseDevice : .ready
        }
    }

    func mayIngest(from peripheralID: String) -> Bool {
        !required || (phase == .ready && checkpoint?.peripheralID == peripheralID)
    }

    @discardableResult
    func select(id: String, name: String, serialConfirmed: Bool) -> Bool {
        guard required, !busy, serialConfirmed, UUID(uuidString: id) != nil,
              Self.hasSerialInName(name) else { return false }
        checkpoint = Checkpoint(peripheralID: id, name: name)
        guard save() else { return false }
        phase = .pairing
        return true
    }

    /// Retry preserves the erase checkpoint by default: a dropped connection must
    /// not wipe new samples every time the phone reconnects.
    func retry(eraseAgain: Bool = false) {
        guard required, !busy, checkpoint != nil else { return }
        if eraseAgain { checkpoint?.eraseIssued = false }
        guard save() else { return }
        phase = .pairing
    }

    func secureLinkReady(peripheralID: String, encrypted: Bool) -> Action? {
        guard required, phase == .pairing, encrypted,
              checkpoint?.peripheralID == peripheralID else { return nil }
        if checkpoint?.eraseIssued == true {
            phase = .verifying
            return .verify
        }
        checkpoint?.eraseIssued = true
        guard save() else { return nil }
        phase = .resetting
        return .erase
    }

    func eraseAcknowledged() {
        guard phase == .resetting else { return }
        phase = .verifying
    }

    func verifiedEmpty(peripheralID: String) {
        guard phase == .verifying, checkpoint?.peripheralID == peripheralID else { return }
        checkpoint?.verified = true
        guard save() else { return }
        phase = .ready
    }

    func fail(_ message: String) {
        guard required, phase != .ready else { return }
        phase = .failed(message)
    }

    func chooseAnotherDevice() {
        guard required, !busy else { return }
        // Keep the checkpoint on disk until another device is explicitly selected.
        phase = .chooseDevice
    }

    @discardableResult
    func finish() -> Bool {
        guard phase == .ready else { return false }
        if required {
            checkpoint?.onboardingFinished = true
            guard save() else { return false }
        }
        required = false
        return true
    }

    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
            return true
        } catch {
            phase = .failed("NARA could not save setup progress. Free some phone storage and retry. Setup cannot continue until its progress is saved.")
            return false
        }
    }
}
