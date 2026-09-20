import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import WhoopStore
import UserNotifications

// MARK: - OnboardingWizard
//
// First-run setup requires explicit strap selection, an encrypted pairing, and
// verified empty storage before profile setup or normal history ingestion.

public struct OnboardingWizard: View {

    /// Called only after pairing and the storage reset have been verified.
    public var onFinished: () -> Void

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    // Live readings stay in child views. The setup phase, rather than per-tick HR
    // updates or the legacy bonded flag, controls progression through connection.
    @EnvironmentObject private var model: AppModel

    private enum Step: Int, CaseIterable {
        case welcome, what, expectations, bluetooth, wear, scan, bonded, profile, importData, notifications, appearance, done

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .done }
    }

    @State private var step: Step = .welcome
    @State private var setupReady = false
    @State private var cloudLinkIssue = false
    @State private var connectionBusy = false
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NARA" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    public var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                // Top chrome: a small back affordance + a step counter.
                topBar
                    .padding(.horizontal, 36)
                    .padding(.top, 42)

                // The paged content.
                ZStack {
                    switch step {
                    case .welcome:    WelcomeStep()
                    case .what:       WhatItDoesStep()
                    case .expectations: ExpectationsStep()
                    case .bluetooth:  BluetoothStep()
                    case .wear:       WearStep()
                    case .scan:       ScanStep(advance: handleBond, setBusy: { connectionBusy = $0 })
                    case .bonded:     BondedStep()
                    case .profile:    ProfileStep()
                    case .importData: ImportStep()
                    case .notifications: NotificationsStep()
                    case .appearance: AppearanceStep()
                    case .done:       DoneStep()
                    }
                }
                .frame(maxWidth: 620, maxHeight: .infinity)
                .transition(stepTransition)
                .id(step)                       // re-runs the transition per step
                .padding(.horizontal, 40)

                // Bottom: the thread (progress) + the forward CTA.
                bottomBar
                    .padding(.horizontal, 40)
                    .padding(.top, 24)
                    .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // Reduce Motion: leave the ambient bloom at its resting frame (no breathing).
        .onAppear { if !poseStill { glow = true } }
    }

    private func handleBond() {
        setupReady = true
        connectionBusy = false
        if step == .scan { withAnimation(StrandMotion.hero) { step = .bonded } }
    }

    // MARK: Backgrounds

    private var background: some View {
        ZStack {
            StrandPalette.surfaceBase
            // A slow ambient bloom that breathes — the substrate feels alive. Kept subtle
            // (≈⅓ the old gold opacity) so it's a minimal gold hint, not a wash.
            RadialGradient(
                colors: [StrandPalette.glowAmbient.opacity(0.18), .clear],
                center: .center,
                startRadius: 40,
                endRadius: glow ? 620 : 480
            )
            .blendMode(.plusLighter)
            .opacity(glow ? 0.4 : 0.28)
            .animation(StrandMotion.breathe(reduced: poseStill), value: glow)
            .ignoresSafeArea()

            // A faint indigo wash from the top — instrument-grade depth.
            LinearGradient(
                colors: [StrandPalette.accentMuted.opacity(0.20), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if step.isFirst {
                Color.clear.frame(width: 64, height: 28)
            } else {
                Button(action: back) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .disabled(step == .scan && connectionBusy)
            }

            Spacer()

            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Bottom bar (the thread + CTA)

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 28) {
            if cloudLinkIssue {
                Text("The server has not confirmed this strap yet. Stay online, then tap Enter NARA again.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
            }
            ThreadProgress(progress: progress)
                .frame(height: 3)
                .frame(maxWidth: 620)

            if step != .scan {
                HStack(spacing: 14) {
                    PrimaryButton(title: ctaTitle, systemImage: ctaIcon, action: primaryAction)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 620)
            }
        }
    }

    private var progress: Double {
        guard Step.allCases.count > 1 else { return 1 }
        return Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    private var ctaTitle: String {
        switch step {
        case .welcome:    return String(localized: "Get Started")
        case .what:       return String(localized: "Continue")
        case .expectations: return String(localized: "I understand")
        case .bluetooth:  return String(localized: "Continue")
        case .wear:       return String(localized: "I see the green light")
        case .scan:       return String(localized: "Continue")
        case .bonded:     return String(localized: "Continue")
        case .profile:    return String(localized: "Save & Continue")
        case .importData: return String(localized: "Continue")
        case .notifications: return String(localized: "Continue")
        case .appearance: return String(localized: "Continue")
        case .done:       return String(localized: "Enter NARA")
        }
    }

    private var ctaIcon: String? {
        switch step {
        case .done:    return "arrow.right"
        case .bonded:  return "checkmark"
        default:       return nil
        }
    }

    private func primaryAction() {
        if step.isLast {
            guard setupReady else { return }
            guard model.serverScores.deviceLinked else {
                cloudLinkIssue = true
                Task { await model.serverScores.refreshVisibleDays() }
                return
            }
            guard model.ble.onboardingSetup.finish() else {
                setupReady = false
                step = .scan
                return
            }
            onFinished()
        } else {
            advance()
        }
    }

    // MARK: Navigation

    /// Leaving the Notifications step is the one point in onboarding where we actually ask the OS for
    /// notification permission — everything before this only explained why (the `NotificationsStep`
    /// card). Without this, NARA never showed up under Settings → Notifications at all unless a user
    /// later found and enabled one of the opt-in automations (wind-down, battery, illness) buried in
    /// More → Alarms/Automations, each of which lazily requests on its own toggle. Mirrors the Android
    /// onboarding's `OnboardingPage.Notifications` step (`OnboardingScreen.kt`): request only if not
    /// already determined (so a re-run/upgrade doesn't re-prompt), and advance once the OS dialog is
    /// dismissed either way — the per-feature toggles still handle a later denial on their own.
    private func advance() {
        guard step != .notifications else {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else {
                    Task { @MainActor in advanceStep() }
                    return
                }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    Task { @MainActor in advanceStep() }
                }
            }
            return
        }
        advanceStep()
    }

    private func advanceStep() {
        guard step != .scan || setupReady else { return }
        guard let next = Step(rawValue: step.rawValue + 1) else { onFinished(); return }
        withAnimation(StrandMotion.gentle) { step = next }
    }

    private func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(StrandMotion.gentle) { step = prev }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStep: View {
    @State private var appear = false
    var body: some View {
        StepShell {
            VStack(spacing: 24) {
                Spacer()
                // The hero mark — the Engraved titanium BrandMark (open gold ring +
                // core dot on a brushed-titanium tile). Clean and flat; it draws in
                // with a calm scale + fade, no glow.
                BrandMark(size: 120)
                    .scaleEffect(appear ? 1 : 0.92)
                    .opacity(appear ? 1 : 0)
                Text("your strap, your NARA account")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .opacity(appear ? 1 : 0)
                Text("Readings from your strap sync to your NARA account for cloud analysis of recovery, sleep and strain.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .opacity(appear ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(StrandMotion.hero) { appear = true } }
    }
}

// MARK: - Step 2 · What it does

private struct WhatItDoesStep: View {
    private struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        .init(icon: "circle.dashed.inset.filled",
              tint: StrandPalette.accent,
              title: String(localized: "See recovery, beautifully"),
              body: String(localized: "A signature ring distils HRV, resting heart rate and sleep into one calm read on whether to push or rest.")),
        .init(icon: "waveform.path.ecg",
              tint: StrandPalette.accent,
              title: String(localized: "Watch your heart, live"),
              body: String(localized: "Connect a WHOOP, a heart-rate strap or a gym machine and watch each beat in real time: heart rate, variability and zones as they happen. Already have history elsewhere? Import it from WHOOP, Apple Health, Oura, Fitbit or Garmin.")),
        .init(icon: "lock.shield",
              tint: StrandPalette.statusPositive,
              title: String(localized: "Keep your readings with your account"),
              body: String(localized: "Your phone collects readings over Bluetooth and uploads them to your NARA account. Server results return to the same account.")),
    ]

    var body: some View {
        StepShell(title: String(localized: "What NARA does"), subtitle: String(localized: "Three quiet promises.")) {
            VStack(spacing: 14) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    SlideRow(slide: slide, index: index)
                }
            }
        }
    }

    private struct SlideRow: View {
        let slide: Slide
        let index: Int
        @State private var shown = false
        var body: some View {
            StrandCard {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(slide.tint.opacity(0.14))
                            .frame(width: 46, height: 46)
                        Image(systemName: slide.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(slide.tint)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slide.title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(slide.body)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(StrandMotion.gentle.delay(Double(index) * 0.10)) { shown = true }
            }
        }
    }
}

// MARK: - Step 2.5 · What to expect (independent / experimental / 5-MG framing)

private struct ExpectationsStep: View {
    @State private var shown = false
    var body: some View {
        StepShell(title: String(localized: "What to expect"),
                  subtitle: String(localized: "A few honest words, so nothing's a surprise.")) {
            VStack(spacing: 12) {
                ForEach(Array(AppChangelog.expectations.enumerated()), id: \.element.id) { index, e in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: e.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 26)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.title).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(e.body).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(NoopPanelSurface(cornerRadius: 14))
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
                    .animation(StrandMotion.gentle.delay(Double(index) * 0.08), value: shown)
                }

                #if os(iOS)
                // The iPhone-only reality: this is a sideloaded build, so set the re-sign + unlock
                // expectation up front rather than letting it surprise people later (#222 / cert expiry).
                expectationRow(
                    icon: "iphone.gen3",
                    title: String(localized: "Installed outside the App Store"),
                    body: String(localized: "On iPhone this is a sideloaded build. Re-sign it about every 7 days on a free Apple ID (longer on a paid account). After your phone reboots, unlock it once so NARA can read and sync its data.")
                )
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 8)
                .animation(StrandMotion.gentle.delay(Double(AppChangelog.expectations.count) * 0.08), value: shown)
                #endif
            }
        }
        .onAppear { shown = true }
    }

    /// One expectation callout, matching the data-driven rows above so the iOS-only addition is visually
    /// identical to the rest of the list.
    private func expectationRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(body).font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 14))
    }
}

