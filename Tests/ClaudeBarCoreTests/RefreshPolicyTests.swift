@testable import ClaudeBarCore
import Foundation
import Testing

@Suite("RefreshPolicy")
struct RefreshPolicyTests {
    static let now = RefreshFixtures.t0

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let trigger: RefreshTrigger
        let state: RefreshPolicy.State
        let expected: RefreshDecision
        var testDescription: String { name }
    }

    static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    static func later(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    static let auto = RefreshPolicy.State(interval: .fiveMinutes, lastAttemptAt: ago(60), nextAttemptAt: later(240))
    static let manual = RefreshPolicy.State(interval: .manual, lastAttemptAt: ago(60))

    static func with(_ base: RefreshPolicy.State, _ change: (inout RefreshPolicy.State) -> Void) -> RefreshPolicy.State {
        var state = base
        change(&state)
        return state
    }

    static let autoCases: [Case] = [
        Case(name: "launch fetches", trigger: .launch, state: auto, expected: .fetch),
        Case(name: "wake fetches", trigger: .wake, state: auto, expected: .fetch),
        Case(name: "manual refresh fetches", trigger: .manualRefresh, state: auto, expected: .fetch),
        Case(name: "check connection fetches", trigger: .checkConnection, state: auto, expected: .fetch),
        Case(name: "URL change fetches", trigger: .configChanged(urlChanged: true), state: auto, expected: .fetch),
        Case(name: "secret change fetches", trigger: .configChanged(urlChanged: false), state: auto, expected: .fetch),
        Case(name: "menu open 60 s after the last attempt fetches", trigger: .menuOpen, state: auto, expected: .fetch),
        Case(name: "menu open exactly 30 s after fetches", trigger: .menuOpen,
             state: with(auto) { $0.lastAttemptAt = ago(30) }, expected: .fetch),
        Case(name: "menu open 29 s after is throttled", trigger: .menuOpen,
             state: with(auto) { $0.lastAttemptAt = ago(29) }, expected: .ignore(.throttled)),
        Case(name: "menu open with no attempt yet fetches", trigger: .menuOpen,
             state: with(auto) { $0.lastAttemptAt = nil }, expected: .fetch),
        Case(name: "timer before the deadline is not due", trigger: .timer, state: auto, expected: .ignore(.notDue)),
        Case(name: "timer at the deadline fetches", trigger: .timer,
             state: with(auto) { $0.nextAttemptAt = now }, expected: .fetch),
    ]

    static let manualCases: [Case] = [
        Case(name: "launch ignored", trigger: .launch, state: manual, expected: .ignore(.manualMode)),
        Case(name: "timer ignored", trigger: .timer,
             state: with(manual) { $0.nextAttemptAt = ago(1) }, expected: .ignore(.manualMode)),
        Case(name: "menu open ignored", trigger: .menuOpen,
             state: with(manual) { $0.lastAttemptAt = nil }, expected: .ignore(.manualMode)),
        Case(name: "wake ignored", trigger: .wake, state: manual, expected: .ignore(.manualMode)),
        Case(name: "config change ignored", trigger: .configChanged(urlChanged: true), state: manual,
             expected: .ignore(.manualMode)),
        Case(name: "manual refresh fetches", trigger: .manualRefresh, state: manual, expected: .fetch),
        Case(name: "check connection fetches", trigger: .checkConnection, state: manual, expected: .fetch),
    ]

    static let inFlightCases: [Case] = [
        Case(name: "timer dropped", trigger: .timer,
             state: with(auto) { $0.isInFlight = true; $0.nextAttemptAt = now }, expected: .ignore(.inFlight)),
        Case(name: "menu open dropped", trigger: .menuOpen,
             state: with(auto) { $0.isInFlight = true; $0.lastAttemptAt = ago(120) }, expected: .ignore(.inFlight)),
        Case(name: "wake dropped", trigger: .wake, state: with(auto) { $0.isInFlight = true }, expected: .ignore(.inFlight)),
        Case(name: "launch dropped", trigger: .launch, state: with(auto) { $0.isInFlight = true }, expected: .ignore(.inFlight)),
        Case(name: "manual refresh follows up", trigger: .manualRefresh,
             state: with(auto) { $0.isInFlight = true }, expected: .followUp),
        Case(name: "check connection follows up", trigger: .checkConnection,
             state: with(manual) { $0.isInFlight = true }, expected: .followUp),
        Case(name: "config change follows up in auto", trigger: .configChanged(urlChanged: true),
             state: with(auto) { $0.isInFlight = true }, expected: .followUp),
        Case(name: "config change ignored in manual", trigger: .configChanged(urlChanged: false),
             state: with(manual) { $0.isInFlight = true }, expected: .ignore(.manualMode)),
    ]

    static let allTriggers: [RefreshTrigger] = [
        .launch, .timer, .menuOpen, .wake, .manualRefresh, .checkConnection,
        .configChanged(urlChanged: true), .configChanged(urlChanged: false),
    ]

    @Test("auto mode", arguments: autoCases)
    func autoMode(_ testCase: Case) {
        #expect(RefreshPolicy.decide(trigger: testCase.trigger, state: testCase.state, now: Self.now) == testCase.expected)
    }

    @Test("manual mode", arguments: manualCases)
    func manualMode(_ testCase: Case) {
        #expect(RefreshPolicy.decide(trigger: testCase.trigger, state: testCase.state, now: Self.now) == testCase.expected)
    }

    @Test("during a request", arguments: inFlightCases)
    func inFlight(_ testCase: Case) {
        #expect(RefreshPolicy.decide(trigger: testCase.trigger, state: testCase.state, now: Self.now) == testCase.expected)
    }

    @Test("an active cooldown blocks every trigger in every mode", arguments: allTriggers, [RefreshInterval.manual, .fiveMinutes])
    func cooldownBlocksAll(trigger: RefreshTrigger, interval: RefreshInterval) {
        let state = RefreshPolicy.State(interval: interval, cooldownUntil: Self.later(1), nextAttemptAt: Self.now)
        #expect(RefreshPolicy.decide(trigger: trigger, state: state, now: Self.now) == .ignore(.coolingDown))
    }

    @Test("a cooldown that ended no longer blocks")
    func cooldownEnded() {
        let state = RefreshPolicy.State(interval: .manual, cooldownUntil: Self.now)
        #expect(RefreshPolicy.decide(trigger: .manualRefresh, state: state, now: Self.now) == .fetch)
    }

    @Test("nothing fetches without an endpoint", arguments: allTriggers)
    func notConfigured(trigger: RefreshTrigger) {
        let state = RefreshPolicy.State(interval: .fiveMinutes, isConfigured: false, nextAttemptAt: Self.now)
        #expect(RefreshPolicy.decide(trigger: trigger, state: state, now: Self.now) == .ignore(.notConfigured))
    }

    @Test("backoff doubles from 30 s and is capped by the interval")
    func backoff() {
        let delays = (1 ... 6).map { RefreshPolicy.backoffDelay(failures: $0, interval: 300) }
        #expect(delays == [30, 60, 120, 240, 300, 300])
        #expect(RefreshPolicy.backoffDelay(failures: 0, interval: 300) == 300)
        #expect(RefreshPolicy.backoffDelay(failures: 3, interval: 60) == 60)
        #expect(RefreshPolicy.backoffDelay(failures: 10_000, interval: 1800) == 1800)
    }

    @Test("cooldown uses a future Retry-After, else 5 minutes")
    func cooldownEnd() {
        #expect(RefreshPolicy.cooldownEnd(retryAfter: Self.later(90), now: Self.now) == Self.later(90))
        #expect(RefreshPolicy.cooldownEnd(retryAfter: Self.now, now: Self.now) == Self.later(300))
        #expect(RefreshPolicy.cooldownEnd(retryAfter: Self.ago(60), now: Self.now) == Self.later(300))
        #expect(RefreshPolicy.cooldownEnd(retryAfter: nil, now: Self.now) == Self.later(300))
    }

    @Test("stale age is twice the interval, or 10 minutes in manual mode")
    func staleAge() {
        #expect(RefreshPolicy.staleAge(for: .oneMinute) == 120)
        #expect(RefreshPolicy.staleAge(for: .fiveMinutes) == 600)
        #expect(RefreshPolicy.staleAge(for: .thirtyMinutes) == 3600)
        #expect(RefreshPolicy.staleAge(for: .manual) == 600)
    }

    @Test("next attempt: interval, backoff, cooldown floor, manual and unconfigured")
    func nextAttempt() {
        func next(_ interval: RefreshInterval, last: Date?, failures: Int = 0, cooldown: Date? = nil, configured: Bool = true) -> Date? {
            RefreshPolicy.nextAttempt(
                interval: interval, isConfigured: configured, lastAttemptAt: last,
                transientFailures: failures, cooldownUntil: cooldown
            )
        }
        #expect(next(.fiveMinutes, last: Self.now) == Self.later(300))
        #expect(next(.fiveMinutes, last: Self.now, failures: 2) == Self.later(60))
        #expect(next(.oneMinute, last: Self.now, cooldown: Self.later(300)) == Self.later(300))
        #expect(next(.thirtyMinutes, last: Self.now, cooldown: Self.later(300)) == Self.later(1800))
        #expect(next(.fiveMinutes, last: nil) == .distantPast)
        #expect(next(.manual, last: Self.now) == nil)
        #expect(next(.fiveMinutes, last: Self.now, configured: false) == nil)
    }

    @Test("transient failures are timeouts, network, 5xx and an unreachable upstream")
    func transient() {
        let transient: [UsageFetchError] = [.timeout, .network(.notConnectedToInternet), .serverError(status: 503), .upstreamUnreachable]
        let permanent: [UsageFetchError] = [
            .missingSecret, .proxySecretRejected, .unauthorized, .forbidden, .accessWindowExpired,
            .proxyMissingCredentials, .rateLimited(retryAfter: nil), .invalidResponse, .redirectRefused(status: 302),
            .unexpectedStatus(418), .cancelled,
        ]
        #expect(transient.filter { !$0.isTransient }.isEmpty)
        #expect(permanent.filter(\.isTransient).isEmpty)
    }
}
