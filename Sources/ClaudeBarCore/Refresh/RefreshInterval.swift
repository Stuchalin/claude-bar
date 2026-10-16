import Foundation

/// How often the coordinator fetches on its own. `manual` never schedules a fetch.
public enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case manual = 0
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    public static let defaultValue: RefreshInterval = .fiveMinutes

    public var id: Int { rawValue }

    /// The interval in seconds, `nil` for manual mode.
    public var seconds: TimeInterval? {
        self == .manual ? nil : TimeInterval(rawValue)
    }

    public var isManual: Bool { self == .manual }

    public var title: String {
        self == .manual ? "Manual" : "\(rawValue / 60) min"
    }
}
