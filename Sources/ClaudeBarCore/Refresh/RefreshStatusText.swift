import Foundation

/// Shared wording for the menu and the icon: remaining percent, the card header's updated and
/// error lines, and the footer's timing line. Times are formatted by the caller.
public enum RefreshStatusText {
    public typealias TimeFormat = (Date) -> String

    /// Remaining share of a window in whole percent, clamped to 0…100.
    public static func remainingPercent(_ window: UsageWindow) -> Int {
        Int(max(0, min(100, 100 - window.usedPercent)).rounded())
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
