#if os(macOS)
import AppKit
import Foundation
import GRDB
import NoopPush
import StrandDesign
import SwiftUI
import XCTest
@testable import Strand

/// Select this class alone in a FRESH isolated app-host process. Do not co-run tests that
/// configure the static auth facade. The extra opt-in is an isolation attestation, not an
/// attempt to reset or inspect that facade (which could itself access stored credentials).
///
/// Required: NOOP_HERMETIC_TESTING=1, NARA_SYNC_RENDER_ISOLATED_HOST=1.
/// Visible window only: NARA_SYNC_RENDER_MANUAL=1, NARA_SYNC_RENDER_SECONDS=250 or 600.
/// No normal app root, auth configuration, network transport or hardware startup is invoked.
/// PNG attachments belong to root's nominated external xcresult; no desktop capture is used.
/// Mounted pixels/SQLite assertions are NOT a visual, click-through or accessibility PASS.
@MainActor
final class ScoringSyncControlRenderTests: XCTestCase {
    private func requireIsolatedHost() throws {
        try XCTSkipUnless(AppRuntimeMode.isUnitTesting,
                          "Requires a hermetic DEBUG app host; do not launch the normal app.")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NARA_SYNC_RENDER_ISOLATED_HOST"] == "1",
                          "Select only this class in a fresh isolated host, then explicitly attest isolation.")
        try XCTSkipUnless(NSApp != nil, "Requires an existing macOS app-host application.")
    }

    private func mounted(_ scenario: RenderScenario) async throws -> (RenderFixture, RenderWindow) {
        try requireIsolatedHost()
        let fixture = try await RenderFixture.make(scenario)
        addTeardownBlock { try await fixture.close() }
        let window = RenderWindow(root: AnyView(RenderControls(model: fixture.model)), visible: false)
        addTeardownBlock { await window.close() }
        add(XCTAttachment(string: "Synthetic retained storage: \(fixture.root.path)\nScenario: \(scenario.rawValue)"))
        await settleLayout(window)
        return (fixture, window)
    }

    private func settleLayout(_ window: RenderWindow) async {
        // Yield to actual SwiftUI tasks/AppKit layout, without blocking MainActor.
        for _ in 0..<4 {
            await Task.yield()
            window.host.layoutSubtreeIfNeeded()
        }
    }

    private func waitUntil(_ description: String, _ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for actual mounted state: " + description)
        throw RenderFailure.boundaryTimeout
    }

    private func capture(_ window: RenderWindow, name: String) throws {
        window.host.layoutSubtreeIfNeeded()
        let bounds = window.host.bounds
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        XCTAssertTrue(window.host.window === window.window)
        let bitmap = try XCTUnwrap(window.host.bitmapImageRepForCachingDisplay(in: bounds),
                                   "The actual attached NSHostingView did not provide a bitmap.")
        window.host.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 0)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + "-mounted-not-visually-reviewed"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMountedEmptyAccountAtTwoWidthsAndAppearances() async throws {
        let (fixture, window) = try await mounted(.empty)
        let consent = try XCTUnwrap(fixture.model.scoringContextConsent)
        XCTAssertNotNil(fixture.model.acceptedScoringPreferences)
        XCTAssertTrue(consent.loaded)
        XCTAssertFalse(consent.enabled(.journal))
        XCTAssertFalse(consent.enabled(.cycle))
        let conflicts = try await fixture.model.scoringInputs?.conflicts()
        XCTAssertEqual(conflicts?.count, 0)
        for (width, appearance) in [(640.0, NSAppearance.Name.aqua), (1040.0, .darkAqua)] {
            window.window.appearance = NSAppearance(named: appearance)
            window.window.setContentSize(NSSize(width: width, height: 900))
            await settleLayout(window)
            try capture(window, name: "empty-\(Int(width))-\(appearance.rawValue)")
        }
        XCTAssertEqual(fixture.transport.sendCount, 0)
        XCTAssertEqual(fixture.transport.headCount, 0)
    }

    func testMountedGuestUsesOnlyUniqueInjectedDefaults() async throws {
        let (fixture, window) = try await mounted(.guest)
        XCTAssertNil(fixture.model.accountContext)
        XCTAssertNil(fixture.model.scoringInputs)
        XCTAssertNil(fixture.model.scoringContextConsent)
        XCTAssertTrue(fixture.model.accountDefaults === fixture.defaults)
        XCTAssertTrue(fixture.defaultsDomain.hasPrefix("nara-render-guest-"))
        XCTAssertTrue(fixture.model.isAccountRuntimeActive)
        try capture(window, name: "guest-no-account-journal")
    }

    func testMountedRetiredCapturedOwnerHasNoActiveControlAuthority() async throws {
        let (fixture, window) = try await mounted(.retired)
        XCTAssertFalse(fixture.model.isAccountRuntimeActive)
        XCTAssertNil(ScoringSyncControlOwner(model: fixture.model))
        XCTAssertFalse(try XCTUnwrap(fixture.model.scoringContextConsent).gate.writeFence.isValid)
        try capture(window, name: "retired-captured-owner")
        _ = try await fixture.auditOriginals()
    }

    func testMountedActualJournalOpenBarrierThenReleasedQueue() async throws {
        let (fixture, window) = try await mounted(.journalLoading)
        try await waitUntil("production conflict-list task reaches journal opener") {
            await fixture.journalBoundary.arrivalCount > 0
        }
        XCTAssertNil(fixture.model.acceptedScoringPreferences)
        try capture(window, name: "actual-journal-open-held")
        try await fixture.releaseBarriersAndHydrate()
        let conflicts = try await fixture.model.scoringInputs?.conflicts()
        XCTAssertEqual(conflicts?.first?.queuedMutationIDs, fixture.originals.map(\.id))
        await settleLayout(window)
        try capture(window, name: "actual-journal-open-released")
        XCTAssertNotNil(fixture.model.acceptedScoringPreferences)
    }

    func testMountedThreeRealQueuedChangesPreserveDifferentDatesAndBytes() async throws {
        let (fixture, window) = try await mounted(.queue)
        let conflicts = try await fixture.model.scoringInputs?.conflicts()
        let conflict = try XCTUnwrap(conflicts?.first)
        XCTAssertEqual(conflict.queuedMutationIDs.count, 3)
        XCTAssertEqual(conflict.queuedChanges.map(\.effectiveDay), ["2026-09-16", "2026-09-17", "2026-09-18"])
        XCTAssertEqual(conflict.queuedChanges, fixture.originals.map(\.change))
        XCTAssertEqual(Set(conflict.queuedChanges.map(\.payload)).count, 3)
        XCTAssertEqual(fixture.transport.headCount, 0, "Mounting must not check a head or choose a replacement.")
        XCTAssertEqual(fixture.transport.sendCount, 0)
        try capture(window, name: "real-three-change-conflict-list")
        _ = try await fixture.auditOriginals()
    }

    func testMountedFailedRevocationUsesActualSQLiteFailureAndRetainedDenial() async throws {
        let (fixture, window) = try await mounted(.failedRevocation)
        let consent = try XCTUnwrap(fixture.model.scoringContextConsent)
        XCTAssertTrue(consent.loaded)
        XCTAssertFalse(consent.enabled(.journal))
        XCTAssertNotNil(consent.error)
        await consent.load()
        XCTAssertFalse(consent.enabled(.journal), "Reload cannot resurrect the grant after the failed denial.")
        XCTAssertNotNil(consent.error)
        await settleLayout(window)
        try capture(window, name: "real-failed-revocation-paused")
    }

    func testMountedNativeAccessibilityTextWhenHostExposesIt() async throws {
        let (_, window) = try await mounted(.empty)
        // In-process AppKit queries only: no AX permission request or cross-process UI automation.
        var observation = RenderAccessibility.read(window.host)
        for _ in 0..<25 where !observation.text.contains(String(localized: "Changes needing review")) {
            try await Task.sleep(nanoseconds: 20_000_000)
            observation = RenderAccessibility.read(window.host)
        }
        let attachment = XCTAttachment(string: observation.text)
        attachment.name = "in-process-native-accessibility-observation"
        attachment.lifetime = .keepAlways
        add(attachment)
        try XCTSkipUnless(!observation.incomplete && observation.text.contains(String(localized: "Changes needing review")),
                          "SwiftUI native text tree unavailable/incomplete in this host. Pixels are not AX/VoiceOver evidence.")
        XCTAssertTrue(observation.text.contains(String(localized: "Optional server context")))
        try await waitUntil("actual empty-list text in native accessibility tree") {
            RenderAccessibility.read(window.host).text.contains(String(localized:
                "No changes currently need conflict review. This does not confirm that all pending uploads reached the server."))
        }
    }

    func testNativeTextTokenContrastAcrossNamedSurfacesInBothAppearances() throws {
        try requireIsolatedHost()
        // Resolve the ACTUAL SwiftUI tokens through AppKit's dynamic appearance provider.
        // This measures opaque text/surface token pairs, not screenshots, custom accents,
        // arbitrary card transparency, other themes, system buttons or disabled controls.
        let texts: [(String, Color)] = [("textPrimary", StrandPalette.textPrimary),
                                      ("textSecondary", StrandPalette.textSecondary)]
        let surfaces: [(String, Color)] = [("surfaceTop", NoopVisualStyle.surfaceTop),
            ("surfaceBottom", NoopVisualStyle.surfaceBottom), ("canvas", NoopVisualStyle.canvas),
            ("inset", NoopVisualStyle.inset)]
        var observations: [String] = []
        var primaryLuminance: [Double] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            func luminance(_ token: Color) throws -> Double {
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = NSColor(token).usingColorSpace(.sRGB)
                }
                let color = try XCTUnwrap(resolved, "Native token must resolve to sRGB.")
                XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.000001,
                               "This test does not silently composite translucent tokens.")
                func linear(_ component: CGFloat) -> Double {
                    let value = Double(component)
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                    + 0.0722 * linear(color.blueComponent)
            }
            primaryLuminance.append(try luminance(StrandPalette.textPrimary))
            for (textName, token) in texts {
                let foreground = try luminance(token)
                for (surfaceName, surface) in surfaces {
                    let background = try luminance(surface)
                    let contrast = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
                    let identity = "\(name.rawValue)/\(textName)/\(surfaceName)"
                    XCTAssertGreaterThanOrEqual(contrast, 4.5, identity + " must meet normal-text AA.")
                    observations.append(identity + " = " + String(format: "%.6f:1", contrast))
                }
            }
        }
        XCTAssertLessThan(primaryLuminance[0], primaryLuminance[1],
                          "Both appearances must actually resolve; do not reuse one cached RGB value.")
        let attachment = XCTAttachment(string: observations.joined(separator: "\n"))
        attachment.name = "native-token-contrast-16-pairs-not-full-screen-validation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testManualSyntheticWindowExplicitOptInOnly() async throws {
        try requireIsolatedHost()
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["NARA_SYNC_RENDER_MANUAL"] == "1",
                          "Manual window is separately opt-in; normal mounted tests never show a window.")
        let rawSeconds = environment["NARA_SYNC_RENDER_SECONDS"] ?? "250"
        guard ["250", "600"].contains(rawSeconds), let seconds = Double(rawSeconds) else {
            XCTFail("NARA_SYNC_RENDER_SECONDS must be exactly 250 or 600.")
            return
        }
        let controller = RenderManualController()
        addTeardownBlock { try await controller.close() }
        try await controller.start()
        let window = RenderWindow(root: AnyView(RenderManualRoot(controller: controller)), visible: true)
        controller.closeWindow = { [weak window] in window?.close() }
        addTeardownBlock { await window.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !window.closed, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // There is no global application activation or normal-root replacement. A human may
        // bring this one titled window forward. Close/timeout also closes any attached sheets.
        window.close()
        try await controller.close()
        let record = XCTAttachment(string: controller.record.joined(separator: "\n"))
        record.name = "synthetic-window-storage-and-transport-record-not-a-click-verdict"
        record.lifetime = .keepAlways
        add(record)
    }
}

