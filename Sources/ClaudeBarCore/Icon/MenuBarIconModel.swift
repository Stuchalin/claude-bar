import Foundation

/// What the menu bar icon shows, derived from `RefreshStatus`: the session (top) and weekly
/// (bottom) bars filled by remaining share, and the matching VoiceOver label.
public struct MenuBarIconModel: Equatable, Sendable {
    public enum Bar: Equatable, Sendable {
        /// No value to draw: never observed, or waiting for fresh data after a reset.
        case unknown
        /// Remaining percent, clamped to 0…100; `stale` for a last-known value.
        case remaining(Double, stale: Bool)
    }

    public let session: Bar
    public let weekly: Bar
    /// `Claude usage: Session 88% left, Weekly 99% left (stale)`.
    public let accessibilityLabel: String

    public init(session: Bar, weekly: Bar, accessibilityLabel: String) {
        self.session = session
        self.weekly = weekly
        self.accessibilityLabel = accessibilityLabel
    }

    public init(status: RefreshStatus) {
        let session = Self.gauge(status.session)
        let weekly = Self.gauge(status.weekly)
        self.init(
            session: session.bar,
            weekly: weekly.bar,
            accessibilityLabel: "Claude usage: Session \(session.spoken), Weekly \(weekly.spoken)"
        )
    }

    private static func gauge(_ state: MetricState) -> (bar: Bar, spoken: String) {
        switch state.presentation {
        case let .fresh(.window(window)):
            (.remaining(remaining(window), stale: false), "\(RefreshStatusText.remainingPercent(window))% left")
        case let .stale(.window(window), _):
            (.remaining(remaining(window), stale: true), "\(RefreshStatusText.remainingPercent(window))% left (stale)")
        case .waitingForFreshData:
            (.unknown, "waiting for fresh data")
        case .fresh, .stale, .unavailable:
            (.unknown, "unknown")
        }
    }

    private static func remaining(_ window: UsageWindow) -> Double {
        max(0, min(100, 100 - window.usedPercent))
    }
}
