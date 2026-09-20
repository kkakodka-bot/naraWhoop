import Foundation
import XCTest
import Darwin
import NoopPush
import GRDB

enum PreferenceCrashProbe {
    private static func context() throws -> AccountSessionContext {
        try PreferenceIntentFixture.context(generation: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    }
    private static func intent(_ context: AccountSessionContext) throws -> ScoringPreferenceIntent {
        let value = try PreferenceIntentFixture.intent(context)
        return try .init(context: context, id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, predecessor: .initial,
            occurredAt: value.occurredAt, timezone: value.timezone, device: value.device, disposition: .serverCoupled,
            patch: value.patch, profilePayload: value.profile?.payload, configPayload: value.config?.payload,
            profileMutationID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            configMutationID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
    }
    static func child() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { throw ScoringInputJournal.Failure.invalidInput }
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let mode = args[3], expected = Int(args[4])!
        let context = try context()
        let layout = AccountStorageLayout(baseDirectory: root, scope: context.scope)
        let journal = try ScoringInputJournal(layout: layout,
            preferenceContext: context, isPreferenceContextCurrent: { $0 == context })
        if mode == "verify" || mode == "reopen" {
            let state = try await journal.committedPreferenceProjection()
            let status = try await journal.status()
            guard state.position.sequence == expected, status.pending == expected * 2,
                  state.entries.count == expected else { throw ScoringInputJournal.Failure.invalidInput }
            if expected == 1 {
                let frozen = try intent(context)
                let recovered = try await journal.admitPreferenceIntent(frozen, allowing: { true })
                guard state.position == frozen.position, state.entries.first?.value == frozen.patch.first?.value,
                      state.entries.first?.originGeneration == context.generation,
                      recovered.profileMutationID == frozen.profileMutationID, recovered.configMutationID == frozen.configMutationID else {
                    throw ScoringInputJournal.Failure.invalidInput
                }
                let db = try DatabaseQueue(path: layout.directory.appendingPathComponent("history-inputs.sqlite").path)
                defer { try? db.close() }
                let rows = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM input_change ORDER BY sequence") }
                guard rows.count == 2 else { throw ScoringInputJournal.Failure.invalidInput }
                for (row, pair) in zip(rows, [(frozen.profile!, frozen.profileMutationID!), (frozen.config!, frozen.configMutationID!)]) {
                    guard row["id"] as String == pair.1.uuidString.lowercased(), row["payload"] as Data == pair.0.payload,
                          row["device"] as String == pair.0.device, row["day"] as String == frozen.effectiveDay,
                          row["kind"] as String == pair.0.kind.rawValue, row["digest"] as String == pair.0.digest else {
                        throw ScoringInputJournal.Failure.invalidInput
                    }
                }
                guard recovered.profileClientRevision == (rows[0]["sequence"] as Int64),
                      recovered.configClientRevision == (rows[1]["sequence"] as Int64) else { throw ScoringInputJournal.Failure.invalidInput }
            }
            if mode == "reopen" { barrier() }
            try await journal.close()
            FileHandle.standardOutput.write(Data("VERIFIED\n".utf8))
            return
        }
        let intent = try intent(context)
        _ = try await journal.admitPreferenceIntent(intent, allowing: { true }, at: { point in
            let name: String
            switch point {
            case .intentInserted: name = "intent"
            case .firstChildInserted: name = "first-child"
            case .projectionWritten: name = "projection"
            case .beforeCommit: name = "precommit"
            case .afterCommit: name = "postcommit"
            }
            if mode == name { barrier() }
        })
        throw ScoringInputJournal.Failure.invalidInput // Every writer run must be killed at its barrier.
    }

    private static func barrier() {
        FileHandle.standardOutput.write(Data("READY\n".utf8))
        // Parent owns this pipe and sends SIGKILL; no cleanup or synthetic retirement occurs.
        _ = FileHandle.standardInput.readData(ofLength: 1)
        _exit(4)
    }

    private static func execute(root: URL, mode: String, expected: Int, killAtBarrier: Bool) throws {
        let process = Process()
        let output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--preference-crash-probe", root.path, mode, String(expected)]
        process.standardOutput = output; process.standardInput = input; process.standardError = FileHandle.standardError
        try process.run()
        let finished = PreferenceIntentSwitch()
        // Avoid hanging the suite if a regression never reaches its checkpoint.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if finished.get() { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        var marker = Data()
        while marker.last != 10 {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty { break }
            marker.append(byte)
            if marker.count > 128 { break }
        }
        let expectedMarker = killAtBarrier ? "READY\n" : "VERIFIED\n"
        XCTAssertEqual(String(data: marker, encoding: .utf8), expectedMarker, mode)
        if killAtBarrier { XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGKILL), 0) }
        process.waitUntilExit()
        finished.disable()
        XCTAssertEqual(process.terminationReason, killAtBarrier ? .uncaughtSignal : .exit, mode)
        XCTAssertEqual(process.terminationStatus, killAtBarrier ? SIGKILL : 0, mode)
        try output.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        try input.fileHandleForReading.close(); try input.fileHandleForWriting.close()
        print("Native crash checkpoint \(mode): pid=\(process.processIdentifier) status=\(process.terminationStatus)")
    }

    static func runCrashes() async throws {
        try await Task.detached {
            let base = ProcessInfo.processInfo.environment["SCORING_PREFERENCE_SCRATCH"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory
            for mode in ["intent", "first-child", "projection", "precommit", "postcommit"] {
                let root = base.appendingPathComponent("sigkill-\(mode)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let expected = mode == "postcommit" ? 1 : 0
                try execute(root: root, mode: mode, expected: expected, killAtBarrier: true)
                try execute(root: root, mode: "reopen", expected: expected, killAtBarrier: true)
                try execute(root: root, mode: "verify", expected: expected, killAtBarrier: false)
                // Preserve real WAL/database evidence (no live handles remain after child exit).
                print("SIGKILL evidence retained: \(root.path)")
            }
        }.value
    }
}
