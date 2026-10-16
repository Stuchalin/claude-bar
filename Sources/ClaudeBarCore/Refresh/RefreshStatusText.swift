import Foundation

/// Wording for the placeholder status item and menu (replaced by the cards and icon of later
/// tasks). Times are formatted by the caller.
public enum RefreshStatusText {
    public typealias TimeFormat = (Date) -> String

    /// Remaining share of a window in whole percent, clamped to 0…100.
    public static func remainingPercent(_ window: UsageWindow) -> Int {
        Int(max(0, min(100, 100 - window.usedPercent)).rounded())
    }

    /// `S 88% · W 99%` (remaining); `—` when unknown or waiting, `*` after a stale value.
    public static func statusTitle(_ status: RefreshStatus) -> String {
        "\(titleComponent("S", status.session)) · \(titleComponent("W", status.weekly))"
    }

    static func titleComponent(_ prefix: String, _ state: MetricState) -> String {
        switch state.presentation {
        case let .fresh(value):
            value.window.map { "\(prefix) \(remainingPercent($0))%" } ?? "\(prefix) —"
        case let .stale(value, _):
            value.window.map { "\(prefix) \(remainingPercent($0))%*" } ?? "\(prefix) —"
        case .waitingForFreshData, .unavailable:
            "\(prefix) —"
        }
    }

    /// `Session: 88% left · resets 14:30`, with the stale, waiting and unavailable variants.
    public static func metricLine(title: String, state: MetricState, time: TimeFormat) -> String {
        switch state.presentation {
        case let .fresh(value):
            "\(title): \(describe(value, time: time))"
        case let .stale(value, lastSeenAt):
            "\(title): \(describe(value, time: time)) (stale, seen \(time(lastSeenAt)))"
        case let .waitingForFreshData(lastSeenAt):
            "\(title): reset passed, waiting for fresh data (seen \(time(lastSeenAt)))"
        case .unavailable:
            "\(title): unavailable"
        }
    }

    private static func describe(_ value: MetricValue, time: TimeFormat) -> String {
        switch value {
        case let .window(window):
            let reset = switch window.reset {
            case let .at(date): " · resets \(time(date))"
            case .notStarted: " · not started"
            case .unknown: " · reset unknown"
            }
            return "\(remainingPercent(window))% left\(reset)"
        case .extra(.enabled):
            return "enabled"
        case .extra:
            return "disabled"
        }
    }

    /// `Updated 14:05`, `Stale — last updated 14:05`, `Refreshing…` or `Not updated yet`.
    public static func updatedLine(_ status: RefreshStatus, time: TimeFormat) -> String {
        guard status.isConfigured else { return "Set the proxy URL and secret in Settings." }
        if status.connection == .loading, status.lastSuccessAt == nil { return "Refreshing…" }
        guard let lastSuccessAt = status.lastSuccessAt else { return "Not updated yet" }
        return status.isStale
            ? "Stale — last updated \(time(lastSuccessAt))"
            : "Updated \(time(lastSuccessAt))"
    }

    /// The error row's hint while the latest attempt failed.
    public static func errorLine(_ status: RefreshStatus) -> String? {
        if case let .failed(error) = status.connection { error.hint } else { nil }
    }

    /// `Next attempt at 14:10` in auto modes; `Retry available at 14:10` in manual mode during a
    /// cooldown, since nothing is scheduled there.
    public static func timingLine(_ status: RefreshStatus, time: TimeFormat) -> String? {
        if let retry = status.retryAvailableAt { return "Retry available at \(time(retry))" }
        if let next = status.nextAttemptAt { return "Next attempt at \(time(next))" }
        return nil
    }
}