// MARK: - Step 3 · Bluetooth priming

private struct BluetoothStep: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NARA" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    var body: some View {
        StepShell(title: String(localized: "A quick word before we connect"),
                  subtitle: String(localized: "\(Platform.deviceNoun) will ask for Bluetooth in a moment.")) {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(StrandPalette.accent.opacity(0.25), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.25 : 0.9)
                        .opacity(pulse ? 0 : 0.8)
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.5))
                        .frame(width: 86, height: 86)
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .frame(height: 130)

                InfoCard(
                    icon: "lock.fill",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "Bluetooth collection, cloud analysis"),
                    message: String(localized: "NARA reads your strap over Bluetooth, buffers readings on this device, and uploads them to your account when a permitted network is available.")
                )

                Text("When the system prompt appears, choose Allow so NARA can find your strap.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .onAppear { if !poseStill { withAnimation(StrandMotion.breathe) { pulse = true } } }
    }
}

// MARK: - Step 4 · Wear & wake

private struct WearStep: View {
    var body: some View {
        StepShell(title: String(localized: "Charge and wake your WHOOP"),
                  subtitle: String(localized: "Keep it off your wrist while we set it up.")) {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(StrandPalette.accent.opacity(0.16))
                        .frame(width: 130, height: 130)
                        .blur(radius: 24)
                    Image(systemName: "battery.100percent")
                        .font(.system(size: 58, weight: .regular))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(height: 140)

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Charge your WHOOP with its charger or battery pack."))
                    Checkline(text: String(localized: "Double-tap the top to check the side light. Green means it is on and has a good charge."))
                    Checkline(text: String(localized: "No light, or a red light? Charge it longer, then check again."))
                    Checkline(text: String(localized: "Keep it within about a metre of \(Platform.deviceNounPhrase)."))
                }
                .frame(maxWidth: 440)
            }
        }
    }
}