private enum RenderFailure: Error {
    case boundaryTimeout, missingAccount, invalidFixture, originalChanged, unexpectedReceipt
}

private enum RenderScenario: String, CaseIterable, Identifiable, Sendable {
    case empty = "Empty signed-in account"
    case queue = "Three dated queued changes"
    case unavailableHead = "Unavailable synthetic head"
    case heldHead = "Held synthetic head"
    case journalLoading = "Held actual journal open"
    case failedRevocation = "SQLite failed revocation"
    case guest = "Isolated guest"
    case retired = "Retired captured account"
    var id: String { rawValue }
    var hasQueue: Bool { [.queue, .unavailableHead, .heldHead, .journalLoading, .retired].contains(self) }
}

private final class RenderTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var sends = 0
    private var heads = 0
    func current() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
    func retire() { lock.lock(); active = false; lock.unlock() }
    func sent() { lock.lock(); sends += 1; lock.unlock() }
    func headed() { lock.lock(); heads += 1; lock.unlock() }
    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return sends }
    var headCount: Int { lock.lock(); defer { lock.unlock() }; return heads }
}

/// Only actual dependency operations wait here. No view/action phase is assigned by the test.
private actor RenderBoundary {
    private var held: Bool
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var arrivalCount = 0
    init(held: Bool) { self.held = held }
    func arrive() async throws {
        arrivalCount += 1
        try Task.checkCancellation()
        guard held else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if !held { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: { Task { await self.cancel(id) } }
        try Task.checkCancellation()
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func release() {
        held = false
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class RenderFixture {
    struct Original: Sendable { let id: String; let change: ScoringInputChange }
    let id = UUID()
    let scenario: RenderScenario
    let root: URL
    let layout: AccountStorageLayout
    let defaultsDomain: String
    let defaults: UserDefaults
    let transport: RenderTransportState
    let journalBoundary: RenderBoundary
    let headBoundary: RenderBoundary
    let model: AppModel
    private(set) var originals: [Original] = []
    private var inspector: ScoringInputJournal?
    private var closed = false

    private init(_ scenario: RenderScenario) throws {
        self.scenario = scenario
        let temporary = (ProcessInfo.processInfo.environment["NARA_SYNC_RENDER_ROOT"]
            ?? ProcessInfo.processInfo.environment["TMPDIR"]).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        root = temporary.appendingPathComponent("nara-sync-render-" + UUID().uuidString, isDirectory: true)
        let context: AccountSessionContext?
        if scenario == .guest { context = nil }
        else {
            let scope = try AccountScope(projectURL: "https://render-" + UUID().uuidString.lowercased() + ".invalid",
                                         userID: UUID().uuidString)
            context = AccountSessionContext(scope: scope, generation: UUID())
        }
        let layout = AccountStorageLayout(baseDirectory: root, scope: context?.scope)
        self.layout = layout
        defaultsDomain = context == nil ? "nara-render-guest-" + UUID().uuidString : layout.preferencesSuite
        guard let defaults = UserDefaults(suiteName: defaultsDomain) else { throw RenderFailure.invalidFixture }
        self.defaults = defaults
        defaults.set(CardAppearancePrefs.defaultPercent, forKey: CardAppearancePrefs.opacityKey)
        let state = RenderTransportState()
        transport = state
        let journalBoundary = RenderBoundary(held: scenario == .journalLoading)
        let headBoundary = RenderBoundary(held: scenario == .heldHead)
        self.journalBoundary = journalBoundary; self.headBoundary = headBoundary
        let dependencies: ScoringInputCoordinator.Dependencies?
        if let context {
            dependencies = .init(isCurrent: { $0 == context && state.current() },
                canUpload: { state.current() && [.queue, .unavailableHead, .heldHead].contains(scenario) },
                openJournal: { layout, fence in
                    try await journalBoundary.arrive()
                    return try ScoringInputJournal(layout: layout, fence: fence, preferenceContext: context,
                        isPreferenceContextCurrent: { $0 == context && state.current() })
                }, head: { change, captured in
                    state.headed()
                    try await headBoundary.arrive()
                    if scenario == .unavailableHead { throw ScoringInputRPC.Failure.unavailable }
                    guard let user = UUID(uuidString: captured.scope.userID), let device = UUID(uuidString: change.device) else {
                        throw RenderFailure.invalidFixture
                    }
                    return ScoringInputHead(schemaVersion: 1, userId: user, sourceDeviceId: device,
                        kind: change.kind, entity: change.entity, headRevision: 37)
                }, send: { _, _ in
                    state.sent()
                    // Never create a receipt, open a socket, or claim a server-accepted result.
                    throw ScoringInputRPC.Failure.unavailable
                })
        } else { dependencies = nil }
        model = AppModel(storageLayout: layout, context: context, presentationAllowed: false,
            captureAllowed: false, guestPreferenceDefaults: context == nil ? defaults : nil,
            postIllnessNotification: { _ in }, scoringInputDependencies: dependencies,
            nativePreferenceCurrent: { $0 == context && state.current() }, preferenceScoringEnabled: { false },
            isCurrent: { $0 == context && state.current() })
    }

    static func make(_ scenario: RenderScenario) async throws -> RenderFixture {
        let fixture = try RenderFixture(scenario)
        do {
            if fixture.model.accountContext != nil {
                let layout = fixture.layout
                fixture.inspector = try await Task.detached { try ScoringInputJournal(layout: layout) }.value
                if scenario.hasQueue { try await fixture.seedQueue() }
                if scenario != .journalLoading { try await fixture.model.prepareScoringPreferences() }
                if scenario == .failedRevocation { try await fixture.failActualRevocation() }
                if scenario == .retired { fixture.retire() }
            }
            return fixture
        } catch {
            try await fixture.close()
            throw error
        }
    }

    private func seedQueue() async throws {
        guard let context = model.accountContext, let inspector else { throw RenderFailure.missingAccount }
        let device = PushDurabilityReceipt.canonicalDevice(owner: context.scope.userID, device: model.repo.deviceId)
        let formatter = ISO8601DateFormatter()
        for (index, day) in ["2026-09-16", "2026-09-17", "2026-09-18"].enumerated() {
            guard let date = formatter.date(from: day + "T12:00:00Z") else { throw RenderFailure.invalidFixture }
            // Use the production serializer for queued synthetic inputs. This seed is NOT
            // assigned to accepted preferences; real hydration owns that separate state.
            let seed = ScoringPreferenceSnapshot.seed(context: context, domain: ["profile.weightKg": Double(70 + index)], now: date)
            let body = try seed.payloads(at: date, timezone: "UTC", consent: .init(journalEnabled: false, cycleEnabled: false))
            let change = try ScoringInputChange(device: device, kind: .profile, entity: "primary",
                                               effectiveDay: day, payload: body.profile)
            guard let id = try await inspector.enqueue(change) else { throw RenderFailure.invalidFixture }
            originals.append(Original(id: id, change: change))
        }
        guard let pending = try await inspector.next() else { throw RenderFailure.invalidFixture }
        try await inspector.retry(pending, conflict: true)
    }

    private func failActualRevocation() async throws {
        guard let consent = model.scoringContextConsent else { throw RenderFailure.missingAccount }
        await consent.setEnabled(true, purpose: .journal)
        guard consent.enabled(.journal), consent.error == nil else { throw RenderFailure.invalidFixture }
        let path = layout.directory.appendingPathComponent("scoring-context-consent.sqlite").path
        try await Task.detached {
            let database = try DatabaseQueue(path: path)
            defer { try? database.close() }
            try database.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER render_deny_revocation BEFORE UPDATE ON consent_decision
                    WHEN NEW.purpose='journal_context' AND NEW.enabled=0
                    BEGIN SELECT RAISE(ABORT,'synthetic render-fixture write failure'); END;
                    """)
            }
        }.value
        await consent.setEnabled(false, purpose: .journal)
        guard !consent.enabled(.journal), consent.error != nil else { throw RenderFailure.invalidFixture }
    }

    func releaseBarriersAndHydrate() async throws {
        await journalBoundary.release(); await headBoundary.release()
        if model.accountContext != nil, model.isAccountRuntimeActive, model.acceptedScoringPreferences == nil {
            try await model.prepareScoringPreferences()
        }
    }

    func retire() {
        transport.retire()
        model.shutdownForAccountChange()
    }

    /// Read-only evidence after real manual clicks. Original bytes must remain either in the
    /// pending queue OR its real resolution archive, never both, never missing. No fake receipt.
    func auditOriginals() async throws -> String {
        guard inspector != nil else { return "Guest: no account journal was created." }
        let path = layout.directory.appendingPathComponent("history-inputs.sqlite").path
        let originals = originals
        return try await Task.detached {
            let database = try DatabaseQueue(path: path)
            defer { try? database.close() }
            return try database.read { db in
                var live = 0, archived = 0
                var replacements = Set<String>()
                for original in originals {
                    let pending = try Row.fetchOne(db, sql: "SELECT * FROM input_change WHERE id=?", arguments: [original.id])
                    let resolved = try Row.fetchOne(db, sql: "SELECT * FROM input_resolution WHERE id=?", arguments: [original.id])
                    guard (pending == nil) != (resolved == nil), let row = pending ?? resolved,
                          row["payload"] as Data == original.change.payload,
                          row["day"] as String == original.change.effectiveDay,
                          row["device"] as String == original.change.device,
                          row["kind"] as String == original.change.kind.rawValue,
                          row["entity"] as String == original.change.entity,
                          row["digest"] as String == original.change.digest,
                          row["deleted"] as Bool == original.change.deleted else { throw RenderFailure.originalChanged }
                    if let resolved {
                        archived += 1
                        guard resolved["reviewed_head"] as Int64 == 37,
                              (resolved["settled_revision"] as Int64?) == nil else { throw RenderFailure.unexpectedReceipt }
                        replacements.insert(resolved["replacement_id"] as String)
                    } else { live += 1 }
                }
                guard live == 0 || archived == 0, replacements.count <= 1 else { throw RenderFailure.originalChanged }
                for id in replacements {
                    guard let replacement = try Row.fetchOne(db, sql: "SELECT * FROM input_change WHERE id=?", arguments: [id]),
                          replacement["expected_revision"] as Int64 == 37 else { throw RenderFailure.originalChanged }
                    let sources = try Row.fetchAll(db, sql: "SELECT * FROM input_resolution WHERE replacement_id=?", arguments: [id])
                    guard sources.contains(where: { source in
                        (source["payload"] as Data) == (replacement["payload"] as Data) &&
                        (source["day"] as String) == (replacement["day"] as String) &&
                        (source["device"] as String) == (replacement["device"] as String) &&
                        (source["kind"] as String) == (replacement["kind"] as String) &&
                        (source["entity"] as String) == (replacement["entity"] as String) &&
                        (source["deleted"] as Bool) == (replacement["deleted"] as Bool) &&
                        (source["digest"] as String) == (replacement["digest"] as String)
                    }) else { throw RenderFailure.originalChanged }
                }
                let receipts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM input_head WHERE receipt IS NOT NULL") ?? 0
                guard receipts == 0 else { throw RenderFailure.unexpectedReceipt }
                return "Original intents: \(live) pending, \(archived) archived with exact bytes/dates/identity. "
                    + "Replacement groups: \(replacements.count), each an exact archived version at head 37. Server receipts: 0."
            }
        }.value
    }

    func close() async throws {
        guard !closed else { return }
        closed = true
        retire()
        await journalBoundary.release(); await headBoundary.release()
        await model.scoringPreferences?.waitForRetirement()
        var firstError: Error?
        do { try await model.scoringInputs?.waitForRetirement() } catch { firstError = error }
        do { try await inspector?.close() } catch { if firstError == nil { firstError = error } }
        inspector = nil
        defaults.removePersistentDomain(forName: defaultsDomain)
        // Consent lacks an explicit close API. Intentionally retain this UUID root (including
        // SQLite/WAL/SHM) through process exit; NEVER unlink a database with a possibly live handle.
        if let firstError { throw firstError }
    }
}

@MainActor
private struct RenderControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScoringContextSharingView()
                ScoringInputConflictReviewView()
            }.padding(16)
        }
        .environmentObject(model)
        .defaultAppStorage(model.accountDefaults)
        .background(NoopVisualStyle.canvas)
    }
}

@MainActor
private final class RenderWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    private(set) var closed = false
    init(root: AnyView, visible: Bool) {
        host = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 940),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "NARA Sync Controls: Synthetic Local Fixture"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 940)
        host.autoresizingMask = [.width, .height]
        window.contentMinSize = NSSize(width: 520, height: 520)
        if visible { window.center(); window.makeKeyAndOrderFront(nil) }
    }
    func windowWillClose(_ notification: Notification) { closed = true }
    func close() {
        // End only sheets attached to this test-owned window, never another app window.
        func endSheets(_ parent: NSWindow) {
            for sheet in parent.sheets { endSheets(sheet); parent.endSheet(sheet); sheet.close() }
        }
        endSheets(window)
        window.contentView = nil
        host.rootView = AnyView(EmptyView())
        window.close()
        closed = true
    }
}

@MainActor
private enum RenderAccessibility {
    struct Observation { let text: String; let incomplete: Bool }
    static func read(_ root: NSView) -> Observation {
        var pending: [(AnyObject, Int)] = [(root, 0)]
        var seen = Set<ObjectIdentifier>()
        var text: [String] = []
        var incomplete = false
        while let (object, depth) = pending.popLast() {
            if seen.contains(ObjectIdentifier(object)) { continue }
            if seen.count >= 2048 || depth > 32 { incomplete = true; break }
            seen.insert(ObjectIdentifier(object))
            if let element = object as? NSAccessibilityProtocol {
                if let label = element.accessibilityLabel() { text.append(label) }
                if let value = element.accessibilityValue() as? String { text.append(value) }
                let children = element.accessibilityChildren() ?? []
                if children.count > 2048 { incomplete = true }
                for child in children.prefix(2048) {
                    pending.append((child as AnyObject, depth + 1))
                }
            }
            // SwiftUI may not expose an AX parent. Visit actual NSView subviews as well,
            // without substituting test strings when its accessible text is unavailable.
            if let view = object as? NSView {
                if view.subviews.count > 2048 { incomplete = true }
                for child in view.subviews.prefix(2048) { pending.append((child, depth + 1)) }
            }
            if pending.count > 4096 { incomplete = true; break }
        }
        return Observation(text: text.joined(separator: "\n"), incomplete: incomplete)
    }
}

@MainActor
private final class RenderManualController: ObservableObject {
    @Published private(set) var fixture: RenderFixture?
    @Published private(set) var scenario: RenderScenario = .queue
    @Published private(set) var busy = false
    @Published private(set) var note = "Synthetic local data only. Head = 37; values unavailable; sends always fail locally."
    @Published var dark = false
    @Published var largerText = false
    private(set) var record: [String] = []
    var closeWindow: (() -> Void)?
    private var operation: Task<Void, Never>?
    private var delayedRetirement: Task<Void, Never>?
    private var closing = false
    private var recordedFailure: Error?

    func start() async throws { fixture = try await RenderFixture.make(.queue); rememberFixture() }
    private func rememberFixture() {
        if let fixture { record.append("\(fixture.scenario.rawValue): retained synthetic root \(fixture.root.path)") }
    }
    func select(_ next: RenderScenario) {
        guard !busy, !closing else { return }
        delayedRetirement?.cancel()
        busy = true
        operation = Task {
            defer { busy = false }
            do {
                let old = fixture
                fixture = nil // Real controls disappear before the captured account retires.
                if let old {
                    old.retire()
                    await old.journalBoundary.release(); await old.headBoundary.release()
                    do { record.append(try await old.auditOriginals()) }
                    catch { try await old.close(); throw error }
                    try await old.close()
                }
                guard !closing else { return }
                let nextFixture = try await RenderFixture.make(next)
                guard !closing else { try await nextFixture.close(); return }
                scenario = next; fixture = nextFixture; rememberFixture()
                note = "Synthetic fixture ready. Use the actual controls below; no server acceptance can occur."
            } catch {
                recordedFailure = recordedFailure ?? error
                note = "Fixture setup/audit failed: \(error)"; record.append(note)
            }
        }
    }
    func release() {
        guard !busy, !closing, let fixture else { return }
        busy = true
        operation = Task {
            defer { busy = false }
            do {
                try await fixture.releaseBarriersAndHydrate()
                if !closing { note = "Actual dependency barriers released. No consent or replacement was selected by the fixture." }
            } catch {
                if !closing {
                    recordedFailure = recordedFailure ?? error
                    note = "Fixture release failed: \(error)"
                }
                record.append("Release: \(error)")
            }
        }
    }
    func retire() {
        guard !busy, !closing, let fixture else { return }
        fixture.retire()
        objectWillChange.send()
        note = "Captured account retired. Release a held request to inspect late-result fencing."
    }
    func retireAfterDelay() {
        guard !busy, !closing, let captured = fixture else { return }
        delayedRetirement?.cancel()
        note = "In 5 seconds this captured owner retires, then barriers release. Open/check the real review now."
        delayedRetirement = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard !closing, !Task.isCancelled, fixture?.id == captured.id else { return }
            // A sheet is modal: schedule this test-only identity transition BEFORE opening it.
            // Never drive its private StateObject, selection, permission or completion fields.
            captured.retire()
            objectWillChange.send()
            await captured.journalBoundary.release(); await captured.headBoundary.release()
            if !closing { note = "Captured owner retired; held real requests released after retirement." }
        }
    }
    func audit() {
        guard !busy, !closing, let fixture else { return }
        busy = true
        operation = Task {
            defer { busy = false }
            do {
                let result = try await fixture.auditOriginals()
                record.append(result)
                if !closing { note = result }
            } catch {
                recordedFailure = recordedFailure ?? error
                note = "Durable fixture audit failed: \(error)"; record.append(note)
            }
        }
    }
    func close() async throws {
        guard !closing else { return }
        closing = true
        delayedRetirement?.cancel()
        // Waiting is asynchronous. Retire while requests are held, then release them; no auth
        // facade mutation or new account is needed to exercise captured-owner rejection.
        fixture?.retire()
        await fixture?.journalBoundary.release(); await fixture?.headBoundary.release()
        await operation?.value
        await delayedRetirement?.value
        operation = nil
        delayedRetirement = nil
        if let fixture {
            do { record.append(try await fixture.auditOriginals()) }
            catch { try await fixture.close(); self.fixture = nil; throw error }
            record.append("Synthetic head calls: \(fixture.transport.headCount); locally failed sends: \(fixture.transport.sendCount).")
            try await fixture.close()
        }
        fixture = nil
        if let recordedFailure { throw recordedFailure }
    }
}

/// Antislop DURING, established NARA 1/1/1: native fixture controls only, no copied cards,
/// palette, assets or motion. Padding separates test instrumentation from unchanged real UI.
@MainActor
private struct RenderManualRoot: View {
    @ObservedObject var controller: RenderManualController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synthetic local fixture controls").font(.headline)
            Text("Not signed in. Synthetic head revision only; no live server values or successful sends.")
                .font(.caption)
            Picker("Fixture scenario", selection: Binding(get: { controller.scenario }, set: { controller.select($0) })) {
                ForEach(RenderScenario.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(controller.busy)
            HStack {
                Button("Release barriers") { controller.release() }.disabled(controller.busy)
                Button("Retire captured owner") { controller.retire() }.disabled(controller.busy)
                Button("Audit retained bytes") { controller.audit() }.disabled(controller.busy)
            }
            Button("Retire captured owner in 5 seconds") { controller.retireAfterDelay() }.disabled(controller.busy)
            HStack {
                Toggle("Fixture dark appearance", isOn: $controller.dark)
                Toggle("Fixture larger text", isOn: $controller.largerText)
                Button("Close fixture") { controller.closeWindow?() }.keyboardShortcut(.cancelAction)
            }
            if controller.busy { ProgressView("Preparing or checking synthetic fixture…") }
            Text(controller.note).font(.caption).textSelection(.enabled)
            Divider()
            if let fixture = controller.fixture {
                RenderControls(model: fixture.model).id(fixture.id)
            } else { Text("No fixture mounted while the previous captured account is retired.") }
        }
        .padding(16)
        .preferredColorScheme(controller.dark ? .dark : .light)
        .dynamicTypeSize(controller.largerText ? .accessibility1 : .large)
    }
}
#endif
