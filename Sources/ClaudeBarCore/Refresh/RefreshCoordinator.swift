import Foundation
import Observation

/// Owns fetching per the refresh contract and publishes connection state and per-metric
/// availability separately from the last successful snapshot.
///
/// Triggers and configuration are applied synchronously on the main actor, even while a request
/// is in flight. A single driver task starts fetches (at most one in flight, each in its own task)
/// and sleeps until the next scheduled attempt or presentation change, also while a request is
/// pending; it is woken by cancelling its sleep, including when a fetch completes.
@MainActor
@Observable
public final class RefreshCoordinator {
    public private(set) var status = RefreshStatus()

    private enum Outcome: Equatable {
        case none
        case succeeded
        case failed(UsageFetchError)

        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    private struct LastKnown: Equatable {
        let value: MetricValue
        let observedAt: Date
        let displayName: String?
    }

    @ObservationIgnored private let fetcher: any UsageFetching
    @ObservationIgnored private let clock: any RefreshClock
    @ObservationIgnored private let history: any HistoryRecording

    @ObservationIgnored private var endpoint: ProxyEndpoint?
    @ObservationIgnored private var secretRevision: Int
    @ObservationIgnored private var interval: RefreshInterval
    /// Bumped on every URL or secret change; results of older generations are discarded.
    @ObservationIgnored private(set) var generation = 0

    @ObservationIgnored private var isInFlight = false
    @ObservationIgnored private var fetchRequested = false
    @ObservationIgnored private var followUp: RefreshTrigger?
    @ObservationIgnored private var lastAttemptAt: Date?
    @ObservationIgnored private var lastSuccessAt: Date?
    @ObservationIgnored private var outcome = Outcome.none
    @ObservationIgnored private var cooldownUntil: Date?
    @ObservationIgnored private var transientFailures = 0
    @ObservationIgnored private var snapshot: UsageSnapshot?
    @ObservationIgnored private var lastKnown: [MetricID: LastKnown] = [:]
    @ObservationIgnored private var scopedKeysSeen: [String] = []

    @ObservationIgnored private var driver: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?

    public init(
        fetcher: any UsageFetching,
        clock: any RefreshClock = SystemRefreshClock(),
        history: any HistoryRecording = NoHistoryRecording(),
        endpoint: ProxyEndpoint?,
        secretRevision: Int,
        interval: RefreshInterval
    ) {
        self.fetcher = fetcher
        self.clock = clock
        self.history = history
        self.endpoint = endpoint
        self.secretRevision = secretRevision
        self.interval = interval
        republish()
    }

    // MARK: - Lifecycle

    /// Starts the driver. In auto modes with an endpoint the first fetch happens at once.
    public func start() {
        guard driver == nil else { return }
        driver = Task { [weak self] in await self?.runDriver() }
    }

    /// Stops the driver and cancels an in-flight request (its result is not applied).
    public func stop() {
        driver?.cancel()
        driver = nil
        fetchTask?.cancel()
        sleeper?.cancel()
    }

    /// Applies `settings.configuration` now and every later commit synchronously, from inside the
    /// commit, so an old-config result can never be accepted after a successful Save.
    public func bind(to settings: SettingsModel) {
        configure(settings.configuration)
        settings.onCommit = { [weak self] configuration in
            self?.configure(configuration)
        }
    }

    public func configure(_ configuration: RefreshConfiguration) {
        configure(
            endpoint: configuration.endpoint,
            secretRevision: configuration.secretRevision,
            interval: configuration.interval
        )
    }

    // MARK: - Intake

    /// Applies the policy to `trigger` immediately.
    @discardableResult
    public func trigger(_ trigger: RefreshTrigger) -> RefreshDecision {
        let decision = RefreshPolicy.decide(trigger: trigger, state: policyState, now: clock.now)
        switch decision {
        case .fetch:
            fetchRequested = true
            wakeDriver()
        case .followUp:
            followUp = Self.stronger(followUp, trigger)
        case .ignore:
            break
        }
        return decision
    }

    /// Applies committed settings. A URL or secret change advances the generation; a URL change
    /// also hides the old source's values at once; in auto modes either change fetches.
    /// An interval change re-arms the schedule from the last attempt.
    /// A URL change away from a configured source is reported to history.
    public func configure(endpoint: ProxyEndpoint?, secretRevision: Int, interval: RefreshInterval) {
        let urlChanged = endpoint != self.endpoint
        let secretChanged = secretRevision != self.secretRevision
        guard urlChanged || secretChanged || interval != self.interval else { return }
        if urlChanged, let oldEndpoint = self.endpoint {
            history.record(.sourceChanged(oldSource: oldEndpoint.normalizedString, at: clock.now))
        }
        self.endpoint = endpoint
        self.secretRevision = secretRevision
        self.interval = interval

        if urlChanged || secretChanged {
            generation += 1
            transientFailures = 0
            if urlChanged { clearSource() }
            trigger(.configChanged(urlChanged: urlChanged))
        }
        republish()
        wakeDriver()
    }