// MARK: - Step 5 · Select, pair, and reset

private struct ScanStep: View {
    let advance: () -> Void
    let setBusy: (Bool) -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        WhoopSetupContent(ble: model.ble, setup: model.ble.onboardingSetup,
                          advance: advance, setBusy: setBusy)
    }
}

private struct WhoopSetupContent: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject var setup: WhoopOnboardingSetup
    let advance: () -> Void
    let setBusy: (Bool) -> Void
    @AppStorage("selectedWhoopModel") private var modelRaw = WhoopModel.whoop4.rawValue
    @State private var selected: (uuid: String, name: String)?
    @State private var serialConfirmed = false
    @State private var blueLightConfirmed = false
    private var model: WhoopModel { WhoopModel(rawValue: modelRaw) ?? .whoop4 }

    var body: some View {
        StepShell(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 22) {
                switch setup.phase {
                case .chooseDevice:
                    if let selected { pairingInstructions(selected) } else { deviceList }
                case .pairing:
                    ProgressView("Waiting for pairing…")
                    Text("When your phone shows Bluetooth Pairing Request, tap Pair. Keep your WHOOP nearby. NARA will move on only when the secure connection succeeds.")
                    Text("If the request does not appear, keep tapping the top firmly and repeatedly until the side light flashes blue. A WHOOP already paired to this phone may reconnect without another prompt.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                case .resetting, .verifying:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Connecting and resetting")
                    Text("Keep your WHOOP charged, off your wrist, and close to your phone. We’re clearing its stored readings and checking that it is ready for you.")
                case .failed(let message):
                    Text(message)
                    PrimaryButton(title: "Retry connection", action: { ble.retryOnboarding() })
                    Button("Clear storage and retry") { ble.retryOnboarding(eraseAgain: true) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Choose a different WHOOP") {
                        selected = nil
                        startScan()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                case .ready:
                    ProgressView("WHOOP is ready")
                }
            }
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(maxWidth: 460, alignment: .leading)
        }
        .onAppear {
            phaseChanged()
            if setup.phase == .chooseDevice { startScan() }
        }
        .onChangeCompat(of: setup.phase) { _ in phaseChanged() }
        .onDisappear { ble.stopWhoopScan() }
    }

    private var title: String {
        switch setup.phase {
        case .chooseDevice: return selected == nil ? "Connect your WHOOP" : "Tap until the light turns blue"
        case .pairing: return "Tap Pair on your phone"
        case .resetting, .verifying: return "Connecting and resetting"
        case .failed: return "Let’s finish setting up your WHOOP"
        case .ready: return "Your WHOOP is ready"
        }
    }

    private var subtitle: String? {
        setup.phase == .chooseDevice && selected == nil
            ? "Find your WHOOP below. Match the number in its name to the serial number printed on your sensor before selecting it."
            : nil
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 16) {
            SegmentedPillControl(WhoopModel.allCases,
                selection: Binding(get: { model }, set: { modelRaw = $0.rawValue; startScan() }),
                label: { $0.displayName })
            if ble.discoveredWhoops.isEmpty {
                Text(ble.onboardingScanIssue ?? "Looking for your WHOOP…")
                    .font(StrandFont.headline)
            }
            ForEach(ble.discoveredWhoops, id: \.uuid) { strap in
                Button {
                    selected = (strap.uuid, strap.name)
                    serialConfirmed = false
                    blueLightConfirmed = false
                    ble.stopWhoopScan()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(strap.name.isEmpty ? "WHOOP (serial not advertised)" : strap.name)
                                .font(StrandFont.headline)
                            Text(WhoopOnboardingSetup.hasSerialInName(strap.name)
                                 ? "Check this against your sensor’s serial number"
                                 : "Serial number not shown. Cannot select this device.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                    }
                    .padding(16)
                    .background(NoopPanelSurface(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!WhoopOnboardingSetup.hasSerialInName(strap.name))
            }
            Button("Scan again", action: startScan)
                .buttonStyle(SecondaryButtonStyle())
            Text("Nothing showing up? Fully close the WHOOP app, keep your charged sensor nearby, and check that Bluetooth is on. If needed, take it off your wrist and tap the top repeatedly until the side light flashes blue, then scan again.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Text("If the name does not show a serial number you can match, do not select it.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func pairingInstructions(_ strap: (uuid: String, name: String)) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(strap.name).font(StrandFont.headline)
            Toggle("I checked that this matches my WHOOP’s serial number", isOn: $serialConfirmed)
            Checkline(text: "Take it off your wrist. Hold it by the sides and wait for the green sensor lights underneath to turn off.")
            Checkline(text: "Tap the top firmly, quickly, and continuously. It can take a lot of taps. Keep going until the light on the side flashes blue.")
            Toggle("The side light is flashing blue", isOn: $blueLightConfirmed)
            Text("After you tap Pair on your phone, NARA will automatically erase all readings stored on this WHOOP, including any previous owner’s data. This cannot be undone.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            PrimaryButton(title: "Connect and reset this WHOOP", action: {
                ble.pairForOnboarding(id: strap.uuid, name: strap.name, serialConfirmed: serialConfirmed)
            })
            .disabled(!serialConfirmed || !blueLightConfirmed)
            Button("Choose a different WHOOP") {
                selected = nil
                startScan()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func startScan() {
        ble.scanForOnboarding(model: model)
    }

    private func phaseChanged() {
        setBusy(setup.busy)
        if setup.phase == .ready { advance() }
    }
}

// MARK: - Step 6 · Bonding celebration

private struct BondedStep: View {
    @EnvironmentObject private var live: LiveState
    @State private var bloom = false
    var body: some View {
        StepShell {
            VStack(spacing: 26) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(StrandPalette.statusPositive)
                        .frame(width: 160, height: 160)
                        .blur(radius: 70)
                        .opacity(bloom ? 0.5 : 0.0)
                        .blendMode(.plusLighter)
                    // A ring materialises — a taste of the signature component.
                    RecoveryRing(score: 100, supporting: nil, diameter: 200, lineWidth: 14, showsLabel: false)
                        .scaleEffect(bloom ? 1 : 0.7)
                        .opacity(bloom ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(StrandPalette.statusPositive)
                        .scaleEffect(bloom ? 1 : 0.4)
                        .opacity(bloom ? 1 : 0)
                }
                .frame(height: 210)

                VStack(spacing: 8) {
                    Text("Paired. Cleared. Ready for you.")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(batteryLine)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .opacity(bloom ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(StrandMotion.hero) { bloom = true } }
    }

    private var batteryLine: String {
        if let pct = live.batteryPct {
            return String(localized: "Stored readings cleared · \(Int(pct))% battery. You can put your WHOOP on now.")
        }
        return String(localized: "Your WHOOP is paired and its stored readings are cleared. You can put it on now.")
    }
}

// MARK: - Step 7 · Profile

private struct ProfileStep: View {
    @EnvironmentObject private var profile: ProfileStore

    // The stored profile is always SI. Body measurements and exercise distance can follow the regional
    // conventions independently; an unset distance choice follows the body choice for compatibility.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: unitSystem, override: distanceSystemRaw)
    }
    private var distanceSystemBinding: Binding<String> {
        Binding(get: { distanceUnitSystem.rawValue }, set: { distanceSystemRaw = $0 })
    }

    private let sexes: [(String, String)] = [
        ("male", String(localized: "Male")), ("female", String(localized: "Female")),
        ("nonbinary", String(localized: "Other"))
    ]

    var body: some View {
        StepShell(title: String(localized: "About you"),
                  subtitle: String(localized: "So your zones, calories and baselines are accurate.")) {
            VStack(spacing: 16) {
                StrandCard {
                    VStack(spacing: 18) {
                        // #146: capture a date of birth so age advances on its own instead of going stale.
                        DatePicker(selection: $profile.dateOfBirth,
                                   in: ProfileStore.dateOfBirthRange,
                                   displayedComponents: .date) {
                            FieldRow(label: String(localized: "Date of birth"),
                                     value: String(localized: "\(profile.age) yrs"))
                        }
                        .tint(StrandPalette.accent)

                        Divider().overlay(StrandPalette.hairline)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sex").strandOverline()
                            Picker("Sex", selection: $profile.sex) {
                                ForEach(sexes, id: \.0) { key, label in
                                    Text(label).tag(key)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider().overlay(StrandPalette.hairline)

                        // Keep the two choices explicit here: "Metric/Imperial" alone cannot describe
                        // common mixed conventions such as Canadian pounds with kilometres.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Body measurements").strandOverline()
                            Picker("Body measurements", selection: $unitSystemRaw) {
                                Text("Metric").tag(UnitSystem.metric.rawValue)
                                Text("Imperial").tag(UnitSystem.imperial.rawValue)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider().overlay(StrandPalette.hairline)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Exercise distance & pace").strandOverline()
                            Picker("Exercise distance & pace", selection: distanceSystemBinding) {
                                Text("Kilometres").tag(UnitSystem.metric.rawValue)
                                Text("Miles").tag(UnitSystem.imperial.rawValue)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider().overlay(StrandPalette.hairline)

                        // Steppers, not sliders — matches the Age row above and the macOS Settings
                        // profile editor (same ranges/steps), so every numeric profile field is
                        // consistent across onboarding and Settings on both platforms.
                        Stepper(value: $profile.weightKg, in: 30...250, step: 0.5) {
                            FieldRow(label: String(localized: "Weight"),
                                     value: UnitFormatter.massFromKilograms(profile.weightKg, system: unitSystem))
                        }

                        Divider().overlay(StrandPalette.hairline)

                        Stepper(value: $profile.heightCm, in: 120...230, step: 1) {
                            FieldRow(label: String(localized: "Height"),
                                     value: UnitFormatter.heightFromCentimeters(profile.heightCm, system: unitSystem))
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "bolt.heart")
                        .foregroundStyle(StrandPalette.accent)
                    Text("Estimated max heart rate · \(profile.hrMax) bpm")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }
}

// MARK: - Step 8 · Import (optional)

private struct ImportStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop

    var body: some View {
        StepShell(title: String(localized: "Bring your history"),
                  subtitle: String(localized: "Optional: import now, or continue and return to Data Sources later.")) {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.45))
                        .frame(width: 96, height: 96)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(StrandPalette.accent)
                }

                InfoCard(
                    icon: "clock.arrow.circlepath",
                    tint: StrandPalette.accent,
                    title: String(localized: "History fills the dashboard immediately"),
                    message: String(localized: "A WHOOP export backfills recovery, strain, sleep and workouts. Apple Health can add HR, HRV, sleep, SpO₂, steps, workouts and weight.")
                )

                StrandCard {
                    VStack(spacing: 10) {
                        ImportActionButton(
                            title: model.isImporting(.whoop) ? String(localized: "Importing…") : String(localized: "Import WHOOP export"),
                            systemImage: "tray.and.arrow.down",
                            disabled: model.hasActiveImport
                        ) {
                            presentImporter(.whoop)
                        }
                        ImportActionButton(
                            title: model.isImporting(.appleHealth) ? String(localized: "Working…") : String(localized: "Import Apple Health export"),
                            systemImage: "heart.fill",
                            disabled: model.hasActiveImport
                        ) {
                            presentImporter(.appleHealth)
                        }
                    }
                }
                .frame(maxWidth: 480)

                if model.hasActiveImport {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StrandPalette.accent)
                }

                // Show the summary for the source the user last imported, styled off the typed
                // failure flag (not a substring match) so real errors read as warnings.
                if let summary = lastSummary {
                    Text(summary)
                        .font(StrandFont.subhead)
                        .foregroundStyle(model.importFailed(importKind) ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importTarget.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result, for: importTarget)
        }
    }

    /// The AppModel source kind matching the last-chosen import target.
    private var importKind: DataSourceImportKind {
        switch importTarget {
        case .whoop: return .whoop
        case .appleHealth: return .appleHealth
        }
    }

    /// The summary for the source the user last imported in this step.
    private var lastSummary: String? {
        switch importTarget {
        case .whoop: return model.whoopImportSummary
        case .appleHealth: return model.appleHealthImportSummary
        }
    }

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        showingImporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>, for target: ImportTarget) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch target {
        case .whoop:
            model.importWhoop(url: url)
        case .appleHealth:
            model.importAppleHealth(url: url)
        }
    }

    private enum ImportTarget {
        case whoop
        case appleHealth

        var allowedContentTypes: [UTType] {
            // See DataSourcesView: `.folder` is a macOS-only affordance (pick an unzipped export
            // directory). On iOS it greys out the .zip in the Files picker (issue #179), so iOS
            // offers only the concrete file types.
            switch self {
            case .whoop:
                #if os(macOS)
                return [.zip, .folder]
                #else
                return [.zip]
                #endif
            case .appleHealth:
                #if os(macOS)
                return [.zip, .xml, .folder]
                #else
                return [.zip, .xml]
                #endif
            }
        }
    }
}

// MARK: - Step 9 · Notifications (wrist alerts priming)

private struct NotificationsStep: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NARA" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    var body: some View {
        StepShell(title: String(localized: "Stay in the loop"),
                  subtitle: String(localized: "NARA can tap your wrist when your \(Platform.deviceNoun) needs you. No glance at the screen required.")) {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(StrandPalette.accent.opacity(0.25), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.2 : 0.9)
                        .opacity(pulse ? 0 : 0.8)
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.5))
                        .frame(width: 86, height: 86)
                    Image(systemName: "bell.badge")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .frame(height: 130)

                #if os(iOS)
                // iOS gives an app no way to observe *other* apps' notifications, and the per-app picker
                // behind it is NSWorkspace-based (macOS-only). So drop the cross-app relay claim here and
                // keep only what iOS genuinely does: NARA's own strain nudges + smart alarm buzz the strap
                // directly over BLE.
                InfoCard(
                    icon: "applewatch.radiowaves.left.and.right",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "A buzz, not a banner"),
                    message: String(localized: "NARA taps your strap so an alert lands on your wrist instead of your screen. No need to reach for it. Everything stays on \(Platform.deviceNounPhrase).")
                )

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Strain nudges and your smart alarm tap your wrist the moment they fire."))
                    Checkline(text: String(localized: "Wrist alerts use the Bluetooth connection between this device and your strap."))
                }
                .frame(maxWidth: 460)
                #else
                InfoCard(
                    icon: "applewatch.radiowaves.left.and.right",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "A buzz, not a banner"),
                    message: String(localized: "When the \(Platform.deviceNoun) apps you choose send a notification, NARA taps your strap: Slack, Calendar, Messages, whatever matters. Everything stays on \(Platform.deviceNounPhrase).")
                )

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Pick which apps reach your wrist in Settings → Notifications."))
                    Checkline(text: String(localized: "Strain nudges and your smart alarm tap your wrist the same way."))
                }
                .frame(maxWidth: 460)
                #endif
            }
        }
        .onAppear { if !poseStill { withAnimation(StrandMotion.breathe) { pulse = true } } }
    }
}

