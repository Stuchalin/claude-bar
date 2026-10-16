@testable import ClaudeBarCore
import Foundation
import Observation
import Testing

private typealias F = RefreshFixtures

@MainActor
@Suite("RefreshCoordinator", .timeLimit(.minutes(1)))
struct RefreshCoordinatorTests {
    // MARK: - Schedule and triggers

    @Test("auto mode fetches at launch once, then on the interval")
    func launchAndTimer() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        #expect(h.coordinator.trigger(.launch) == .fetch)

        await h.fetcher.waitForCalls(1)
        #expect(h.status.connection == .loading)
        #expect(h.status.phase == .firstLoad)
        let deadline = await h.complete(call: 1, with: .success(F.snapshot()))
        #expect(deadline == h.at(300))
        #expect(h.fetcher.callCount == 1)
        #expect(h.status.connection == .succeeded)
        #expect(h.status.lastAttemptAt == h.at(0))
        #expect(h.status.nextAttemptAt == h.at(300))

        h.advance(to: 300)
        await h.fetcher.waitForCalls(2)
        #expect(await h.complete(call: 2, with: .success(F.snapshot())) == h.at(600))
    }

    @Test("menu opens during a request add nothing; manual triggers collapse into one follow-up")
    func coalescing() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        await h.fetcher.waitForCalls(1)
        for _ in 0 ..< 5 { #expect(h.coordinator.trigger(.menuOpen) == .ignore(.inFlight)) }
        #expect(h.coordinator.trigger(.wake) == .ignore(.inFlight))
        await h.complete(call: 1, with: .success(F.snapshot()))
        #expect(h.fetcher.callCount == 1)

        h.coordinator.trigger(.manualRefresh)
        await h.fetcher.waitForCalls(2)
        #expect(h.coordinator.trigger(.manualRefresh) == .followUp)
        #expect(h.coordinator.trigger(.checkConnection) == .followUp)
        #expect(h.coordinator.trigger(.manualRefresh) == .followUp)
        #expect(h.coordinator.trigger(.menuOpen) == .ignore(.inFlight))
        h.fetcher.resolveNext(.success(F.snapshot()))
        await h.fetcher.waitForCalls(3)
        for _ in 0 ..< 3 { #expect(h.coordinator.trigger(.menuOpen) == .ignore(.inFlight)) }
        await h.complete(call: 3, with: .success(F.snapshot()))
        #expect(h.fetcher.callCount == 3)
    }

    @Test("menu open is throttled to 30 s after the last attempt")
    func menuThrottle() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        await h.complete(call: 1, with: .success(F.snapshot()))
        h.advance(to: 29)
        #expect(h.coordinator.trigger(.menuOpen) == .ignore(.throttled))
        h.advance(to: 30)
        #expect(h.coordinator.trigger(.menuOpen) == .fetch)
        await h.complete(call: 2, with: .success(F.snapshot()))
        #expect(h.fetcher.callCount == 2)
    }

    @Test("wake fetches in auto mode")
    func wake() async {
        let h = RefreshHarness(interval: .thirtyMinutes)
        defer { h.stop() }
        await h.complete(call: 1, with: .success(F.snapshot()))
        h.advance(to: 5)
        #expect(h.coordinator.trigger(.wake) == .fetch)
        await h.complete(call: 2, with: .success(F.snapshot()))
        #expect(h.fetcher.callCount == 2)
    }

    @Test("an interval change re-arms the timer from the last attempt")
    func intervalChange() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        #expect(await h.complete(call: 1, with: .success(F.snapshot())) == h.at(300))
        h.advance(to: 10)
        h.coordinator.configure(endpoint: F.endpointA, secretRevision: 0, interval: .oneMinute)
        #expect(await h.clock.waitForSleeper() == h.at(60))
        #expect(h.status.nextAttemptAt == h.at(60))

        h.coordinator.configure(endpoint: F.endpointA, secretRevision: 0, interval: .manual)
        #expect(await h.clock.waitForSleeper() == h.at(600)) // only the manual stale age remains
        #expect(h.status.nextAttemptAt == nil)
        h.coordinator.configure(endpoint: F.endpointA, secretRevision: 0, interval: .fiveMinutes)
        #expect(await h.clock.waitForSleeper() == h.at(300))
        #expect(h.fetcher.callCount == 1)
    }

    @Test("nothing fetches until an endpoint is configured")
    func unconfigured() async {
        let h = RefreshHarness(interval: .fiveMinutes, endpoint: nil)
        defer { h.stop() }
        #expect(await h.clock.waitForSleeper() == .distantFuture)
        #expect(h.coordinator.trigger(.manualRefresh) == .ignore(.notConfigured))
        #expect(!h.status.isConfigured)
        h.coordinator.configure(endpoint: F.endpointA, secretRevision: 0, interval: .fiveMinutes)
        await h.complete(call: 1, with: .success(F.snapshot()))
        #expect(h.fetcher.endpoints == [F.endpointA])
    }

    // MARK: - Manual mode

    @Test("manual mode: no timer, launch, menu or wake fetch; failures schedule nothing")
    func manualMode() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        #expect(await h.clock.waitForSleeper() == .distantFuture)
        for trigger in [RefreshTrigger.launch, .menuOpen, .wake, .timer] {
            #expect(h.coordinator.trigger(trigger) == .ignore(.manualMode))
        }
        h.advance(to: 3600)
        #expect(h.fetcher.callCount == 0)

        #expect(h.coordinator.trigger(.manualRefresh) == .fetch)
        #expect(await h.complete(call: 1, with: .failure(.timeout)) == .distantFuture)
        #expect(h.status.nextAttemptAt == nil)
        #expect(h.status.retryAvailableAt == nil)
        #expect(h.fetcher.callCount == 1)

        #expect(h.coordinator.trigger(.checkConnection) == .fetch)
        await h.complete(call: 2, with: .success(F.snapshot()))
        #expect(h.fetcher.callCount == 2)
    }

    @Test("manual mode: a cooldown shows 'retry available at' and blocks Refresh until it ends")
    func manualCooldown() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        h.coordinator.trigger(.manualRefresh)
        let deadline = await h.complete(call: 1, with: .failure(.rateLimited(retryAfter: h.at(90))))
        #expect(deadline == h.at(90))
        #expect(h.status.retryAvailableAt == h.at(90))
        #expect(h.status.nextAttemptAt == nil)
        #expect(RefreshStatusText.timingLine(h.status, time: { _ in "T" }) == "Retry available at T")
        #expect(h.coordinator.trigger(.manualRefresh) == .ignore(.coolingDown))

        h.advance(to: 90)
        #expect(await h.clock.waitForSleeper() == .distantFuture)
        #expect(h.status.retryAvailableAt == nil)
        #expect(h.status.cooldownUntil == nil)
        #expect(RefreshStatusText.timingLine(h.status, time: { _ in "T" }) == nil)
        #expect(h.fetcher.callCount == 1)
        #expect(h.coordinator.trigger(.manualRefresh) == .fetch)
        await h.complete(call: 2, with: .success(F.snapshot()))
    }

    @Test("manual mode: a config change advances the generation without fetching")
    func manualConfigChange() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 1, with: .success(F.snapshot()))
        let generation = h.coordinator.generation

        h.coordinator.configure(endpoint: F.endpointB, secretRevision: 0, interval: .manual)
        #expect(h.coordinator.generation == generation + 1)
        #expect(h.status.snapshot == nil)
        #expect(h.status.session == .unavailable)
        h.coordinator.configure(endpoint: F.endpointB, secretRevision: 1, interval: .manual)
        #expect(h.coordinator.generation == generation + 2)
        await h.clock.waitForSleeper()
        #expect(h.fetcher.callCount == 1)
    }

    // MARK: - Cooldown and backoff

    @Test("a 429 cooldown blocks every trigger, manual included, until Retry-After")
    func cooldownBlocksEverything() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        let deadline = await h.complete(call: 1, with: .failure(.rateLimited(retryAfter: h.at(120))))
        #expect(deadline == h.at(120))
        #expect(h.status.cooldownUntil == h.at(120))
        #expect(h.status.nextAttemptAt == h.at(300))
        #expect(h.status.connection == .failed(.rateLimited(retryAfter: h.at(120))))
        let triggers: [RefreshTrigger] = [.manualRefresh, .checkConnection, .menuOpen, .wake, .launch, .timer]
        for trigger in triggers {
            #expect(h.coordinator.trigger(trigger) == .ignore(.coolingDown))
        }
        h.coordinator.configure(endpoint: F.endpointA, secretRevision: 1, interval: .fiveMinutes)
        #expect(await h.clock.waitForSleeper() == h.at(120))
        #expect(h.fetcher.callCount == 1)

        h.advance(to: 120)
        #expect(await h.clock.waitForSleeper() == h.at(300))
        #expect(h.status.cooldownUntil == nil)
        #expect(h.fetcher.callCount == 1)
        #expect(h.coordinator.trigger(.manualRefresh) == .fetch)
        await h.complete(call: 2, with: .success(F.snapshot()))
    }

    @Test("repeated 429 with Retry-After 0 or a past date waits 5 minutes each time, no loop")
    func repeatedRateLimit() async {
        let h = RefreshHarness(interval: .oneMinute)
        defer { h.stop() }
        let first = await h.complete(call: 1, with: .failure(.rateLimited(retryAfter: h.at(0))))
        #expect(first == h.at(300))
        #expect(h.status.cooldownUntil == h.at(300))
        #expect(h.fetcher.callCount == 1)

        h.advance(to: 300)
        let second = await h.complete(call: 2, with: .failure(.rateLimited(retryAfter: h.at(-60))))
        #expect(second == h.at(600))
        #expect(h.status.cooldownUntil == h.at(600))
        #expect(h.fetcher.callCount == 2)
    }

    @Test("transient failures back off 30, 60, 120, 240 s capped at the interval, reset on success")
    func backoff() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        let failures: [UsageFetchError] = [
            .timeout, .network(.notConnectedToInternet), .serverError(status: 503), .upstreamUnreachable, .timeout,
        ]
        let expected: [TimeInterval] = [30, 90, 210, 450, 750]
        for (index, error) in failures.enumerated() {
            let deadline = await h.complete(call: index + 1, with: .failure(error))
            #expect(deadline == h.at(expected[index]))
            #expect(h.status.nextAttemptAt == h.at(expected[index]))
            h.advance(to: expected[index])
        }
        #expect(await h.complete(call: 6, with: .success(F.snapshot())) == h.at(1050))
        h.advance(to: 1050)
        #expect(await h.complete(call: 7, with: .failure(.timeout)) == h.at(1080))
        h.advance(to: 1080)
        #expect(await h.complete(call: 8, with: .failure(.proxySecretRejected)) == h.at(1380))
        #expect(h.fetcher.callCount == 8)
    }

    // MARK: - Generations and source switch

    @Test("slow A, then URL B and three Refresh: A is discarded and one follow-up goes to B")
    func urlSwitchDuringFlight() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        await h.complete(call: 1, with: .success(F.snapshot(session: F.window(used: 10))))
        h.coordinator.trigger(.manualRefresh)
        await h.fetcher.waitForCalls(2)

        h.coordinator.configure(endpoint: F.endpointB, secretRevision: 0, interval: .fiveMinutes)
        #expect(h.status.snapshot == nil)
        #expect(h.status.session == .unavailable)
        #expect(h.status.phase == .firstLoad)
        for _ in 0 ..< 3 { #expect(h.coordinator.trigger(.manualRefresh) == .followUp) }

        h.fetcher.resolveNext(.success(F.snapshot(session: F.window(used: 50))))
        await h.fetcher.waitForCalls(3)
        #expect(h.status.snapshot == nil)
        #expect(h.status.session == .unavailable)
        #expect(h.fetcher.endpoints == [F.endpointA, F.endpointA, F.endpointB])

        await h.complete(call: 3, with: .success(F.snapshot(session: F.window(used: 70))))
        #expect(h.fetcher.callCount == 3)
        #expect(h.status.session.presentation == .fresh(.window(F.window(used: 70))))
    }

    @Test("a late failure from the old URL is discarded too")
    func lateFailureAfterURLChange() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        h.coordinator.trigger(.manualRefresh)
        await h.fetcher.waitForCalls(1)
        h.coordinator.configure(endpoint: F.endpointB, secretRevision: 0, interval: .manual)
        await h.resolve(.failure(.rateLimited(retryAfter: nil)))
        #expect(h.status.connection == .idle)
        #expect(h.status.cooldownUntil == nil)
        #expect(h.status.phase == .firstLoad)
    }

    @Test("a secret change keeps displayed values, discards the late response and fetches again")
    func secretChangeDuringFlight() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        let first = F.snapshot(session: F.window(used: 10))
        await h.complete(call: 1, with: .success(first))
        h.coordinator.trigger(.manualRefresh)
        await h.fetcher.waitForCalls(2)

        h.coordinator.configure(endpoint: F.endpointA, secretRevision: 1, interval: .fiveMinutes)
        #expect(h.status.snapshot == first)
        #expect(h.status.session.presentation == .fresh(.window(F.window(used: 10))))

        h.fetcher.resolveNext(.success(F.snapshot(session: F.window(used: 50))))
        await h.fetcher.waitForCalls(3)
        #expect(h.status.snapshot == first)
        await h.complete(call: 3, with: .success(F.snapshot(session: F.window(used: 70))))
        #expect(h.status.session.presentation == .fresh(.window(F.window(used: 70))))
        #expect(h.fetcher.endpoints == [F.endpointA, F.endpointA, F.endpointA])
    }

    @Test("a secret change while idle fetches in auto mode and keeps values meanwhile")
    func secretChangeIdle() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        let first = F.snapshot()
        await h.complete(call: 1, with: .success(first))
        h.coordinator.configure(endpoint: F.endpointA, secretRevision: 1, interval: .fiveMinutes)
        #expect(h.status.snapshot == first)
        #expect(h.status.lastSuccessAt == h.at(0))
        await h.complete(call: 2, with: .failure(.proxySecretRejected))
        #expect(h.status.phase == .failureWithCache)
    }

    // MARK: - Phases and presentation

    @Test("phases: first load, first failure, fresh, failure with cache")
    func phases() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        #expect(h.status.phase == .firstLoad)
        #expect(h.status.connection == .idle)

        h.coordinator.trigger(.manualRefresh)
        await h.fetcher.waitForCalls(1)
        #expect(h.status.connection == .loading)
        #expect(h.status.phase == .firstLoad)
        await h.complete(call: 1, with: .failure(.timeout))
        #expect(h.status.phase == .firstFailure)
        #expect(h.status.connection == .failed(.timeout))
        #expect(!h.status.isStale)
        #expect(h.status.session == .unavailable)

        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 2, with: .success(F.snapshot()))
        #expect(h.status.phase == .fresh)
        #expect(!h.status.isStale)
        #expect(h.status.lastSuccessAt == h.at(0))

        h.advance(to: 60)
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 3, with: .failure(.forbidden))
        #expect(h.status.phase == .failureWithCache)
        #expect(h.status.isStale)
        #expect(h.status.session.presentation == .stale(.window(F.window(used: 12)), lastSeenAt: h.at(0)))
        #expect(RefreshStatusText.errorLine(h.status) == UsageFetchError.forbidden.hint)
    }

    @Test("stale by age is published when the clock passes the stale age, without a fetch")
    func staleByAge() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        h.coordinator.trigger(.manualRefresh)
        #expect(await h.complete(call: 1, with: .success(F.snapshot())) == h.at(600))
        #expect(!h.status.isStale)
        #expect(h.status.session.presentation == .fresh(.window(F.window(used: 12))))

        let changed = ChangeFlag()
        withObservationTracking { _ = h.coordinator.status } onChange: { changed.raise() }
        h.advance(to: 599)
        #expect(!changed.isRaised)
        h.advance(to: 600)
        await h.clock.waitForSleeper()
        #expect(changed.isRaised)
        #expect(h.status.isStale)
        #expect(h.status.phase == .fresh)
        #expect(h.status.session.presentation == .stale(.window(F.window(used: 12)), lastSeenAt: h.at(0)))
        #expect(!h.status.session.allowsForecast)
        #expect(h.fetcher.callCount == 1)
    }

    @Test("a cached window passing its reset shows waiting for fresh data and no forecast")
    func waitingForFreshData() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        let session = F.window(used: 40, reset: .at(h.at(60)))
        let weekly = F.window(used: 5, duration: UsageWindow.weeklyDuration)
        h.coordinator.trigger(.manualRefresh)
        #expect(await h.complete(call: 1, with: .success(F.snapshot(session: session, weekly: weekly))) == h.at(60))
        #expect(h.status.session == MetricState(presentation: .fresh(.window(session)), allowsForecast: true))

        let changed = ChangeFlag()
        withObservationTracking { _ = h.coordinator.status } onChange: { changed.raise() }
        h.advance(to: 60)
        #expect(await h.clock.waitForSleeper() == h.at(600))
        #expect(changed.isRaised)
        #expect(h.status.session == MetricState(presentation: .waitingForFreshData(lastSeenAt: h.at(0)), allowsForecast: false))
        #expect(h.status.weekly == MetricState(presentation: .fresh(.window(weekly)), allowsForecast: true))
        #expect(RefreshStatusText.statusTitle(h.status) == "S — · W 95%")
        #expect(h.fetcher.callCount == 1)
    }

    @Test("availability is per metric: a missing metric shows its prior value as stale, never fresh")
    func perMetricAvailability() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        let session = F.window(used: 20)
        let extra = ExtraUsageState.enabled(ExtraUsage(used: 1, cap: .amount(10), currency: "USD", utilization: 10))
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 1, with: .success(F.snapshot(
            session: session,
            scoped: [F.scoped("a", used: 3), F.scoped("b", used: 4)],
            extra: extra
        )))
        #expect(h.status.scoped.map(\.key) == ["a", "b"])

        h.advance(to: 10)
        let weekly = F.window(used: 7, duration: UsageWindow.weeklyDuration)
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 2, with: .success(F.snapshot(
            session: nil,
            weekly: weekly,
            scoped: [F.scoped("b", used: 6), F.scoped("c", used: nil)],
            extra: .unavailable
        )))

        #expect(h.status.session == MetricState(presentation: .stale(.window(session), lastSeenAt: h.at(0)), allowsForecast: false))
        #expect(h.status.weekly == MetricState(presentation: .fresh(.window(weekly)), allowsForecast: true))
        #expect(h.status.extra.presentation == .stale(.extra(extra), lastSeenAt: h.at(0)))
        let scoped = h.status.scoped
        #expect(scoped.map(\.key) == ["b", "c", "a"])
        #expect(scoped[0].state.presentation == .fresh(.window(F.scoped("b", used: 6).window!)))
        #expect(scoped[1].state == .unavailable)
        #expect(scoped[2].state.presentation == .stale(.window(F.scoped("a", used: 3).window!), lastSeenAt: h.at(0)))
        #expect(scoped[2].displayName == "A")
        #expect(RefreshStatusText.statusTitle(h.status) == "S 80%* · W 93%")

        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 3, with: .success(F.snapshot(
            scoped: [F.scoped("b", used: nil, ambiguous: true), F.scoped("b", used: nil, ambiguous: true)]
        )))
        #expect(h.status.scoped.map(\.key) == ["b", "b", "a"])
        #expect(h.status.scoped.prefix(2).allSatisfy { $0.isAmbiguous && $0.state == .unavailable })
    }

    @Test("windows without a known future reset are fresh but allow no forecast")
    func forecastNeedsFutureReset() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 1, with: .success(F.snapshot(
            session: F.window(used: 0, reset: .notStarted),
            weekly: F.window(used: 3, reset: .unknown, duration: UsageWindow.weeklyDuration)
        )))
        #expect(h.status.session.presentation == .fresh(.window(F.window(used: 0, reset: .notStarted))))
        #expect(!h.status.session.allowsForecast)
        #expect(!h.status.weekly.allowsForecast)
        #expect(!h.status.extra.allowsForecast)
    }

    @Test("a reset passing while a request hangs is published before it completes, with no second fetch")
    func resetDuringFlight() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        let session = F.window(used: 40, reset: .at(h.at(60)))
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 1, with: .success(F.snapshot(session: session)))
        h.advance(to: 59)
        h.coordinator.trigger(.manualRefresh)
        await h.fetcher.waitForCalls(2)
        #expect(await h.clock.waitForSleeper() == h.at(60))
        #expect(h.status.session == MetricState(presentation: .fresh(.window(session)), allowsForecast: true))

        let mark = h.clock.parkCount
        h.advance(to: 60)
        await h.clock.waitForSleeper(after: mark)
        #expect(h.status.connection == .loading)
        #expect(h.status.session == MetricState(presentation: .waitingForFreshData(lastSeenAt: h.at(0)), allowsForecast: false))
        h.advance(to: 80)
        #expect(h.fetcher.callCount == 2)

        let fresh = F.window(used: 1, reset: .at(h.at(80 + 18000)))
        await h.resolve(.success(F.snapshot(session: fresh)))
        #expect(h.status.session == MetricState(presentation: .fresh(.window(fresh)), allowsForecast: true))
        #expect(h.fetcher.callCount == 2)
    }

    @Test("the stale age passing while a request hangs is published before it completes, with no second fetch")
    func staleDuringFlight() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 1, with: .success(F.snapshot()))
        h.advance(to: 599)
        h.coordinator.trigger(.manualRefresh)
        await h.fetcher.waitForCalls(2)
        #expect(await h.clock.waitForSleeper() == h.at(600))
        #expect(!h.status.isStale)

        let mark = h.clock.parkCount
        h.advance(to: 600)
        await h.clock.waitForSleeper(after: mark)
        #expect(h.status.isStale)
        #expect(h.status.connection == .loading)
        #expect(h.status.session.presentation == .stale(.window(F.window(used: 12)), lastSeenAt: h.at(0)))
        #expect(h.fetcher.callCount == 2)

        await h.resolve(.success(F.snapshot()))
        #expect(!h.status.isStale)
        #expect(h.fetcher.callCount == 2)
    }

    @Test("auto mode schedules nothing while a request hangs; an overdue timer fires once afterwards")
    func noTimerDuringFlight() async {
        let h = RefreshHarness(interval: .oneMinute)
        defer { h.stop() }
        await h.fetcher.waitForCalls(1)
        #expect(await h.clock.waitForSleeper() == .distantFuture)
        #expect(h.status.nextAttemptAt == nil)
        h.advance(to: 600)
        #expect(h.fetcher.callCount == 1)
        // The attempt started at t0, so the t+60 deadline is overdue: exactly one timer fetch follows.
        await h.resolve(.success(F.snapshot()))
        await h.fetcher.waitForCalls(2)
        #expect(h.status.lastAttemptAt == h.at(600))
        #expect(await h.resolve(.success(F.snapshot())) == h.at(660))
        #expect(h.fetcher.callCount == 2)
    }

    // MARK: - Settings bridge

    private func boundSettings(_ h: RefreshHarness, interval: RefreshInterval) -> (SettingsModel, IsolatedDefaults) {
        let isolated = IsolatedDefaults()
        let store = SettingsStore(defaults: isolated.defaults)
        store.proxyURL = F.endpointA.normalizedString
        store.refreshInterval = interval
        let model = SettingsModel(settings: store, secrets: InMemorySecretStore(secret: Fixture.dummy))
        h.coordinator.bind(to: model)
        model.loadDraft()
        return (model, isolated)
    }

    @Test("Save of a new URL reaches the coordinator synchronously: old values hidden, late success of A discarded")
    func saveURLDuringFlight() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        let (model, isolated) = boundSettings(h, interval: .fiveMinutes)
        defer { withExtendedLifetime(isolated) {} }
        await h.complete(call: 1, with: .success(F.snapshot(session: F.window(used: 10))))
        h.coordinator.trigger(.manualRefresh)
        await h.fetcher.waitForCalls(2)
        let generation = h.coordinator.generation

        model.draftURL = F.endpointB.normalizedString
        #expect(model.save())
        #expect(h.coordinator.generation == generation + 1)
        #expect(h.status.snapshot == nil)
        #expect(h.status.session == .unavailable)

        h.fetcher.resolveNext(.success(F.snapshot(session: F.window(used: 50))))
        await h.fetcher.waitForCalls(3)
        #expect(h.status.snapshot == nil)
        #expect(h.fetcher.endpoints == [F.endpointA, F.endpointA, F.endpointB])
        await h.complete(call: 3, with: .success(F.snapshot(session: F.window(used: 70))))
        #expect(h.status.session.presentation == .fresh(.window(F.window(used: 70))))
    }

    @Test("Save of a new URL or secret discards a late error of the old configuration", arguments: [true, false])
    func saveDiscardsLateError(urlChange: Bool) async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        let (model, isolated) = boundSettings(h, interval: .fiveMinutes)
        defer { withExtendedLifetime(isolated) {} }
        await h.complete(call: 1, with: .success(F.snapshot()))
        model.refreshInterval = .manual
        #expect(h.status.interval == .manual)

        h.coordinator.trigger(.manualRefresh)
        await h.fetcher.waitForCalls(2)
        let generation = h.coordinator.generation
        if urlChange {
            model.draftURL = F.endpointB.normalizedString
        } else {
            model.draftSecret = Fixture.other
        }
        #expect(model.save())
        #expect(h.coordinator.generation == generation + 1)
        #expect((h.status.snapshot == nil) == urlChange)

        await h.resolve(.failure(.rateLimited(retryAfter: nil)))
        #expect(h.status.cooldownUntil == nil)
        #expect(h.status.connection == (urlChange ? .idle : .succeeded))
        #expect(h.status.phase == (urlChange ? .firstLoad : .fresh))
        #expect(h.fetcher.callCount == 2)
    }

    @Test("an interval change in Settings re-arms the coordinator synchronously")
    func intervalHandoff() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        defer { h.stop() }
        let (model, isolated) = boundSettings(h, interval: .fiveMinutes)
        defer { withExtendedLifetime(isolated) {} }
        #expect(await h.complete(call: 1, with: .success(F.snapshot())) == h.at(300))
        model.refreshInterval = .oneMinute
        #expect(h.status.interval == .oneMinute)
        #expect(h.status.nextAttemptAt == h.at(60))
        #expect(await h.clock.waitForSleeper() == h.at(60))
    }

    @Test("stopping cancels the in-flight request without applying it")
    func stopCancels() async {
        let h = RefreshHarness(interval: .fiveMinutes)
        await h.fetcher.waitForCalls(1)
        h.stop()
        #expect(h.status.connection == .loading || h.status.connection == .idle)
        #expect(h.status.phase == .firstLoad)
    }
}
