import Foundation
import Combine
import NoopPush
import WhoopStore

@MainActor
final class ServerScoreRepository: ObservableObject {
    /// Root posts this after validated receipts/result invalidation; no payload is needed.
    static let refreshRequested = Notification.Name("noop.serverScores.refreshRequested")
    @Published private(set) var state = ServerScoreViewState.empty
    @Published private(set) var lastError: String?
    @Published private(set) var lastFetchedAt: Date?
    @Published private(set) var signedIn = false
    @Published private(set) var signOutNeedsRetry = false
    @Published private(set) var sleepEditMessage: String?
    @Published private(set) var deviceLinked = false
    @Published private(set) var activeDeviceId: String?

    /// Owner-scoped enrollment overlay used by physiology tests and sleep edits.
    struct Dependencies {
        var ownerId: () -> String?
        var clearSession: () throws -> Void
        var clearIfCurrent: (String, String) -> Bool
        var signIn: (String, String) async throws -> Void
        var fetch: (String, String, String) async throws -> ServerScoreDayCache
        var enabled: () -> Bool
        var ready: () -> Bool
        var automaticPolling = true
        var canonicalDeviceId: (String, String) -> String? = { _, _ in nil }
        var projectURL: () -> String? = { ServerScoringSettings.supabaseProjectURL()?.absoluteString }
        var ownershipStore: ServerMetricOwnershipStore? = nil

        static let live = Dependencies(
            ownerId: {
                CloudRuntimeIdentity.snapshot().scope?.userID
            },
            clearSession: {
                if CloudRuntimeIdentity.currentEnrollmentSnapshot() != nil { try CloudEnrollment.clear() }
                else { try CloudAuthClient.clearSessionChecked() }
            },
            clearIfCurrent: { token, owner in
                if CloudRuntimeIdentity.currentEnrollmentSnapshot() != nil { return CloudEnrollment.clear(ifUploadToken: token, ownerId: owner) }
                return CloudAuthClient.clearSession(ifAccessToken: token, ownerId: owner)
            },
            signIn: { _ = try await CloudAuthClient.signIn(email: $0, password: $1) },
            fetch: { try await CanonicalScoreTransport.fetch(day: $0, owner: $1, localDevice: $2) },
            enabled: { ServerScoringSettings.isEnabled }, ready: { ServerScoringSettings.ready },
            canonicalDeviceId: { CanonicalScoreTransport.canonicalDevice(owner: $0, localDevice: $1) })
    }

    typealias Fetch = @Sendable (String, AccountSessionContext) async throws -> ServerScoreResponse
    typealias Restore = @Sendable (ServerScoreCachedSnapshot) async throws -> ServerScoreSnapshot
    enum RefreshReason: Equatable { case automatic, userInitiated, invalidation, poll }
    struct RefreshPolicy {
        var currentDay: TimeInterval = 45
        var historicalDay: TimeInterval = 5 * 60
        var pending: TimeInterval = 15
        var failure: TimeInterval = 15
        var maximumFailure: TimeInterval = 5 * 60
    }
    private struct ReadAdmission {
        let attemptedAt: Date
        let nextAttempt: Date
        let invalidation: UInt64
        let failures: Int
    }
    private let fetchSnapshot: Fetch
    private let restoreSnapshot: Restore
    private let now: () -> Date
    private let refreshPolicy: RefreshPolicy
    private var context: AccountSessionContext?
    private var cache: ServerScoreSnapshotCache?
    private var epoch = UUID()
    private var timeZone = TimeZone.current
    private var explicitTimeZone = false
    private var foreground = true
    private var retired = false
    private var selectedDay: String?
    private var pollTask: Task<Void, Never>?
    private var hydrationTask: Task<Void, Never>?
    private var hydrationID: UUID?
    private var cacheHydration: (id: UUID, task: Task<Void, Never>)?
    private var hydratedEpoch: UUID?
    private var requests: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var admissions: [String: ReadAdmission] = [:]
    private var invalidations: [String: UInt64] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private let legacy: Dependencies?
    private var cacheStore: ServerScoreCacheStore?
    private var cacheProjectURL: String?
    private var session = ServerScoreSessionState()
    private var visibleDays = Set<String>()
    private var enrolledDays: [String: ServerScoreDayCache] = [:]
    private let ownershipStore: ServerMetricOwnershipStore
    private var ownership: ServerMetricOwnership?
    private struct EnrollmentReadIdentity: Equatable {
        let project: String?, owner: String?, localDevice: String?, source: String?, token: String?
    }
    private var enrollmentReadIdentity: EnrollmentReadIdentity?
    private var enrollmentReadFailures = Set<String>()
    private var currentEnrollmentReadIdentity: EnrollmentReadIdentity {
        let credential = CloudEnrollment.currentCredential()
        let context = CloudRuntimeIdentity.snapshot().context
        return .init(project: legacy?.projectURL(), owner: currentOwnerId,
            localDevice: activeDeviceId, source: context.map { CloudPushSettings.sourceId(scope: $0.scope) },
            token: credential?.tokenId ?? CloudAuthClient.storedSession()?.accessToken)
    }
    private var linkInFlight = false
    private var pollingDay: String?
    private var currentOwnerId: String? { legacy?.ownerId()?.lowercased() }
    var usesEnrollmentReadback: Bool { legacy != nil }

    init(dependencies: Dependencies) {
        legacy = dependencies
        ownershipStore = dependencies.ownershipStore ?? ServerMetricOwnershipStore()
        fetchSnapshot = { _, _ in throw ServerScoreClient.FetchError.notConfigured }
        restoreSnapshot = { _ in throw ServerScoreDecodeError.invalid }
        now = { Date() }
        refreshPolicy = .init()
        signedIn = dependencies.ownerId() != nil
        session.activate(ownerId: dependencies.ownerId())
        NotificationCenter.default.publisher(for: .cloudEnrollmentDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.enrollmentChanged() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: CloudAuthClient.identityDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.enrollmentChanged() }
            .store(in: &subscriptions)
    }