// MARK: - Step 10 · Done

private struct DoneStep: View {
    @State private var appear = false
    var body: some View {
        StepShell {
            VStack(spacing: 22) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(StrandPalette.recovery100)
                        .frame(width: 120, height: 120)
                        .blur(radius: 64)
                        .opacity(appear ? 0.5 : 0)
                        .blendMode(.plusLighter)
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(
                            LinearGradient(gradient: StrandPalette.recoveryGradient,
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .scaleEffect(appear ? 1 : 0.8)
                        .opacity(appear ? 1 : 0)
                }
                .frame(height: 130)

                VStack(spacing: 10) {
                    Text("Your thread starts here.")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Every beat, every night, every day, woven into one quiet picture of you. Welcome to NARA.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .opacity(appear ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(StrandMotion.hero) { appear = true } }
    }
}

// MARK: - Step shell (shared layout for each page)

/// Lets a brand-new user pick the app's look up front (and learn it's changeable) — the same
/// System / Light / Dark setting that lives in Settings → Appearance. Selecting re-themes the whole
/// app live (the shared `@AppStorage(AppearanceMode.storageKey)` drives `preferredColorScheme`), so
/// the wizard itself IS the preview.
private struct AppearanceStep: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    private var binding: Binding<AppearanceMode> {
        Binding(get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }
    var body: some View {
        StepShell(title: String(localized: "Make it yours"),
                  subtitle: String(localized: "Choose how NARA looks. The whole app updates as you tap. You can change this any time in Settings → Appearance.")) {
            VStack(spacing: 28) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(height: 96)
                SegmentedPillControl(AppearanceMode.allCases, selection: binding) { $0.label }
                    .frame(maxWidth: 320)
                Text("System follows your \(Platform.deviceNoun)'s light or dark setting.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)
        }
    }
}

private struct StepShell<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                if title != nil || subtitle != nil {
                    VStack(spacing: 8) {
                        if let title {
                            Text(title)
                                .font(StrandFont.title1)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .multilineTextAlignment(.center)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 8)
                }
                content()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold. First-run wizard, every step routes
        // through this one shell, so a single fix here covers the whole onboarding flow.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
    }
}

// MARK: - The bottom progress thread
private struct ThreadProgress: View {
    var progress: Double           // 0...1
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StrandPalette.hairline)
                Capsule()
                    .fill(LinearGradient(gradient: StrandPalette.recoveryGradient,
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * progress))
                    .shadow(color: StrandPalette.recovery078.opacity(0.6), radius: 6)
                    .animation(StrandMotion.gentle, value: progress)
            }
        }
    }
}

