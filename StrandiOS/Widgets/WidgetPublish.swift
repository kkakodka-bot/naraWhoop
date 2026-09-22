import Foundation

/// The live adapter and synthetic tests share the final read/validate/publish sequence.
/// A successful callback is not a WidgetKit delivery or filesystem durability receipt.
@MainActor
enum WidgetPublicationBoundary {
    static func publish<Payload>(
        prepare: @MainActor () async throws -> Payload,
        validate: @MainActor () async -> Bool,
        checkBoundary: @MainActor () throws -> Void,
        isCurrent: @MainActor () -> Bool,
        save: @MainActor (Payload) -> Void
    ) async -> Bool {
        let payload: Payload
        do { payload = try await prepare() } catch { return false }
        guard await validate() else { return false }
        do { try checkBoundary() } catch { return false }
        guard isCurrent() else { return false }
        save(payload)
        return true
    }

    static func restScore(
        anchorDay: String?, today: String, requiresSuccessfulRead: Bool,
        strictRead: @MainActor () async throws -> [(day: String, value: Double)],
        legacyRead: @MainActor () async -> [(day: String, value: Double)],
        serverOwned: @MainActor () -> Bool
    ) async throws -> Double? {
        guard let anchorDay else { return nil }
        let series: [(day: String, value: Double)]
        if requiresSuccessfulRead { series = try await strictRead() }
        else { series = await legacyRead() }
        let byDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        return byDay[anchorDay] ?? (!serverOwned() && anchorDay == today ? series.last?.value : nil)
    }
}

#if os(iOS)
import WidgetKit

extension WidgetSnapshot {
    /// Build a glance snapshot from the live app state and publish it to the shared App Group, then
    /// ask WidgetKit to refresh. Called when the app becomes active and after a Health sync.
    ///
    /// `async` because the Rest score (#446) lives in a computed metric series, not a `DailyMetric`
    /// column, so it needs an `exploreSeries` read. The sole caller already runs inside a `Task`, so it
    /// just gains an `await`. Charge / Effort / HRV / Resting HR all read synchronously off the SAME
    /// anchor day, so the richer fields and the headline never disagree about which day they describe.
    ///
    /// #911: the anchor is resolved the way Today resolves it (the current LOGICAL local day, `Date()`
    /// read here so the day rolls live as the extension republishes), NOT "the most recent day with any
    /// recovery score". The old anchor drifted around the day rollover: the new logical day exists but
    /// isn't scored yet, so `days.last(where: recovery != nil)` still pointed at yesterday's scored row
    /// and the widget showed the older day while Today had already moved on. We now anchor on today's
    /// row and, only when today isn't scored yet, carry over the last STRICTLY-PRIOR scored day for the
    /// recovery-derived fields (the same carry-over Today does), so the widget never blanks right after
    /// the rollover yet always describes today.
    @MainActor @discardableResult
    static func publish(from model: AppModel,
                        dependentAdmission: SyncEngine.DependentStageAdmission? = nil) async -> Bool {
        guard model.isAccountRuntimeActive, let namespace = model.accountStorage?.scope?.namespace else { return false }
        let snapshotRevision = model.repo.serverPresentation.revision
        return await WidgetPublicationBoundary.publish(prepare: {
            try await preparedSnapshot(from: model, namespace: namespace,
                                       requiresSuccessfulRead: dependentAdmission != nil)
        }, validate: {
            guard let dependentAdmission else { return true }
            return await dependentAdmission.validate()
        }, checkBoundary: {
            try dependentAdmission?.checkBoundary()
        }, isCurrent: {
            model.isAccountRuntimeActive && model.accountStorage?.scope?.namespace == namespace
                && model.repo.serverPresentation.revision == snapshotRevision
        }, save: { snap in
            saveAndReloadIfChanged(snap)
        })
    }

