import Foundation

/// The connection, separate from the last successful snapshot.
public enum ConnectionState: Equatable, Sendable {
    /// No accepted attempt for the current source yet (or none configured).
    case idle
    case loading
    case succeeded
    case failed(UsageFetchError)
}

/// Where the coordinator stands for the current source, from its last accepted attempt.
/// Staleness by age is reported separately in `RefreshStatus.isStale`.
public enum RefreshPhase: Equatable, Sendable {
    /// No snapshot and no failure yet.
    case firstLoad
    /// No snapshot; the last attempt failed.
    case firstFailure
    /// A snapshot exists; the last attempt after it failed.
    case failureWithCache
    /// A snapshot exists and the last attempt succeeded.
    case fresh
}

/// Identity of one displayed metric.
public enum MetricID: Hashable, Sendable {
    case session
    case weekly
    /// A model-scoped weekly limit by its `ScopedWeeklyLimit.key`.
    case scoped(key: String)
    case extra
}

/// A metric's observed value.
public enum MetricValue: Equatable, Sendable {
    case window(UsageWindow)
    /// Extra usage as reported, `.enabled` or `.disabled` (never `.unavailable`).
    case extra(ExtraUsageState)

    public var window: UsageWindow? {
        if case let .window(window) = self { window } else { nil }
    }
}

/// How a metric may be shown right now.
public enum MetricPresentation: Equatable, Sendable {
    /// In the latest accepted snapshot, which is not stale.
    case fresh(MetricValue)
    /// The last known value: the snapshot is stale, or the metric was missing from the latest one.
    case stale(MetricValue, lastSeenAt: Date)
    /// The last known window's reset has passed without a newer observation: no renewed
    /// capacity and no forecast until a fetch brings a new value.
    case waitingForFreshData(lastSeenAt: Date)
    /// Never observed for the current source.
    case unavailable
}

public struct MetricState: Equatable, Sendable {
    public let presentation: MetricPresentation
    /// `true` only for a fresh window with a reset in the future.
    public let allowsForecast: Bool

    public static let unavailable = MetricState(presentation: .unavailable, allowsForecast: false)

    public init(presentation: MetricPresentation, allowsForecast: Bool) {
        self.presentation = presentation
        self.allowsForecast = allowsForecast
    }
}

/// One scoped weekly row: those in the latest snapshot in response order, then keys seen
/// earlier for the same source and missing now.
public struct ScopedMetricState: Equatable, Sendable {
    public let key: String
    public let displayName: String?
    /// Another row in the latest snapshot has the same key; neither value is shown.
    public let isAmbiguous: Bool
    public let state: MetricState

    public init(key: String, displayName: String?, isAmbiguous: Bool, state: MetricState) {
        self.key = key
        self.displayName = displayName
        self.isAmbiguous = isAmbiguous
        self.state = state
    }
}

/// Everything the UI reads from the coordinator, published as one value.
public struct RefreshStatus: Equatable, Sendable {
    public var isConfigured = false
    public var interval = RefreshInterval.defaultValue
    public var connection = ConnectionState.idle
    public var phase = RefreshPhase.firstLoad
    /// The latest accepted snapshot of the current source.
    public var snapshot: UsageSnapshot?
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    /// Scheduled automatic attempt (auto modes, not during a request).
    public var nextAttemptAt: Date?
    /// End of an active cooldown in manual mode, where nothing is scheduled.
    public var retryAvailableAt: Date?
    /// End of an active 429 cooldown.
    public var cooldownUntil: Date?
    /// The snapshot is older than the stale age, or the latest attempt after it failed.
    public var isStale = false
    public var session = MetricState.unavailable
    public var weekly = MetricState.unavailable
    public var extra = MetricState.unavailable
    public var scoped: [ScopedMetricState] = []

    public init() {}
}