// MARK: - Reusable pieces

private struct InfoCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var body: some View {
        StrandCard {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(message)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 480)
    }
}

private struct Checkline: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(StrandPalette.statusPositive)
                .padding(.top, 1)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct FieldRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).strandOverline()
            Spacer()
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

private struct DisclosureToggle: View {
    @Binding var open: Bool
    let label: String
    var body: some View {
        Button {
            withAnimation(StrandMotion.gentle) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.up" : "chevron.down")
                Text(label)
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.accent)
        }
        .buttonStyle(.plain)
    }
}

private struct ImportActionButton: View {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(StrandFont.subhead.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

// MARK: - Button styles

private struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(StrandFont.headline)
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? StrandPalette.accentHover : StrandPalette.accent)
            )
            .shadow(color: StrandPalette.accent.opacity(0.4), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.vertical, 11)
            .padding(.horizontal, 18)
            .background(NoopPanelSurface(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(configuration.isPressed ? StrandPalette.hairlineStrong : StrandPalette.hairline, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

// MARK: - Preview

#if DEBUG
private struct OnboardingPreview: View {
    @StateObject private var model = AppModel()
    var body: some View {
        OnboardingWizard(onFinished: {})
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(model.profile)
            .frame(width: 1100, height: 780)
    }
}

#Preview("Onboarding") { OnboardingPreview() }
#endif