    // MARK: - Driver

    private func runDriver() async {
        while !Task.isCancelled {
            if fetchRequested, !isInFlight {
                fetchRequested = false
                startFetch()
                continue
            }
            republish()
            let now = clock.now
            if !isInFlight, let next = scheduledAttempt(), next <= now, trigger(.timer) == .fetch {
                continue
            }
            await park(until: wakeDeadline(now: now))
        }
    }

    /// Starts the single in-flight request in its own task, so the driver keeps serving
    /// presentation deadlines while the network is pending.
    private func startFetch() {
        guard let endpoint else { return }
        let attemptGeneration = generation
        let fetcher = fetcher
        isInFlight = true
        lastAttemptAt = clock.now
        republish()
        fetchTask = Task { [weak self] in
            let result: Result<UsageSnapshot, UsageFetchError>
            do throws(UsageFetchError) {
                result = try await .success(fetcher.fetchUsage(endpoint: endpoint))
            } catch {
                result = .failure(error)
            }
            self?.finishFetch(result, generation: attemptGeneration, endpoint: endpoint, cancelled: Task.isCancelled)
        }
    }

    private func finishFetch(
        _ result: Result<UsageSnapshot, UsageFetchError>,
        generation attemptGeneration: Int,
        endpoint attemptEndpoint: ProxyEndpoint,
        cancelled: Bool
    ) {
        isInFlight = false
        fetchTask = nil
        if attemptGeneration == generation, !cancelled {
            accept(result, source: attemptEndpoint.normalizedString)
        }
        if let pending = followUp {
            followUp = nil
            trigger(pending)
        }
        republish()
        wakeDriver()
    }

    private func park(until deadline: Date?) async {
        let clock = clock
        let target = deadline ?? .distantFuture
        let task = Task<Void, Never> { try? await clock.sleep(until: target) }
        sleeper = task
        await task.value
        if sleeper == task { sleeper = nil }
    }

    private func wakeDriver() {
        sleeper?.cancel()
    }

    // MARK: - Results

    /// Applies a result of the current generation and reports it to history (cancellation aside),
    /// stamped with the acceptance time.
    private func accept(_ result: Result<UsageSnapshot, UsageFetchError>, source: String) {
        let now = clock.now
        switch result {
        case let .success(snapshot):
            self.snapshot = snapshot
            lastSuccessAt = now
            outcome = .succeeded
            transientFailures = 0
            record(snapshot, at: now)
            history.record(.observed(source: source, at: now, interval: interval, snapshot: snapshot))
        case .failure(.cancelled):
            // Not an answer from the proxy: keep the previous outcome, record nothing.
            break
        case let .failure(error):
            outcome = .failed(error)
            history.record(.failed(source: source, at: now))
            if case let .rateLimited(retryAfter) = error {
                cooldownUntil = RefreshPolicy.cooldownEnd(retryAfter: retryAfter, now: now)
                transientFailures = 0
            } else if error.isTransient {
                transientFailures += 1
            } else {
                transientFailures = 0
            }
        }
    }

    private func record(_ snapshot: UsageSnapshot, at now: Date) {
        if let session = snapshot.session {
            lastKnown[.session] = LastKnown(value: .window(session), observedAt: now, displayName: nil)
        }
        if let weekly = snapshot.weekly {
            lastKnown[.weekly] = LastKnown(value: .window(weekly), observedAt: now, displayName: nil)
        }
        for row in snapshot.scopedWeeklies {
            guard let window = row.window else { continue }
            lastKnown[.scoped(key: row.key)] = LastKnown(
                value: .window(window), observedAt: now, displayName: row.displayName
            )
            if !scopedKeysSeen.contains(row.key) { scopedKeysSeen.append(row.key) }
        }
        if snapshot.extraUsage != .unavailable {
            lastKnown[.extra] = LastKnown(value: .extra(snapshot.extraUsage), observedAt: now, displayName: nil)
        }
    }

    private func clearSource() {
        snapshot = nil
        lastSuccessAt = nil
        outcome = .none
        lastKnown = [:]
        scopedKeysSeen = []
    }

    // MARK: - Derived state

    private var policyState: RefreshPolicy.State {
        RefreshPolicy.State(
            interval: interval,
            isConfigured: endpoint != nil,
            isInFlight: isInFlight,
            lastAttemptAt: lastAttemptAt,
            cooldownUntil: cooldownUntil,
            nextAttemptAt: scheduledAttempt()
        )
    }

    private func scheduledAttempt() -> Date? {
        RefreshPolicy.nextAttempt(
            interval: interval,
            isConfigured: endpoint != nil,
            lastAttemptAt: lastAttemptAt,
            transientFailures: transientFailures,
            cooldownUntil: cooldownUntil
        )
    }

