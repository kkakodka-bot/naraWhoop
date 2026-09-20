import Foundation
import XCTest
import NoopPush
import Darwin

enum PreferenceRuntimeCrashProbe {
    private static let generation = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let returnedGeneration = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let epoch = 1_794_122_999.0
    private static let dob = 631_180_800.0
    private static let patch: [ScoringPreferenceIntent.Patch] = [
        .init(key: .dateOfBirth, value: .number(dob)), .init(key: .ageExplicit, value: .boolean(true)),
        .init(key: .weightKg, value: .number(81)), .init(key: .hrvWindow, value: .text("deep")),
        .init(key: .hrvBaselineEpoch, value: .number(epoch)), .init(key: .recoveryBaselineEpoch, value: .number(epoch)),
        .init(key: .effortMethod, value: .text("BANISTER"))].sorted { $0.key.rawValue < $1.key.rawValue }

    @MainActor static func child() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, let expected = Int(args[4]) else { throw ScoringInputJournal.Failure.invalidInput }
        let root = URL(fileURLWithPath: args[2], isDirectory: true), mode = args[3]
        let recovering = mode == "reopen" || mode == "verify"
        let scope = try AccountScope(projectURL: "https://runtime-crash.invalid", userID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let context = AccountSessionContext(scope: scope, generation: recovering ? returnedGeneration : generation)
        let domain = "test.preference-runtime-crash." + root.lastPathComponent
        let f = try PreferenceRuntimeFixture(root: root, context: context, domain: domain, hooks: .init(atCommit: { point in
            if mode == "precommit" && point == .beforeCommit { barrier() }
            if mode == "postcommit" && point == .afterCommit { barrier() }
        }, beforePublication: { if mode == "before-publication" { barrier() } }, afterMirrorKey: { key in
            if mode == "mid-mirror" && key == .dateOfBirth { barrier() }
        }))
        if recovering {
            // A stale/torn mirror must not become authority after restart.
            f.defaults.set(199.0, forKey: "profile.weightKg")
            f.defaults.set("whole", forKey: "hrv.window")
            try await f.runtime.hydrate()
            guard let state = f.runtime.accepted, state.position.sequence == expected,
                  try f.intents().count == expected,
                  try f.rows("input_change").count == expected * 2,
                  try f.rows("preference_projection").count == expected * patch.count else {
                throw ScoringInputJournal.Failure.invalidInput
            }
            if expected == 1 {
                let intent = try XCTUnwrap(f.intents().first)
                guard intent.context.generation == generation, intent.patch == patch,
                      intent.occurredAt.timeIntervalSince1970 == epoch, intent.timezone == "America/Los_Angeles",
                      intent.device == PreferenceRuntimeFixture.device, intent.predecessor == .initial,
                      state.position == intent.position, state.dateOfBirth.timeIntervalSince1970 == dob,
                      state.weightKg == 81, state.hrvWindowRaw == "deep", state.hrvBaselineEpoch == epoch,
                      state.recoveryBaselineEpoch == epoch, state.algorithmChoices.banisterEffortEnabled,
                      f.defaults.double(forKey: "profile.weightKg") == 81,
                      f.defaults.string(forKey: "hrv.window") == "deep" else { throw ScoringInputJournal.Failure.invalidInput }
                let payloads = try state.payloads(at: intent.occurredAt, timezone: intent.timezone,
                    consent: .init(journalEnabled: false, cycleEnabled: false))
                guard intent.profile?.payload == payloads.profile, intent.config?.payload == payloads.config else {
                    throw ScoringInputJournal.Failure.invalidInput
                }
                let children = try f.rows("input_change").sorted { ($0["sequence"] as Int64) < ($1["sequence"] as Int64) }
                for (row, member) in zip(children, [(intent.profile!, intent.profileMutationID!), (intent.config!, intent.configMutationID!)]) {
                    guard row["id"] as String == member.1.uuidString.lowercased(), row["payload"] as Data == member.0.payload,
                          row["device"] as String == member.0.device, row["day"] as String == member.0.effectiveDay else {
                        throw ScoringInputJournal.Failure.invalidInput
                    }
                }
                // Pin immutable intent/child identities across a second process death/reopen.
                let ledger = try JSONSerialization.data(withJSONObject: [
                    "intent": try intent.encoded().base64EncodedString(),
                    "profileID": intent.profileMutationID!.uuidString, "configID": intent.configMutationID!.uuidString,
                    "profileSequence": children[0]["sequence"] as Int64, "configSequence": children[1]["sequence"] as Int64], options: [.sortedKeys])
                let proof = root.appendingPathComponent("recovered-ledger.json")
                if mode == "reopen" { try ledger.write(to: proof, options: .atomic) }
                else if try Data(contentsOf: proof) != ledger { throw ScoringInputJournal.Failure.invalidInput }
            } else if state.weightKg != 75 || state.hrvWindowRaw != "whole" {
                throw ScoringInputJournal.Failure.invalidInput
            }
            if mode == "reopen" { barrier() }
            try await f.close()
            f.defaults.removePersistentDomain(forName: domain)
            FileHandle.standardOutput.write(Data("VERIFIED\n".utf8))
            return
        }
        try await f.runtime.hydrate()
        let ticket = f.runtime.complete(f.action(patch))
        _ = try await ticket.acceptance()
        throw ScoringInputJournal.Failure.invalidInput // Writer must be killed at the selected real boundary.
    }

    private static func barrier() {
        FileHandle.standardOutput.write(Data("READY\n".utf8))
        _ = FileHandle.standardInput.readData(ofLength: 1)
        _exit(4)
    }

    private static func execute(root: URL, mode: String, expected: Int, killAtBarrier: Bool) throws {
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--preference-runtime-crash", root.path, mode, String(expected)]
        process.standardOutput = output; process.standardInput = input; process.standardError = FileHandle.standardError
        try process.run()
        let running = PreferenceRuntimeFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if running.get() { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        var marker = Data()
        while marker.last != 10 && marker.count < 128 {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty { break }; marker.append(byte)
        }
        XCTAssertEqual(String(data: marker, encoding: .utf8), killAtBarrier ? "READY\n" : "VERIFIED\n", mode)
        if killAtBarrier { XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGKILL), 0, mode) }
        process.waitUntilExit(); running.set(false)
        XCTAssertEqual(process.terminationReason, killAtBarrier ? .uncaughtSignal : .exit, mode)
        XCTAssertEqual(process.terminationStatus, killAtBarrier ? SIGKILL : 0, mode)
        try output.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        try input.fileHandleForReading.close(); try input.fileHandleForWriting.close()
        print("Runtime SIGKILL checkpoint \(mode): pid=\(process.processIdentifier) status=\(process.terminationStatus)")
    }

    static func run() async throws {
        try await Task.detached {
            let base = ProcessInfo.processInfo.environment["SCORING_PREFERENCE_SCRATCH"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory
            for mode in ["precommit", "postcommit", "before-publication", "mid-mirror"] {
                let root = base.appendingPathComponent("runtime-sigkill-\(mode)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let expected = mode == "precommit" ? 0 : 1
                try execute(root: root, mode: mode, expected: expected, killAtBarrier: true)
                try execute(root: root, mode: "reopen", expected: expected, killAtBarrier: true)
                try execute(root: root, mode: "verify", expected: expected, killAtBarrier: false)
                print("Retained runtime crash evidence: \(root.path)")
            }
        }.value
    }
}

final class PreferenceRuntimeCrashTests: XCTestCase {
    func testActualSIGKILLCommitPublicationMirrorAndSecondRecovery() async throws { try await PreferenceRuntimeCrashProbe.run() }
}