    init(fetch: @escaping Fetch = { try await ServerScoreClient.fetchDaySnapshot(day: $0, context: $1) },
         now: @escaping () -> Date = { Date() }, refreshPolicy: RefreshPolicy = .init(),
         restore: @escaping Restore = { try await ServerScoreDecodeWorker.shared.restore($0) }) {
        legacy = nil
        ownershipStore = ServerMetricOwnershipStore()
        fetchSnapshot = fetch
        restoreSnapshot = restore
        self.now = now
        self.refreshPolicy = refreshPolicy
        synchronizeIdentity()
        restoreSignOutFailure()
        NotificationCenter.default.publisher(for: .cloudEnrollmentDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.retired else { return }
                self.synchronizeIdentity()
                self.restoreDeviceLink()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: CloudAuthClient.identityDidChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, !self.retired else { return }
                self.synchronizeIdentity()
                self.restoreSignOutFailure()
                self.hydrateAndRefresh()
                self.startPolling(todayKey: self.currentDay)
            }.store(in: &subscriptions)
        for name in [Self.refreshRequested, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                     ServerScoringSettings.settingsDidChange] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] note in
                    guard let self, !self.retired else { return }
                    if note.name == .NSSystemTimeZoneDidChange, !self.explicitTimeZone { self.setTimeZone(.current) }
                    self.publish(days: self.state.days)
                    self.invalidateVisibleDays()
                    if self.foreground {
                        Task { [weak self] in await self?.refreshVisibleDays() }
                    }
                }.store(in: &subscriptions)
        }
    }

    var currentDay: String { ServerScoreDate.day(now(), timeZone: timeZone) }

    func wire(store: WhoopStore) {
        if legacy != nil {
            cacheStore = ServerScoreCacheStore(db: store.registryWriter)
            cacheProjectURL = legacy?.projectURL()
            session.activate(ownerId: currentOwnerId)
            signedIn = currentOwnerId != nil
            preloadFromDisk()
            return
        }
        installCache(store: store)
        hydrateAndRefresh()
    }

    /// Launch may await cached ownership without waiting for a network request or maintenance.
    func wireAndHydrate(store: WhoopStore) async {
        if legacy != nil {
            wire(store: store)
            return
        }
        installCache(store: store)
        await hydrate()
    }

    private func installCache(store: WhoopStore) {
        guard !retired else { return }
        epoch = UUID()
        hydratedEpoch = nil
        cancelHydration()
        cancelRequests()
        cache = ServerScoreSnapshotCache(db: store.registryWriter)
        synchronizeIdentity()
    }

    func configure(timeZone: TimeZone) {
        explicitTimeZone = true
        setTimeZone(timeZone)
    }

    private func setTimeZone(_ zone: TimeZone) {
        guard zone.identifier != timeZone.identifier else { return }
        timeZone = zone
        epoch = UUID()
        cancelRequests()
        cancelHydration()
        admissions.removeAll()
        invalidations.removeAll()
        hydratedEpoch = nil
        selectedDay = nil
        publish(days: [:])
        hydrateAndRefresh()
    }

    func setForeground(_ active: Bool) {
        guard !retired else { return }
        foreground = active
        if active {
            synchronizeIdentity()
            hydrateAndRefresh()
            startPolling(todayKey: currentDay)
        } else {
            stopPolling()
            cancelHydration()
            cancelRequests()
        }
    }

    /// Discards this runtime without signing out a replacement account runtime.
    func invalidate() {
        retired = true
        foreground = false
        epoch = UUID()
        stopPolling()
        cancelHydration()
        cancelRequests()
        subscriptions.removeAll()
        if let context { ServerScoreReadTransport.retire(context: context) }
        context = nil
        admissions.removeAll()
        invalidations.removeAll()
        hydratedEpoch = nil
        signedIn = false
        deviceLinked = false
        session.activate(ownerId: nil)
        lastFetchedAt = nil
        lastError = nil
        state = .empty
        if let cache { Task { await cache.activate(nil) } }
    }

    func signIn(email: String, password: String) async {
        if let dependencies = legacy {
            stopPolling()
            ownership = nil
            ServerScoringSettings.bindComputeOwnership(nil)
            do { try dependencies.clearSession() }
            catch { signOutNeedsRetry = true; lastError = "Session changes could not be saved"; return }
            CloudScoreIdentity.clearIngestOwner()
            session.activate(ownerId: nil)
            signedIn = false
            deviceLinked = false
            lastFetchedAt = nil
            sleepEditMessage = nil
            let attempt = session.generation
            do {
                try await dependencies.signIn(email, password)
                guard attempt == session.generation else { return }
                session.activate(ownerId: currentOwnerId)
                signedIn = true
                lastError = nil
                preloadFromDisk()
                await refreshVisibleDays()
                startPolling(todayKey: pollingDay ?? Repository.dayString(Date()))
            } catch {
                guard attempt == session.generation else { return }
                signedIn = false
                lastError = "Sign-in failed"
            }
            return
        }
        do {
            _ = try await CloudAuthClient.signIn(email: email, password: password)
            guard !retired else { return }
            synchronizeIdentity()
            lastError = nil
            await hydrate()
            await refreshVisibleDays(reason: .userInitiated)
            startPolling(todayKey: currentDay)
        } catch {
            guard !retired else { return }
            synchronizeIdentity()
            lastError = "Sign-in failed"
        }
    }

    func signOut() {
        if let dependencies = legacy {
            enrolledDays.removeAll()
            enrollmentReadFailures.removeAll()
            ownership = nil
            ServerScoringSettings.bindComputeOwnership(nil)
            state = .empty
            do { try dependencies.clearSession(); signOutNeedsRetry = false }
            catch { signOutNeedsRetry = true; lastError = "Sign-out could not be saved. Retry before closing NARA."; return }
            CloudScoreIdentity.clearIngestOwner()
            signedIn = false
            deviceLinked = false
            stopPolling()
            session.activate(ownerId: nil)
            lastFetchedAt = nil
            lastError = nil
            sleepEditMessage = nil
            return
        }
        do {
            try CloudAuthClient.clearSessionChecked()
            synchronizeIdentity()
            signOutNeedsRetry = false
            lastError = nil
        } catch {
            synchronizeIdentity()
            signOutNeedsRetry = true
            lastError = "Sign-out could not be saved. Access is stopped for this session; retry before closing the app."
        }
    }

    /// The linking screen owns enrollment, regardless of which dashboard reader is installed.
    func signOutEnrollment() {
        stopPolling()
        cancelRequests()
        enrolledDays.removeAll()
        ownership = nil
        ServerScoringSettings.bindComputeOwnership(nil)
        state = .empty
        session.activate(ownerId: nil)
        deviceLinked = false
        do {
            try CloudEnrollment.clear()
            CloudScoreIdentity.clearIngestOwner()
            lastError = nil
        } catch {
            lastError = "Sign-out could not be saved. Please try again before closing NARA."
        }
    }

    func retryDeviceLink() async {
        guard !retired, !linkInFlight else { return }
        restoreDeviceLink()
        guard !deviceLinked else { return }
        guard let local = activeDeviceId,
              let owner = CloudEnrollment.currentCredential()?.userId else {
            lastError = "Your account or strap is still loading. Retry in a moment."
            return
        }
        do {
            linkInFlight = true
            defer { linkInFlight = false }
            _ = try await ServerScoreClient.confirmDeviceLink(localDeviceId: local, expectedOwnerId: owner)
            guard !retired, !Task.isCancelled, activeDeviceId == local,
                  CloudEnrollment.currentCredential()?.userId == owner else { return }
            restoreDeviceLink()
            if deviceLinked { lastError = nil }
        } catch {
            guard !retired, !Task.isCancelled, activeDeviceId == local,
                  CloudEnrollment.currentCredential()?.userId == owner else { return }
            lastError = "Could not confirm this strap. Check your internet connection and retry."
        }
    }

    private func restoreSignOutFailure() {
        // The identity notification can replace this repository before the caller catches.
        if context == nil, CloudAuthClient.lastPersistenceError == .credentialUnavailable {
            signOutNeedsRetry = true
            lastError = "Credential storage is unavailable. Retry sign-out before closing the app."
        }
    }

    func setActivated(_ metrics: Set<ServerScoreMetric>, enabled: Bool) {
        synchronizeIdentity()
        guard let context, CloudAuthClient.isCurrent(context), state.configured else { return }
        var activated = state.activated
        if enabled { activated.formUnion(metrics.intersection(state.capabilities)) }
        else { activated.subtract(metrics) }
        ServerScoringSettings.setActivated(activated, scope: context.scope)
        publish(days: state.days)
        if foreground { Task { [weak self] in await self?.refreshVisibleDays() } }
    }

    func startPolling(todayKey: String) {
        guard !retired else { return }
        if let dependencies = legacy {
            pollingDay = todayKey
            guard dependencies.ready(), dependencies.automaticPolling else { return }
            guard signedIn, activeDeviceId != nil else { return }
            stopPolling()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.legacyFetch(day: todayKey)
                    try? await Task.sleep(for: .seconds(ServerScoringSettings.pollIntervalSeconds))
                }
            }
            return
        }
        guard !retired, foreground else { return }
        synchronizeIdentity()
        guard state.configured, signedIn else { return }
        // The compatibility argument is not captured: each iteration recalculates today.
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.hydrationTask?.value
            while !Task.isCancelled {
                guard let self, self.foreground, !self.retired else { return }
                await self.refreshVisibleDays(reason: .poll)
                do { try await Task.sleep(for: .seconds(ServerScoringSettings.pollIntervalSeconds)) }
                catch { return }
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    private func invalidateVisibleDays() {
        for day in Set([currentDay, selectedDay].compactMap({ $0 })) {
            invalidations[day, default: 0] &+= 1
        }
    }

    func refreshVisibleDays(todayKey: String? = nil, reason: RefreshReason = .automatic) async {
        guard !retired else { return }
        if legacy != nil {
            synchronizeOwner()
            guard let dependencies = legacy, dependencies.ready(), signedIn, activeDeviceId != nil else { return }
            if let todayKey { visibleDays.insert(todayKey) }
            if visibleDays.isEmpty { visibleDays.insert(pollingDay ?? Repository.dayString(Date())) }
            for day in visibleDays.sorted() { await legacyFetch(day: day) }
            return
        }
        guard !retired else { return }
        synchronizeIdentity()
        if let day = todayKey, ServerScoreDate.isDay(day) { selectedDay = day }
        guard foreground else { return }
        await confirmSelectedDeviceLink()
        guard deviceLinked else { return }
        publish(days: state.days)
        guard signedIn, state.configured else { return }
        let current = currentDay
        let days = selectedDay.map { $0 == current ? [current] : [$0, current] } ?? [current]
        if reason == .invalidation {
            for day in days { invalidations[day, default: 0] &+= 1 }
        }
        for day in days {
            guard !Task.isCancelled else { return }
            await fetch(day: day, reason: reason)
        }
    }

    func refreshRecentDays(limit: Int = 14, reason: RefreshReason = .automatic) async {
        if legacy != nil {
            await refreshVisibleDays(reason: reason)
            return
        }
        await refreshVisibleDays(reason: reason)
        for offset in 1..<max(1, min(limit, 14)) {
            guard foreground, !retired, !Task.isCancelled else { return }
            let day = ServerScoreDate.offsetDay(currentDay, by: -offset, timeZone: timeZone)
            guard day != selectedDay else { continue }
            if reason == .invalidation { invalidations[day, default: 0] &+= 1 }
            await fetch(day: day, reason: reason)
        }
    }

    /// Kept for older non-product call sites. Views must use state to distinguish null from local ownership.
    func overlay(for day: String) -> ServerScoreDayCache? {
        if let dependencies = legacy {
            synchronizeOwner()
            visibleDays.insert(day)
            let cache = session.overlay(day: day, currentOwnerId: currentOwnerId)
            if let ownership { return ownership.presentation(cache, day: day, readFailed: enrollmentReadFailures.contains(day)) }
            return dependencies.enabled() ? cache : nil
        }
        guard state.hasServerOwnership, let snapshot = state.days[day]?.snapshot else { return nil }
        var cache = ServerScoreDayCache(day: day, algorithmVersion: snapshot.algorithmVersion,
            daily: snapshot.daily.map {
                var daily = ServerScoreDailyCache(hrvRmssdMs: $0[.hrv], restingHrBpm: $0[.restingHR].map { Int($0.rounded()) },
                    sleepTotalMin: $0[.sleepTotal], sleepInBedMin: $0[.sleepInBed], sleepAwakeMin: $0[.sleepAwake],
                    sleepLightMin: $0[.sleepLight], sleepDeepMin: $0[.sleepDeep], sleepRemMin: $0[.sleepREM],
                    sleepEfficiency: $0[.sleepEfficiency], respRateBpm: $0[.respiration], computedAt: snapshot.computedAt)
                daily.recovery = $0[.recovery]
                daily.strain = $0[.strain]
                daily.spo2Pct = $0[.spo2]
                daily.skinTempC = $0[.skinTemperature]
                daily.skinTempDevC = $0[.skinTemperatureDeviation]
                return daily
            }, nights: [], computedAt: snapshot.computedAt,
            stale: state.days[day]?.pending == true || state.days[day]?.cached == true,
            fetchedAt: state.days[day]?.fetchedAt ?? now())
        cache.ownerId = snapshot.userId.lowercased()
        return cache
    }

    private var cacheSession: ServerScoreCacheSession? {
        context.map { ServerScoreCacheSession(owner: ServerScoreCacheOwner(projectURL: $0.scope.projectURL, userID: $0.scope.userID),
                                              generation: $0.generation) }
    }

    private func synchronizeIdentity() {
        guard legacy == nil else { return }
        let next = CloudAuthClient.currentContext()
        guard next != context else { return }
        epoch = UUID()
        stopPolling()
        cancelHydration()
        cancelRequests()
        if let context { ServerScoreReadTransport.retire(context: context) }
        admissions.removeAll()
        invalidations.removeAll()
        hydratedEpoch = nil
        context = next
        signedIn = next != nil
        restoreDeviceLink()
        selectedDay = nil
        lastFetchedAt = nil
        lastError = nil
        publish(days: [:], capabilities: next.map { ServerScoringSettings.knownCapabilities(scope: $0.scope) } ?? [])
    }

    private func isCurrent(_ expected: AccountSessionContext, epoch token: UUID) -> Bool {
        !retired && context == expected && epoch == token && CloudAuthClient.isCurrent(expected)
    }

    private func cancelRequests() {
        for entry in requests.values { entry.task.cancel() }
        requests.removeAll()
    }

    private func cancelHydration() {
        hydrationTask?.cancel()
        hydrationTask = nil
        hydrationID = nil
        cacheHydration?.task.cancel()
        cacheHydration = nil
    }

    private func hydrateAndRefresh() {
        guard !retired, foreground, hydrationTask == nil else { return }
        let id = UUID()
        hydrationID = id
        hydrationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.hydrationID == id { self.hydrationTask = nil; self.hydrationID = nil }
            }
            await self.hydrate()
            guard !Task.isCancelled else { return }
            await self.refreshVisibleDays()
        }
    }

    private func hydrate() async {
        guard hydratedEpoch != epoch else { return }
        if let current = cacheHydration { await current.task.value; return }
        let id = UUID()
        let work = Task<Void, Never> { [weak self] in await self?.performHydration() }
        cacheHydration = (id, work)
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if cacheHydration?.id == id { cacheHydration = nil }
    }

    private func performHydration() async {
        guard hydratedEpoch != epoch else { return }
        guard let cache, let session = cacheSession, let expected = context else { return }
        let token = epoch
        let interval = SyncPipelineTrace.begin(.cacheLoad)
        var outcome: SyncPipelineTrace.Outcome = .failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        do {
            await cache.activate(session)
            guard isCurrent(expected, epoch: token), !Task.isCancelled else { outcome = .cancelled; return }
            let rows = try await cache.loadRecent(session: session, timeZoneID: timeZone.identifier)
            var days = state.days
            var capabilities = state.capabilities
            for row in rows {
                let snapshot = try await restoreSnapshot(row)
                guard isCurrent(expected, epoch: token), !Task.isCancelled else { outcome = .cancelled; return }
                if state.days[snapshot.day]?.snapshot != nil { continue }
                capabilities.formUnion(snapshot.supported)
                days[snapshot.day] = ServerScoreDayState(snapshot: snapshot, phase: phase(snapshot.status), fetchedAt: row.fetchedAt,
                    cached: true, pending: false, requestedInputRevision: nil, archiveStatus: nil)
            }
            guard isCurrent(expected, epoch: token), !Task.isCancelled else { outcome = .cancelled; return }
            // Disk hydration cannot roll back a newer in-memory result or erase a fetch failure.
            for (day, entry) in state.days {
                if entry.snapshot != nil || days[day]?.snapshot == nil { days[day] = entry }
                else if let restored = days[day] {
                    days[day] = ServerScoreDayState(snapshot: restored.snapshot, phase: entry.phase,
                        fetchedAt: restored.fetchedAt, cached: true, pending: entry.pending,
                        requestedInputRevision: entry.requestedInputRevision, archiveStatus: entry.archiveStatus)
                }
            }
            publish(days: days, capabilities: capabilities.union(state.capabilities))
            hydratedEpoch = token
            outcome = rows.isEmpty ? .pending : .succeeded
        } catch {
            if !isCurrent(expected, epoch: token) || Task.isCancelled { outcome = .cancelled; return }
            lastError = "Cached server scores unavailable"
        }
    }

    private func fetch(day: String, reason: RefreshReason, followInvalidation: Bool = true) async {
        guard !retired, foreground, let expected = context, state.configured else { return }
        if let existing = requests[day] { await existing.task.value; return }
        guard admits(day: day, reason: reason) else { return }
        let id = UUID()
        let token = epoch
        let invalidation = invalidations[day, default: 0]
        let work = Task<Void, Never> { [weak self] in
            await self?.performFetch(day: day, expected: expected, token: token, invalidation: invalidation)
        }
        requests[day] = (id, work)
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if requests[day]?.id == id { requests.removeValue(forKey: day) }
        // A receipt arriving during this request may describe work the response could not observe.
        // Coalesce those edges into one trailing read; sustained changes retain ordinary polling.
        if followInvalidation, isCurrent(expected, epoch: token), !Task.isCancelled,
           invalidations[day, default: 0] != invalidation {
            await fetch(day: day, reason: .automatic, followInvalidation: false)
        }
    }

    private func admits(day: String, reason: RefreshReason) -> Bool {
        guard reason != .userInitiated else { return true }
        guard let admission = admissions[day] else { return true }
        let date = now()
        // A wall-clock rollback must not extend a transient failure pause indefinitely.
        if date < admission.attemptedAt { return true }
        if admission.failures > 0 { return date >= admission.nextAttempt }
        return admission.invalidation != invalidations[day, default: 0] || date >= admission.nextAttempt
    }

    private func recordAdmission(day: String, invalidation: UInt64, failed: Bool, pending: Bool = false) {
        let date = now()
        let failures = failed ? min(10, (admissions[day]?.failures ?? 0) + 1) : 0
        let interval = failed
            ? min(refreshPolicy.maximumFailure, refreshPolicy.failure * pow(2, Double(failures - 1)))
            : (pending ? refreshPolicy.pending : (day == currentDay ? refreshPolicy.currentDay : refreshPolicy.historicalDay))
        admissions[day] = ReadAdmission(attemptedAt: date, nextAttempt: date.addingTimeInterval(max(0, interval)),
                                        invalidation: invalidation, failures: failures)
        // Navigation is unbounded, but retry/freshness bookkeeping is not.
        let keep = Set([currentDay, selectedDay, day].compactMap { $0 }).union(requests.keys)
        for key in admissions.keys.sorted(by: { admissions[$0]!.attemptedAt < admissions[$1]!.attemptedAt })
            where admissions.count > 32 && !keep.contains(key) {
            admissions.removeValue(forKey: key)
            invalidations.removeValue(forKey: key)
        }
    }

    private func performFetch(day: String, expected: AccountSessionContext, token: UUID, invalidation: UInt64) async {
        let interval = SyncPipelineTrace.begin(.scoreRefresh)
        var outcome: SyncPipelineTrace.Outcome = .failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        setDay(day, (state.days[day] ?? .empty(.loading)).retaining(.loading))
        do {
            let response = try await fetchSnapshot(day, expected)
            try Task.checkCancellation()
            guard isCurrent(expected, epoch: token) else { outcome = .cancelled; return }
            if let user = response.userId, user.lowercased() != expected.scope.userID.lowercased() { throw ServerScoreDecodeError.invalid }
            if let zone = response.timezone, zone != timeZone.identifier {
                setDay(day, (state.days[day] ?? .empty(.timezoneMismatch)).retaining(.timezoneMismatch))
                recordAdmission(day: day, invalidation: invalidation, failed: true)
                return
            }
            if let snapshot = response.snapshot {
                if let previous = state.days[day]?.snapshot, sameNamespace(previous, snapshot),
                   previous.resultRevision == snapshot.resultRevision, previous != snapshot {
                    throw ServerScoreSnapshotCacheError.revisionConflict
                }
                if let previous = state.days[day]?.snapshot, sameNamespace(previous, snapshot),
                   (snapshot.resultRevision < previous.resultRevision || snapshot.inputRevision < previous.inputRevision) {
                    setDay(day, state.days[day]!.retaining(.pending))
                    recordAdmission(day: day, invalidation: invalidation, failed: false, pending: true)
                    outcome = .stale; return
                }
                if let cache, let session = cacheSession {
                    let row = try await ServerScoreDecodeWorker.shared.prepare(snapshot, owner: session.owner, now: now())
                    guard isCurrent(expected, epoch: token), !Task.isCancelled else { outcome = .cancelled; return }
                    await cache.activate(session)
                    guard isCurrent(expected, epoch: token), !Task.isCancelled else { outcome = .cancelled; return }
                    let result = try await cache.store(row, session: session)
                    guard isCurrent(expected, epoch: token), !Task.isCancelled else { outcome = .cancelled; return }
                    if result == .ignoredOlderRevision {
                        recordAdmission(day: day, invalidation: invalidation, failed: false, pending: true)
                        outcome = .stale; return
                    }
                }
                let capabilities = state.capabilities.union(snapshot.supported)
                ServerScoringSettings.setKnownCapabilities(capabilities, scope: expected.scope)
                let entry = ServerScoreDayState(snapshot: snapshot, phase: phase(snapshot.status), fetchedAt: now(),
                    cached: false, pending: response.pending, requestedInputRevision: response.requestedInputRevision,
                    archiveStatus: response.archiveStatus)
                var days = state.days
                days[day] = entry
                publish(days: days, capabilities: capabilities)
                lastFetchedAt = entry.fetchedAt
                lastError = nil
                outcome = response.pending ? .waitingForServer : .succeeded
                recordAdmission(day: day, invalidation: invalidation, failed: false, pending: response.pending)
            } else {
                setDay(day, ServerScoreDayState(snapshot: state.days[day]?.snapshot, phase: phase(response.status),
                    fetchedAt: state.days[day]?.fetchedAt, cached: state.days[day]?.snapshot != nil,
                    pending: response.pending, requestedInputRevision: response.requestedInputRevision, archiveStatus: response.archiveStatus))
                if response.status == "pending" || response.status == "failed" {
                    let capabilities = state.capabilities.union(ServerScoreMetric.schema2)
                    ServerScoringSettings.setKnownCapabilities(capabilities, scope: expected.scope)
                    publish(days: state.days, capabilities: capabilities)
                }
                outcome = response.status == "pending" ? .waitingForServer : .failed
                recordAdmission(day: day, invalidation: invalidation,
                                failed: response.status == "failed", pending: response.pending || response.status == "pending")
            }
        } catch {
            guard isCurrent(expected, epoch: token) else { outcome = .cancelled; return }
            if Task.isCancelled || error is CancellationError { outcome = .cancelled; return }
            let status: ServerScoreDayState.Phase
            if case ServerScoreDecodeError.unsupportedSchema = error { status = .unsupported }
            else if case ServerScoreClient.FetchError.unauthorized = error { status = .authenticationRequired; outcome = .authenticationRequired }
            else if (error as? URLError)?.code == .notConnectedToInternet { status = .offline; outcome = .offline }
            else { status = .failed }
            setDay(day, (state.days[day] ?? .empty(status)).retaining(status))
            lastError = state.days[day]?.note
            recordAdmission(day: day, invalidation: invalidation, failed: true)
        }
    }

    private func phase(_ value: String) -> ServerScoreDayState.Phase {
        switch value {
        case "available": return .available
        case "partial": return .partial
        case "no_data": return .noData
        case "pending": return .pending
        case "unsupported": return .unsupported
        default: return .failed
        }
    }

    private func sameNamespace(_ lhs: ServerScoreSnapshot, _ rhs: ServerScoreSnapshot) -> Bool {
        lhs.userId.lowercased() == rhs.userId.lowercased() && lhs.sourceDeviceId == rhs.sourceDeviceId
            && lhs.day == rhs.day && lhs.timezone == rhs.timezone && lhs.schemaVersion == rhs.schemaVersion
            && lhs.algorithmVersion == rhs.algorithmVersion
    }

    private func setDay(_ day: String, _ entry: ServerScoreDayState) {
        var days = state.days
        days[day] = entry
        publish(days: days)
    }

    private func publish(days input: [String: ServerScoreDayState], capabilities: Set<ServerScoreMetric>? = nil) {
        let interval = SyncPipelineTrace.begin(.snapshotPublication)
        defer { SyncPipelineTrace.end(interval, outcome: .succeeded) }
        var days = input
        let keep = Set([currentDay, selectedDay].compactMap { $0 })
        for key in days.keys.sorted() where days.count > 14 && !keep.contains(key) { days.removeValue(forKey: key) }
        let authenticated = context.map(CloudAuthClient.isCurrent) ?? false
        if signedIn != authenticated { signedIn = authenticated }
        let configured = ServerScoringSettings.isEnabled && ServerScoringSettings.anonKey() != nil && context != nil
        let activated = context.map { ServerScoringSettings.activatedMetrics(scope: $0.scope) } ?? []
        let nextCapabilities = capabilities ?? state.capabilities
        let sameOwnership = state.generation == context?.generation && state.currentDay == currentDay
            && state.timezone == timeZone.identifier && state.configured == configured
            && state.authenticated == authenticated && state.capabilities == nextCapabilities && state.activated == activated
        let contentUnchanged = sameOwnership && Set(state.days.keys).union(days.keys).allSatisfy { day in
            switch (state.days[day]?.snapshot, days[day]?.snapshot) {
            case (nil, nil): return true
            case let (old?, next?):
                return sameNamespace(old, next)
                    && old.inputRevision == next.inputRevision && old.resultRevision == next.resultRevision
            default: return false
            }
        }
        let next = ServerScoreViewState(generation: context?.generation,
            revision: contentUnchanged ? state.revision : state.revision &+ 1,
            currentDay: currentDay, timezone: timeZone.identifier,
            configured: configured, authenticated: authenticated, capabilities: nextCapabilities,
            activated: activated, days: days)
        if next != state {
            state = next
            if let day = next.days[currentDay], !day.cached, !day.pending, let snapshot = day.snapshot {
                SyncPipelineTrace.freshness(.projectionReady,
                    sourceDate: SyncPipelineTrace.sourceDate(snapshot.computedAt))
            }
        }
    }

    func selectDevice(localDeviceId: String?) {
        let selected = localDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = selected?.isEmpty == false ? selected : nil
        guard next != activeDeviceId else { return }
        stopPolling()
        activeDeviceId = next
        ownership = nil
        ServerScoringSettings.bindComputeOwnership(nil)
        deviceLinked = false
        if legacy != nil {
            enrolledDays.removeAll()
            state = .empty
            session.activate(ownerId: currentOwnerId)
            lastFetchedAt = nil
            lastError = nil
            sleepEditMessage = nil
            preloadFromDisk()
            if let day = pollingDay { startPolling(todayKey: day) }
        } else {
            // PR 22 moved the primary reader to account-scoped snapshots, but the gate still
            // relies on the enrolled-device receipt. Restore it before a score read so an
            // already-confirmed strap never waits on an unrelated result request.
            restoreDeviceLink()
        }
    }

    func enrollmentChanged() {
        synchronizeOwner()
        if let day = pollingDay { startPolling(todayKey: day) }
    }

    func saveSleepOverride(_ target: ServerSleepEditTarget, start: Int, end: Int, tombstone: Bool) async -> Bool {
        synchronizeOwner()
        guard let dependencies = legacy, dependencies.ready(), let localDeviceId = activeDeviceId,
              target.ownerId == session.ownerId,
              let cache = session.overlay(day: target.day, currentOwnerId: currentOwnerId),
              cache.features["sleep"]?.deviceId == target.deviceId,
              cache.features["sleep"]?.supportsBoundaryOverrides == true else {
            lastError = "The account or sleep source changed. Refresh before editing."
            return false
        }
        let generation = session.generation, key = "override:\(target.id)"
        let request = session.beginRequest(day: key)
        lastError = nil
        do {
            _ = try await ServerScoreClient.saveSleepOverride(target, localDeviceId: localDeviceId, start: start, end: end, tombstone: tombstone)
            guard !Task.isCancelled, session.isCurrentRequest(day: key, generation: generation, currentOwnerId: currentOwnerId, request: request) else { return false }
            sleepEditMessage = tombstone ? "Sleep deleted. Server recomputation queued." : "Sleep boundaries saved. Server recomputation queued."
            await legacyFetch(day: target.day)
            return generation == session.generation && currentOwnerId == target.ownerId
        } catch {
            synchronizeOwner()
            guard !Task.isCancelled, session.isCurrentRequest(day: key, generation: generation, currentOwnerId: currentOwnerId, request: request) else { return false }
            if case ServerScoreClient.FetchError.unauthorized = error,
               let token = CloudEnrollment.currentCredential()?.uploadToken,
               dependencies.clearIfCurrent(token, target.ownerId) {
                synchronizeOwner()
                lastError = "Session expired — sign in again"
            } else if case ServerScoreClient.FetchError.conflict = error {
                await legacyFetch(day: target.day)
                guard generation == session.generation, currentOwnerId == target.ownerId else { return false }
                lastError = "This sleep was changed elsewhere. Close the editor and reopen it to use the latest revision."
            } else {
                lastError = "Sleep changes were not confirmed. Refresh before retrying; local sleep records were not changed."
            }
            return false
        }
    }

    private func legacyFetch(day: String) async {
        guard !retired, let dependencies = legacy else { return }
        synchronizeOwner()
        guard let owner = session.ownerId, let device = activeDeviceId else { return }
        let generation = session.generation
        let request = session.beginRequest(day: day)
        do {
            let cache = try await dependencies.fetch(day, owner, device)
            synchronizeOwner()
            guard ServerComputeRevisionFence.admits(previous: enrolledDays[day] ?? cachedDay(ownerId: owner, day: day), next: cache) else {
                throw ServerScoreClient.FetchError.invalidResponse
            }
            guard !Task.isCancelled, generation == session.generation, cache.day == day,
                  activeDeviceId == device,
                  session.accept(cache, generation: generation, currentOwnerId: currentOwnerId, request: request)
            else { return }
            CloudScoreIdentity.rememberOwner(cache.ownerId)
            deviceLinked = cache.features.values.contains { $0.deviceId != nil }
            observeOwnership(cache)
            if cacheProjectURL == dependencies.projectURL() { try cacheStore?.upsert(cache) }
            enrolledDays[day] = cache
            enrollmentReadFailures.remove(day)
            publishEnrolledDays()
            lastFetchedAt = cache.fetchedAt
            lastError = nil
        } catch ServerScoreClient.FetchError.unauthorized {
            synchronizeOwner()
            guard !Task.isCancelled, session.isCurrentRequest(day: day, generation: generation, currentOwnerId: currentOwnerId, request: request) else { return }
            if let token = CloudEnrollment.currentCredential()?.uploadToken ?? CloudAuthClient.storedSession()?.accessToken {
                _ = dependencies.clearIfCurrent(token, owner)
            }
            signedIn = false
            session.activate(ownerId: nil)
            enrolledDays.removeAll()
            enrollmentReadFailures.removeAll()
            ownership = nil
            ServerScoringSettings.bindComputeOwnership(nil)
            state = .empty
            deviceLinked = false
            lastError = "Session expired — sign in again"
        } catch {
            synchronizeOwner()
            guard !Task.isCancelled, session.isCurrentRequest(day: day, generation: generation, currentOwnerId: currentOwnerId, request: request) else { return }
            restoreDeviceLink()
            lastError = "Server scores unavailable"
            enrollmentReadFailures.insert(day)
            if let ownerId = session.ownerId, let cached = cachedDay(ownerId: ownerId, day: day) {
                observeOwnership(cached)
                session.accept(cached, generation: generation, currentOwnerId: currentOwnerId, request: request)
                enrolledDays[day] = cached
            }
            publishEnrolledDays()
        }
    }

    private func preloadFromDisk() {
        restoreDeviceLink()
        guard let owner = session.ownerId else { return }
        restoreOwnership(owner: owner)
        let cal = Calendar.current
        let today = Date()
        for offset in 0..<14 {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Repository.dayString(date)
            if let row = cachedDay(ownerId: owner, day: key) {
                observeOwnership(row)
                session.accept(row, generation: session.generation, currentOwnerId: currentOwnerId)
                enrolledDays[key] = row
            }
        }
        publishEnrolledDays()
    }

    private func publishEnrolledDays() {
        guard !retired, legacy != nil, let owner = currentOwnerId,
              owner == session.ownerId else { return }
        // Ownership comes only from the durable scope, never the current day's availability.
        let metrics = Set(ownership?.metrics.compactMap(ServerScoreMetric.init(rawValue:)) ?? [])
        var readStates: [String: ServerScoreDayState] = [:]
        for (day, cache) in enrolledDays where cache.ownerId == owner {
            let authorizedFeatures = cache.features.values.filter(\.hasCanonicalAuthorization)
            let pending = authorizedFeatures.contains { feature in
                ["pending", "running", "retry"].contains(feature.processingStatus ?? "") ||
                    feature.status == "pending" ||
                    (feature.requiredRevision.map { $0 > (feature.inputRevision ?? 0) } ?? false)
            }
            let failed = authorizedFeatures.contains {
                ["failed", "exhausted"].contains($0.processingStatus ?? "")
            }
            // A completed, empty result is not an indefinitely running calculation.
            // The endpoint's revision fields stay on the feature envelope, not a fabricated snapshot.
            let d = cache.daily
            let hasValues = [d?.hrvRmssdMs, d?.restingHrBpm.map(Double.init), d?.respRateBpm,
                d?.recovery, d?.strain, d?.rest, d?.sleepTotalMin, d?.sleepInBedMin,
                d?.sleepAwakeMin, d?.sleepLightMin, d?.sleepDeepMin, d?.sleepRemMin,
                d?.sleepEfficiency, d?.spo2Pct,
                d?.skinTempC, d?.skinTempDevC].contains { $0 != nil } || !cache.nights.isEmpty
            let readFailed = enrollmentReadFailures.contains(day)
            let phase: ServerScoreDayState.Phase = failed || readFailed ? .failed : pending ? .pending : hasValues ? .partial : .noData
            readStates[day] = .init(snapshot: nil, phase: phase, fetchedAt: cache.fetchedAt,
                cached: cache.stale || readFailed, pending: pending, requestedInputRevision: nil, archiveStatus: nil)
        }
        for day in enrollmentReadFailures where readStates[day] == nil { readStates[day] = .empty(.failed) }
        var next = ServerScoreViewState(generation: CloudRuntimeIdentity.snapshot().generation,
            revision: state.revision &+ 1, currentDay: currentDay, timezone: timeZone.identifier,
            configured: legacy?.ready() == true || ownership?.metrics.isEmpty == false, authenticated: true, capabilities: metrics,
            activated: metrics, days: readStates)
        for (day, cache) in enrolledDays where cache.ownerId == owner {
            if let canonical = cache.canonicalResults { next.canonicalDays[day] = canonical }
            if let pending = cache.pendingCanonicalResults { next.pendingCanonicalDays[day] = pending }
            let d = cache.daily
            let authorized = Self.authorizedEnrollmentMetrics(cache).intersection(metrics)
            let entries: [(ServerScoreMetric, Double?)] = [
                (.hrv, d?.hrvRmssdMs), (.restingHR, d?.restingHrBpm.map(Double.init)),
                (.respiration, d?.respRateBpm), (.recovery, d?.recovery), (.strain, d?.strain),
                (.sleepPerformance, d?.rest), (.sleepTotal, d?.sleepTotalMin), (.sleepInBed, d?.sleepInBedMin),
                (.sleepAwake, d?.sleepAwakeMin), (.sleepLight, d?.sleepLightMin), (.sleepDeep, d?.sleepDeepMin),
                (.sleepREM, d?.sleepRemMin), (.sleepEfficiency, d?.sleepEfficiency), (.spo2, d?.spo2Pct),
                (.skinTemperature, d?.skinTempC), (.skinTemperatureDeviation, d?.skinTempDevC)]
            var values: [String: Double] = [:]
            for (metric, value) in entries where authorized.contains(metric) {
                if let value { values[metric.rawValue] = value }
            }
            if !values.isEmpty { next.enrollmentValues[day] = values }
        }
        if next.canonicalDays != state.canonicalDays || next.pendingCanonicalDays != state.pendingCanonicalDays || next.enrollmentValues != state.enrollmentValues || next.currentDay != state.currentDay
            || next.generation != state.generation || next.configured != state.configured
            || next.authenticated != state.authenticated || next.capabilities != state.capabilities
            || next.days != state.days {
            state = next
        }
    }

    private static func authorizedEnrollmentMetrics(_ cache: ServerScoreDayCache) -> Set<ServerScoreMetric> {
        var result = Set<ServerScoreMetric>()
        if cache.features["hrv"]?.isCanonicalAvailable == true {
            result.formUnion([.hrv, .restingHR, .recovery, .strain, .spo2,
                              .skinTemperature, .skinTemperatureDeviation])
        }
        if cache.features["respiration"]?.isCanonicalAvailable == true {
            result.insert(.respiration)
        }
        if cache.features["sleep"]?.isCanonicalAvailable == true {
            result.formUnion([.sleepPerformance, .sleepTotal, .sleepInBed, .sleepAwake,
                              .sleepLight, .sleepDeep, .sleepREM, .sleepEfficiency, .sleepSessions])
        }
        return result
    }

    private func restoreOwnership(owner: String) {
        guard let local = activeDeviceId,
              let device = legacy?.canonicalDeviceId(owner, local),
              let project = legacy?.projectURL() else { return }
        ownership = ownershipStore.load(.init(project: project, ownerID: owner, deviceID: device))
        ServerScoringSettings.bindComputeOwnership(ownership)
    }

    private func observeOwnership(_ cache: ServerScoreDayCache) {
        guard cache.ownerId == currentOwnerId, activeDeviceId != nil,
              let project = legacy?.projectURL() else { return }
        let devices = cache.canonicalResults.map { Set([$0.deviceID]) } ?? Set(cache.features.values.compactMap(\.deviceId))
        guard devices.count == 1, let device = devices.first else { return }
        let scope = ServerMetricOwnership.Scope(project: project, ownerID: cache.ownerId, deviceID: device)
        ownership = ownershipStore.observe(cache, scope: scope)
        ServerScoringSettings.bindComputeOwnership(ownership)
    }

    private func restoreDeviceLink() {
        if let dependencies = legacy {
            deviceLinked = Self.hasConfirmedDeviceLink(
                ownerId: currentOwnerId == session.ownerId ? currentOwnerId : nil,
                localDeviceId: activeDeviceId,
                canonicalDeviceId: dependencies.canonicalDeviceId)
            return
        }
        deviceLinked = Self.hasConfirmedDeviceLink(
            ownerId: CloudEnrollment.currentCredential()?.userId.lowercased(),
            localDeviceId: activeDeviceId,
            canonicalDeviceId: { ServerScoreClient.canonicalDeviceId(ownerId: $0, localDeviceId: $1) })
    }

    /// A positive value is a server-issued canonical id, not merely an active BLE peripheral.
    static func hasConfirmedDeviceLink(ownerId: String?, localDeviceId: String?,
                                       canonicalDeviceId: (String, String) -> String?) -> Bool {
        guard let ownerId, let localDeviceId,
              !ownerId.isEmpty, !localDeviceId.isEmpty else { return false }
        return canonicalDeviceId(ownerId, localDeviceId) != nil
    }

    private func confirmSelectedDeviceLink() async {
        guard legacy == nil else { return }
        restoreDeviceLink()
        guard !deviceLinked,
              let owner = CloudEnrollment.currentCredential()?.userId.lowercased(),
              let local = activeDeviceId else { return }
        do {
            _ = try await ServerScoreClient.confirmDeviceLink(localDeviceId: local, expectedOwnerId: owner)
            guard !retired, activeDeviceId == local,
                  CloudEnrollment.currentCredential()?.userId.lowercased() == owner else { return }
            restoreDeviceLink()
            if deviceLinked { lastError = nil }
        } catch {
            guard !retired, activeDeviceId == local,
                  CloudEnrollment.currentCredential()?.userId.lowercased() == owner else { return }
            lastError = "Could not confirm this strap with the server. Check your connection and try again."
        }
    }

    private func cachedDay(ownerId: String, day: String) -> ServerScoreDayCache? {
        guard cacheProjectURL == legacy?.projectURL(),
              let local = activeDeviceId, let canonical = legacy?.canonicalDeviceId(ownerId, local),
              let row = try? cacheStore?.load(ownerId: ownerId, day: day, deviceId: canonical) else { return nil }
        if let results = row.canonicalResults {
            guard let context = CloudRuntimeIdentity.snapshot().context,
                  (try? results.validate(owner: ownerId, day: day, project: legacy?.projectURL(),
                    source: CloudPushSettings.sourceId(scope: context.scope), device: canonical)) != nil else { return nil }
        }
        return row
    }

    private func synchronizeOwner() {
        guard legacy != nil,
              session.ownerId != currentOwnerId || enrollmentReadIdentity != currentEnrollmentReadIdentity else { return }
        enrollmentReadIdentity = currentEnrollmentReadIdentity
        stopPolling()
        enrolledDays.removeAll()
        enrollmentReadFailures.removeAll()
        ownership = nil
        ServerScoringSettings.bindComputeOwnership(nil)
        state = .empty
        session.activate(ownerId: nil)
        session.activate(ownerId: currentOwnerId)
        signedIn = currentOwnerId != nil
        deviceLinked = false
        lastFetchedAt = nil
        lastError = nil
        sleepEditMessage = nil
        preloadFromDisk()
    }
}
