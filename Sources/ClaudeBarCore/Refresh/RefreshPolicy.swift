import Foundation

/// Something that may start a fetch.
public enum RefreshTrigger: Equatable, Sendable {
    case launch
    case timer
    case menuOpen
    case wake
    case manualRefresh
    case checkConnection
    /// The proxy URL or the secret changed; `urlChanged` is `false` for a secret-only change.
    case configChanged(urlChanged: Bool)
}

/// What the coordinator does with a trigger.
public enum RefreshDecision: Equatable, Sendable {
    /// Start a fetch (the driver picks it up at once).
    case fetch
    /// A request is in flight: run one follow-up after it, re-checked against the policy then.
    case followUp
    case ignore(IgnoreReason)

    public enum IgnoreReason: Equatable, Sendable {
        case notConfigured
        /// A 429 cooldown is active; it blocks every trigger, manual ones included.
        case coolingDown
        /// A request is in flight and its result is at least as fresh as this trigger needs.
        case inFlight
        case manualMode
        /// Menu open within `RefreshPolicy.menuOpenThrottle` of the last attempt.
        case throttled
        /// Timer before the scheduled attempt.
        case notDue
    }
}

/// The trigger rules of the refresh contract as pure functions.
public enum RefreshPolicy {
    /// Menu opens fetch only when the last attempt is at least this old (auto modes).
    public static let menuOpenThrottle: TimeInterval = 30
    /// Cooldown after a 429 without a usable future `Retry-After`.
    public static let defaultCooldown: TimeInterval = 5 * 60
    /// First transient-failure retry delay; doubles per failure up to the interval.
    public static let backoffBase: TimeInterval = 30
    /// Snapshot age that makes data stale in manual mode.
    public static let manualStaleAge: TimeInterval = 10 * 60

    /// The coordinator state the trigger rules look at.
    public struct State: Equatable, Sendable {
        public var interval: RefreshInterval
        public var isConfigured: Bool
        public var isInFlight: Bool
        public var lastAttemptAt: Date?
        public var cooldownUntil: Date?
        /// The scheduled auto attempt (see `nextAttempt`), `nil` in manual mode.
        public var nextAttemptAt: Date?

        public init(
            interval: RefreshInterval,
            isConfigured: Bool = true,
            isInFlight: Bool = false,
            lastAttemptAt: Date? = nil,
            cooldownUntil: Date? = nil,
            nextAttemptAt: Date? = nil
        ) {
            self.interval = interval
            self.isConfigured = isConfigured
            self.isInFlight = isInFlight
            self.lastAttemptAt = lastAttemptAt
            self.cooldownUntil = cooldownUntil
            self.nextAttemptAt = nextAttemptAt
        }
    }

    public static func decide(trigger: RefreshTrigger, state: State, now: Date) -> RefreshDecision {
        guard state.isConfigured else { return .ignore(.notConfigured) }
        if let cooldownUntil = state.cooldownUntil, now < cooldownUntil { return .ignore(.coolingDown) }
        let manual = state.interval.isManual

        if state.isInFlight {
            switch trigger {
            case .manualRefresh, .checkConnection:
                return .followUp
            case .configChanged:
                return manual ? .ignore(.manualMode) : .followUp
            case .launch, .timer, .menuOpen, .wake:
                return .ignore(.inFlight)
            }
        }

        switch trigger {
        case .manualRefresh, .checkConnection:
            return .fetch
        case .launch, .wake, .configChanged:
            return manual ? .ignore(.manualMode) : .fetch
        case .menuOpen:
            if manual { return .ignore(.manualMode) }
            if let last = state.lastAttemptAt, now.timeIntervalSince(last) < menuOpenThrottle {
                return .ignore(.throttled)
            }
            return .fetch
        case .timer:
            if manual { return .ignore(.manualMode) }
            guard let next = state.nextAttemptAt, next <= now else { return .ignore(.notDue) }
            return .fetch
        }
    }

    /// Delay after `failures` consecutive transient failures: `min(30 s · 2^(n-1), interval)`.
    public static func backoffDelay(failures: Int, interval: TimeInterval) -> TimeInterval {
        guard failures > 0 else { return interval }
        let exponent = Double(min(failures - 1, 30))
        return min(backoffBase * pow(2, exponent), interval)
    }

    /// End of the cooldown after a 429: `retryAfter` when strictly in the future, else now + 5 min
    /// (as CodexBar's `ClaudeOAuthUsageRateLimitGate.recordRateLimit`).
    public static func cooldownEnd(retryAfter: Date?, now: Date) -> Date {
        if let retryAfter, retryAfter > now { return retryAfter }
        return now.addingTimeInterval(defaultCooldown)
    }

    /// Snapshot age at which data becomes stale: 2 × interval, or 10 min in manual mode.
    public static func staleAge(for interval: RefreshInterval) -> TimeInterval {
        interval.seconds.map { 2 * $0 } ?? manualStaleAge
    }

    /// The next scheduled attempt in auto modes: last attempt start + interval (or the backoff
    /// delay after transient failures), never before a cooldown ends. With no attempt yet it is
    /// due at once (`distantPast`). `nil` in manual mode or without an endpoint.
    public static func nextAttempt(
        interval: RefreshInterval,
        isConfigured: Bool,
        lastAttemptAt: Date?,
        transientFailures: Int,
        cooldownUntil: Date?
    ) -> Date? {
        guard isConfigured, let seconds = interval.seconds else { return nil }
        var next = lastAttemptAt.map {
            $0.addingTimeInterval(backoffDelay(failures: transientFailures, interval: seconds))
        } ?? .distantPast
        if let cooldownUntil, cooldownUntil > next { next = cooldownUntil }
        return next
    }
}

extension UsageFetchError {
    /// Failures worth an accelerated retry: the proxy or Anthropic may answer on the next try.
    public var isTransient: Bool {
        switch self {
        case .timeout, .network, .serverError, .upstreamUnreachable: true
        default: false
        }
    }
}
