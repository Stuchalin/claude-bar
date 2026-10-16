import Foundation

/// One validated response from `{proxy}/api/oauth/usage`.
///
/// Every metric is independently available or unavailable: a missing or malformed field is
/// `nil` / `.unavailable`, never 0.
public struct UsageSnapshot: Equatable, Sendable {
    /// Five-hour session window; `nil` when the response carries no valid session value.
    public let session: UsageWindow?
    /// Seven-day window across all models; `nil` when unavailable.
    public let weekly: UsageWindow?
    /// Model-scoped weekly limits in response order, including inactive and unusable rows.
    public let scopedWeeklies: [ScopedWeeklyLimit]
    public let extraUsage: ExtraUsageState
    /// When the response was received, from the client's clock.
    public let fetchedAt: Date

    public init(
        session: UsageWindow?,
        weekly: UsageWindow?,
        scopedWeeklies: [ScopedWeeklyLimit],
        extraUsage: ExtraUsageState,
        fetchedAt: Date
    ) {
        self.session = session
        self.weekly = weekly
        self.scopedWeeklies = scopedWeeklies
        self.extraUsage = extraUsage
        self.fetchedAt = fetchedAt
    }
}

/// A rate-limit window with its used share and reset.
public struct UsageWindow: Equatable, Sendable {
    /// Used share in percent (0…100, may exceed 100 when the limit is overrun). Always finite, ≥ 0.
    public let usedPercent: Double
    public let reset: ResetState
    /// Nominal window length: 5 h for the session, 7 days for weekly windows.
    public let duration: TimeInterval
    /// Which response field the value came from.
    public let source: Source

    public enum Source: Equatable, Sendable {
        /// A top-level window object such as `five_hour`, `seven_day`, `seven_day_sonnet`.
        case window(field: String)
        /// A `limits[]` row of this `kind`.
        case limitsRow(kind: String)
    }

    public static let sessionDuration: TimeInterval = 5 * 60 * 60
    public static let weeklyDuration: TimeInterval = 7 * 24 * 60 * 60

    public init(usedPercent: Double, reset: ResetState, duration: TimeInterval, source: Source) {
        self.usedPercent = usedPercent
        self.reset = reset
        self.duration = duration
        self.source = source
    }
}

/// When a window resets.
public enum ResetState: Equatable, Sendable {
    case at(Date)
    /// `resets_at` is explicitly `null` and usage is 0: the window has not started yet.
    case notStarted
    /// `resets_at` is missing, malformed, or `null` while usage is above 0. No pace for such windows.
    case unknown
}

/// One model-scoped weekly limit (`limits[]` row with `kind == "weekly_scoped"`, or the legacy
/// `seven_day_sonnet` / `seven_day_opus` fields when there are no such rows).
public struct ScopedWeeklyLimit: Equatable, Sendable {
    /// Best-effort identity namespaced by provenance: `id:<model id>`, `name:<normalized display
    /// name>` or `legacy:<field>`. A rename or a name→id transition yields a new key.
    public let key: String
    /// Display name for the card title, when the response has one.
    public let displayName: String?
    /// `true` only when the row says `is_active: true` (legacy fields count as active).
    public let isActive: Bool
    public let reading: Reading

    public enum Reading: Equatable, Sendable {
        case available(UsageWindow)
        /// The row's percent is missing or malformed.
        case unavailable
        /// Another row has the same key; rows are never merged, so neither value is shown.
        case ambiguous
    }

    public init(key: String, displayName: String?, isActive: Bool, reading: Reading) {
        self.key = key
        self.displayName = displayName
        self.isActive = isActive
        self.reading = reading
    }

    /// The window to display, `nil` when unavailable or ambiguous.
    public var window: UsageWindow? {
        if case let .available(window) = reading { window } else { nil }
    }
}

/// The `extra_usage` object.
public enum ExtraUsageState: Equatable, Sendable {
    /// Missing, malformed, or without a boolean `is_enabled`.
    case unavailable
    /// `is_enabled == false`.
    case disabled
    case enabled(ExtraUsage)
}

/// Enabled extra usage. Amounts are converted from cents to currency units (÷ 100).
public struct ExtraUsage: Equatable, Sendable {
    /// Amount spent this month; `nil` when missing or malformed.
    public let used: Double?
    public let cap: Cap
    /// Trimmed currency code; `nil` when missing (never defaulted).
    public let currency: String?
    /// Used share of the cap in percent, when the response provides a valid one.
    public let utilization: Double?

    public enum Cap: Equatable, Sendable {
        /// `monthly_limit` is `null`: no cap.
        case none
        /// `monthly_limit` is 0.
        case zero
        case amount(Double)
        /// `monthly_limit` is missing or malformed.
        case unknown
    }

    public init(used: Double?, cap: Cap, currency: String?, utilization: Double?) {
        self.used = used
        self.cap = cap
        self.currency = currency
        self.utilization = utilization
    }
}