    /// Earliest future moment when either a fetch is due or the published state changes by time
    /// alone (stale by age, a cached reset passing, a cooldown ending).
    private func wakeDeadline(now: Date) -> Date? {
        var candidates: [Date] = []
        if !isInFlight, let next = scheduledAttempt(), next > now { candidates.append(next) }
        if let lastSuccessAt, !outcome.isFailure {
            candidates.append(lastSuccessAt.addingTimeInterval(RefreshPolicy.staleAge(for: interval)))
        }
        for known in lastKnown.values {
            if let window = known.value.window, case let .at(reset) = window.reset { candidates.append(reset) }
        }
        if let cooldownUntil { candidates.append(cooldownUntil) }
        return candidates.filter { $0 > now }.min()
    }

    private func republish() {
        let next = makeStatus(now: clock.now)
        if next != status { status = next }
    }

    private func makeStatus(now: Date) -> RefreshStatus {
        var status = RefreshStatus()
        status.isConfigured = endpoint != nil
        status.interval = interval
        status.snapshot = snapshot
        status.lastSuccessAt = lastSuccessAt
        status.lastAttemptAt = lastAttemptAt

        status.connection = switch (isInFlight, outcome) {
        case (true, _): .loading
        case (false, .none): .idle
        case (false, .succeeded): .succeeded
        case let (false, .failed(error)): .failed(error)
        }
        status.phase = switch (lastSuccessAt != nil, outcome.isFailure) {
        case (false, false): .firstLoad
        case (false, true): .firstFailure
        case (true, true): .failureWithCache
        case (true, false): .fresh
        }

        let activeCooldown = cooldownUntil.flatMap { $0 > now ? $0 : nil }
        status.cooldownUntil = activeCooldown
        status.retryAvailableAt = interval.isManual ? activeCooldown : nil
        status.nextAttemptAt = (isInFlight || lastAttemptAt == nil) ? nil : scheduledAttempt()

        let isStale = lastSuccessAt.map {
            outcome.isFailure || now.timeIntervalSince($0) >= RefreshPolicy.staleAge(for: interval)
        } ?? false
        status.isStale = isStale

        status.session = metricState(.session, inLatest: snapshot?.session != nil, stale: isStale, now: now)
        status.weekly = metricState(.weekly, inLatest: snapshot?.weekly != nil, stale: isStale, now: now)
        status.extra = metricState(
            .extra, inLatest: snapshot.map { $0.extraUsage != .unavailable } ?? false, stale: isStale, now: now
        )

        var listed = Set<String>()
        for row in snapshot?.scopedWeeklies ?? [] {
            listed.insert(row.key)
            if row.reading == .ambiguous {
                status.scoped.append(ScopedMetricState(
                    key: row.key, displayName: row.displayName, isAmbiguous: true, state: .unavailable
                ))
                continue
            }
            let known = lastKnown[.scoped(key: row.key)]
            status.scoped.append(ScopedMetricState(
                key: row.key,
                displayName: row.displayName ?? known?.displayName,
                isAmbiguous: false,
                state: metricState(.scoped(key: row.key), inLatest: row.window != nil, stale: isStale, now: now)
            ))
        }
        for key in scopedKeysSeen where !listed.contains(key) {
            status.scoped.append(ScopedMetricState(
                key: key,
                displayName: lastKnown[.scoped(key: key)]?.displayName,
                isAmbiguous: false,
                state: metricState(.scoped(key: key), inLatest: false, stale: isStale, now: now)
            ))
        }
        return status
    }

    /// Judged on the metric's own last-known value: a fresh weekly never makes session fresh.
    private func metricState(_ id: MetricID, inLatest: Bool, stale: Bool, now: Date) -> MetricState {
        guard let known = lastKnown[id] else { return .unavailable }
        if let window = known.value.window, case let .at(reset) = window.reset, reset <= now {
            return MetricState(presentation: .waitingForFreshData(lastSeenAt: known.observedAt), allowsForecast: false)
        }
        guard inLatest, !stale else {
            return MetricState(presentation: .stale(known.value, lastSeenAt: known.observedAt), allowsForecast: false)
        }
        let futureReset = if let window = known.value.window, case .at = window.reset { true } else { false }
        return MetricState(presentation: .fresh(known.value), allowsForecast: futureReset)
    }

    /// Collapsed follow-ups keep the trigger least likely to be refused when re-checked.
    private static func stronger(_ current: RefreshTrigger?, _ new: RefreshTrigger) -> RefreshTrigger {
        func rank(_ trigger: RefreshTrigger?) -> Int {
            switch trigger {
            case .manualRefresh, .checkConnection: 2
            case .some: 1
            case nil: 0
            }
        }
        return rank(new) > rank(current) ? new : current ?? new
    }
}