    @MainActor
    private static func preparedSnapshot(from model: AppModel, namespace: String,
                                         requiresSuccessfulRead: Bool) async throws -> WidgetSnapshot {
        let now = Date()
        // The recovery-derived anchor: today's row when it's scored, else the freshest STRICTLY-PRIOR
        // scored day carried over. Resolved through the SHARED `Repository.widgetAnchor`, the ONE selector
        // the watch snapshot and the iOS Live Activity now also use, so all four surfaces describe the same
        // day (the #911 fix; see `Repository.widgetAnchor` for the rollover-drift rationale, the #304
        // pre-04:00 carve-out and the #547 future-day guard it folds in). The `$0.day < carriedKey` bound
        // inside the helper (matching `TodayView.selectedDayKey`) means a stale scored row can never
        // re-surface AS today.
        let day = model.repo.cachedWidgetAnchor(now: now)
        // Rest (sleep_performance) for that same anchor day. exploreSeries merges imported + on-device,
        // exactly like the Today Rest tile. The tail fallback (restSeries.last) is ONLY valid when the
        // anchor day IS the local today: early in a fresh day today's Rest row may not exist yet, so we
        // borrow the latest value. For an anchor that is NOT today, borrowing the tail would surface a
        // DIFFERENT day's Rest as this day's (the cross-day bug), so we leave it nil. Mirrors TodayView's
        // `restByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? restSeries.last?.value : nil)` and the
        // matching guard in WatchSessionBridge.
        let restScore = try await WidgetPublicationBoundary.restScore(
            anchorDay: day?.day, today: Repository.localDayKey(now),
            requiresSuccessfulRead: requiresSuccessfulRead,
            strictRead: {
                try await model.repo.exploreSeriesForExport(key: "sleep_performance", source: "my-whoop")
            }, legacyRead: {
                await model.repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            }, serverOwned: {
                RepositoryServerScores.metric(key: "sleep_performance")
                .map { model.repo.serverPresentation.owns($0) } ?? false
            })
        // #313: honour the user's Effort scale at publish time. The widget extension cannot read the
        // app's plain `@AppStorage(UnitPrefs.effortScaleKey)` (it is not in the App Group), so we
        // pre-format the display string here and keep the 0–100 int for the ring fill (the fill
        // fraction is scale-independent: 38/100 == 8.0/21).
        let effortScale = UnitPrefs.resolveEffortScale(
            UserDefaults.standard.string(forKey: UnitPrefs.effortScaleKey) ?? ""
        )
        let strain = day?.strain
        let effortDisplay: String? = strain.map { stored in
            if effortScale == .whoop {
                return String(format: "%.1f", UnitFormatter.effortValue(stored, scale: .whoop))
            }
            return "\(Int(stored.rounded()))"
        }
        return WidgetSnapshot(
            recovery: day?.recovery.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: Date(),
            // Stored 0–100 axis for ring fill; display string carries the #313 scale.
            effort: strain.map { Int($0.rounded()) },
            rest: restScore.map { Int($0.rounded()) },
            hrv: day?.avgHrv.map { Int($0.rounded()) },
            restingHr: day?.restingHr,
            effortDisplay: effortDisplay,
            effortWhoop: effortScale == .whoop,
            accountNamespace: namespace
        )
    }

    /// Publish fields that come directly from the live BLE state without re-reading the Rest metric
    /// series. HR is admitted once a minute and battery arrives about every eight minutes; routing those
    /// hooks through the full `publish` path used to query up to 4,000 days of Rest history every time even
    /// though none of the score fields could have changed. Reusing the last full snapshot keeps every score
    /// byte-identical and changes only the three live fields. A cold start with no snapshot falls back to a
    /// full build so this fast path can never publish an incomplete first glance. The first live update
    /// after a local-day rollover also takes the full path so the score anchor advances with Today.
    @MainActor
    static func publishLive(from model: AppModel) async {
        guard model.isAccountRuntimeActive, model.accountStorage?.scope != nil else { return }
        let now = Date()
        guard var snap = load(), !liveUpdateRequiresFullBuild(previous: snap, now: now) else {
            await publish(from: model)
            return
        }
        // The loaded value IS the current on-disk state (this runs on the main actor, so nothing else
        // rewrote it between here and the save); hand it to the dedup so the live path reads the App Group
        // ONCE per tick instead of loading it again inside saveAndReloadIfChanged.
        let previous = snap
        snap.bpm = model.bpm ?? model.live.heartRate
        snap.batteryPct = model.live.batteryPct.map { Int($0.rounded()) }
        snap.bonded = model.live.bonded
        snap.updated = now
        saveAndReloadIfChanged(snap, previous: previous)
    }

    /// Persist and ask WidgetKit for a new timeline only when a rendered field changed. The snapshot's
    /// timestamp is metadata only (no widget family displays it), so an otherwise-identical publish is a
    /// true no-op rather than an App-Group write plus an extension reload.
    /// `previous` lets the live fast path pass the snapshot it already loaded (it runs on the main actor,
    /// so that value is still current); the full publish path omits it and this loads once for the dedup.
    @MainActor
    private static func saveAndReloadIfChanged(_ snap: WidgetSnapshot, previous: WidgetSnapshot? = nil) {
        let previous = previous ?? load()
        if renderedContentChanged(from: previous, to: snap) {
            snap.save()
            WidgetCenter.shared.reloadAllTimelines()
        } else if liveUpdateRequiresFullBuild(previous: previous, now: snap.updated) {
            // The rollover's visible values can legitimately match yesterday's. Persist the fresh day
            // stamp once without spending a redundant WidgetKit reload, so later live ticks stay fast.
            snap.save()
        }
    }

    /// #114/#169: HR is the ONE high-frequency widget-publish trigger — `model.bpm` moves every few
    /// seconds during activity, unlike battery (~8 min) or connection flips (rare). Left ungated, the
    /// `model.$bpm` hook rewrote the shared snapshot + called `reloadAllTimelines()` on every tick (and,
    /// before the live-only fast path, also re-read the full Rest series). This caps HR-DRIVEN publishes
    /// to one per `interval`, mirroring Android's `PushGate` 60 s `HR_REFRESH_MS` cadence. Only the bpm
    /// hook consults it; the low-frequency score/battery/connection/scenePhase publish sites stay ungated,
    /// exactly as before. `@MainActor` (the hook already runs there), so the timestamp needs no locking.
    @MainActor
    enum HRPublishThrottle {
        static let interval: TimeInterval = 60
        private static var lastPublishedAt: Date = .distantPast
        /// True (and stamps `now`) when at least `interval` has elapsed since the last HR-driven publish;
        /// false to skip this HR change. The first call always admits (`.distantPast`).
        static func admit(now: Date = Date()) -> Bool {
            guard now.timeIntervalSince(lastPublishedAt) >= interval else { return false }
            lastPublishedAt = now
            return true
        }
    }
}
#endif
