import Foundation

/// Synthetic, in-memory history for the debug fixture mode (`--history-fixtures`), so both charts
/// can be reviewed without waiting for real history. Nothing here touches the history file: the
/// result is an `InMemoryUsageHistory` under its own source, never a `HistoryRecording`.
public enum UsageHistoryFixtures {
    /// The fixture source; never a valid proxy URL, so it cannot match real streams.
    public static let source = "fixture://claudebar-history"
    /// The process argument that turns the fixture mode on for one launch.
    public static let launchArgument = "--history-fixtures"

    /// Whether this launch asked for fixtures. Read from the process arguments only, never persisted.
    public static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.dropFirst().contains(launchArgument)
    }

    /// Session, Weekly and one scoped stream, each with a current window holding a break or gap and
    /// past windows with one unobserved stretch, all relative to `now`.
    public static func make(now: Date) -> InMemoryUsageHistory {
        var builder = Builder(now: now)
        let hour: TimeInterval = 3600
        let day = 24 * hour
        let session: Int64 = 1, weekly: Int64 = 2, scoped: Int64 = 3

        // Session: current window ends in 2 h; the metric went missing once (stream break).
        let sessionReset = now.addingTimeInterval(2 * hour)
        builder.piece(session, reset: sessionReset, points: [
            (-3 * hour, 2), (-2.67 * hour, 5), (-2.33 * hour, 9), (-2 * hour, 14), (-1.67 * hour, 18),
        ], end: .missing)
        builder.piece(session, reset: sessionReset, points: [
            (-1.17 * hour, 24), (-0.92 * hour, 27), (-0.67 * hour, 31), (-0.42 * hour, 36), (-0.02 * hour, 40),
        ], end: nil)
        // Past session windows, back to back, with two missing between the 4th and 5th newest.
        let sessionPeaks: [Double] = [62, 88, 45, 100, 30, 71, 54, 95, 12, 67]
        for (index, peak) in sessionPeaks.enumerated() {
            let back = index < 4 ? index + 1 : index + 3
            builder.pastWindow(session, reset: sessionReset.addingTimeInterval(-Double(back) * 5 * hour),
                               duration: 5 * hour, peak: peak)
        }

        // Weekly: current window ends in 3 days, with a polling gap in the middle.
        let weeklyReset = now.addingTimeInterval(3 * day)
        builder.piece(weekly, reset: weeklyReset, points: stride(from: 0.0, through: 6, by: 1).map {
            (-4 * day + $0 * 8 * hour, 3.5 * $0)
        }, end: .gap)
        builder.piece(weekly, reset: weeklyReset, points: stride(from: 0.0, through: 6, by: 1).map {
            (-1.5 * day + $0 * 6 * hour, 28 + 4.5 * $0)
        }, end: nil)
        let weeklyPeaks: [Double] = [74, 58, 91, 66, 40, 83, 77, 52]
        for (index, peak) in weeklyPeaks.enumerated() {
            let back = index < 3 ? index + 1 : index + 3
            builder.pastWindow(weekly, reset: weeklyReset.addingTimeInterval(-Double(back) * 7 * day),
                               duration: 7 * day, peak: peak)
        }

        // A scoped weekly limit sharing the weekly reset.
        builder.piece(scoped, reset: weeklyReset, points: stride(from: 0.0, through: 7, by: 1).map {
            (-4 * day + $0 * 12 * hour, 2.5 * $0)
        }, end: nil)
        for (index, peak) in [35.0, 22, 48, 15, 30].enumerated() {
            builder.pastWindow(scoped, reset: weeklyReset.addingTimeInterval(-Double(index + 1) * 7 * day),
                               duration: 7 * day, peak: peak)
        }

        return InMemoryUsageHistory(
            streams: [
                HistoryStream(id: session, source: source, metric: .session, modelKey: ""),
                HistoryStream(id: weekly, source: source, metric: .weekly, modelKey: ""),
                HistoryStream(id: scoped, source: source, metric: .scoped, modelKey: "name:Sonnet"),
            ],
            runs: builder.runs,
            breaks: builder.breaks
        )
    }

    private struct Builder {
        let now: Date
        var runs: [HistoryRun] = []
        var breaks: [HistoryBreak] = []
        private var nextID: Int64 = 1
        private let poll: TimeInterval = 60

        init(now: Date) { self.now = now }

        /// One continuous piece: a run per point, each closed as `changed` where the next begins.
        /// The last run is closed for `end` one poll after its first sighting (open when `nil`).
        mutating func piece(
            _ stream: Int64, reset: Date, points: [(offset: TimeInterval, used: Double)], end: HistoryCloseReason?
        ) {
            for (index, point) in points.enumerated() {
                let first = now.addingTimeInterval(point.offset)
                let next = index + 1 < points.count ? now.addingTimeInterval(points[index + 1].offset) : nil
                let lastSeen = next.map { $0.addingTimeInterval(-poll) } ?? min(now, first.addingTimeInterval(poll))
                let closedAt: Date? = next ?? (end == nil ? nil : (end == .gap ? lastSeen : lastSeen.addingTimeInterval(poll)))
                let reason: HistoryCloseReason? = next == nil ? end : .changed
                runs.append(HistoryRun(
                    id: takeID(), streamID: stream, firstSeenAt: first, lastSeenAt: max(first, lastSeen),
                    usedPercent: point.used, reset: .at(reset), closedAt: closedAt, closeReason: reason
                ))
                if next == nil, let closedAt, let breakReason = Self.breakReason(end) {
                    breaks.append(HistoryBreak(
                        id: takeID(), source: source, at: closedAt, reason: breakReason, streamID: stream
                    ))
                }
            }
        }

        /// A closed past window rising to `peak` and ended by its reset.
        mutating func pastWindow(_ stream: Int64, reset: Date, duration: TimeInterval, peak: Double) {
            let offset = reset.timeIntervalSince(now)
            piece(stream, reset: reset, points: [
                (offset - duration * 0.8, (peak * 0.3).rounded()),
                (offset - duration * 0.4, (peak * 0.7).rounded()),
                (offset - duration * 0.1, peak),
            ], end: .reset)
        }

        private mutating func takeID() -> Int64 {
            defer { nextID += 1 }
            return nextID
        }

        private static func breakReason(_ reason: HistoryCloseReason?) -> HistoryBreakReason? {
            switch reason {
            case .missing: .missing
            case .failure: .failure
            case .source: .source
            default: nil
            }
        }
    }
}
