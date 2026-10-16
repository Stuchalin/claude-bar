import Foundation

/// Time source for the refresh coordinator; tests inject a manual clock.
public protocol RefreshClock: Sendable {
    var now: Date { get }
    /// Suspends until `deadline` or until the calling task is cancelled (then throws).
    /// Returning early is allowed: the coordinator re-evaluates its deadlines after every wake.
    func sleep(until deadline: Date) async throws
}

/// Wall-clock time with `Task.sleep`, which runs on the continuous clock and so keeps counting
/// while the Mac sleeps. A single sleep is capped, so a wall-clock change is noticed within the cap.
public struct SystemRefreshClock: RefreshClock {
    static let maxSleep: TimeInterval = 15 * 60

    public init() {}

    public var now: Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let delay = min(max(0, deadline.timeIntervalSinceNow), Self.maxSleep)
        try await Task.sleep(for: .seconds(delay))
    }
}
