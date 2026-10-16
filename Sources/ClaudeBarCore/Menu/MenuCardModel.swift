import Foundation

/// What the menu card shows, derived from `RefreshStatus` at a moment `now`. Pure, so wording
/// and visibility are tested without AppKit.
public struct MenuCardModel: Equatable, Sendable {
    public struct Header: Equatable, Sendable {
        public let title: String
        /// `Updated 14:05`, `Stale — last updated 14:05`, `Refreshing…`, …
        public let subtitle: String
        /// The latest attempt's error hint, when it failed.
        public let errorText: String?
    }

    /// One quota card: Session, Weekly or a model-scoped weekly.
    public struct Metric: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let content: Content

        public enum Content: Equatable, Sendable {
            case usage(Usage)
            /// No value to draw: unavailable, ambiguous, or waiting for fresh data after a reset.
            case status(String)
        }
    }

    public struct Usage: Equatable, Sendable {
        /// Remaining percent, 0…100: the bar's fill.
        public let percentLeft: Double
        /// `88% left`.
        public let percentText: String
        /// `Resets in 4h 12m`, `Not started`, `Reset unknown`.
        public let resetText: String
        /// Pace line, only for a fresh window with a future reset.
        public let paceText: String?
        /// Where the pace marker sits on the bar (remaining scale); `nil` when on track or no pace.
        public let pacePercent: Double?
        /// `true` when usage is at or below the straight line (reserve, green marker).
        public let paceOnTop: Bool
        /// `Stale · seen 14:05` for a last-known value; `nil` when fresh.
        public let staleText: String?
    }

    /// The Extra usage card.
    public struct Extra: Equatable, Sendable {
        public let title: String
        /// Remaining share of the cap, 0…100, when a cap and spend are known.
        public let percentLeft: Double?
        /// `This month: $12.34 / $50.00`.
        public let spendText: String
        /// `25% used`.
        public let percentText: String?
        /// The specific state when there is no usable cap or currency: `No monthly cap`, …
        public let noteText: String?
        public let staleText: String?
    }

    public let header: Header
    public let metrics: [Metric]
    public let extra: Extra?

    public typealias TimeFormat = RefreshStatusText.TimeFormat

    public init(status: RefreshStatus, now: Date, time: TimeFormat) {
        header = Header(
            title: "Claude",
            subtitle: RefreshStatusText.updatedLine(status, time: time),
            errorText: RefreshStatusText.errorLine(status)
        )

        var metrics = [
            Self.metric(id: "session", title: "Session", state: status.session, isSession: true, now: now, time: time),
            Self.metric(id: "weekly", title: "Weekly", state: status.weekly, isSession: false, now: now, time: time),
        ]
        // Ambiguous rows share their key, so their card ids add an occurrence index. Ambiguous and
        // resolved rows use disjoint namespaces placed before the opaque key, so no key can make
        // two ids equal. Presentation identity only: the metric/history identity stays unresolved.
        var occurrences: [String: Int] = [:]
        for row in status.scoped {
            let title = Self.scopedTitle(row.displayName)
            if row.isAmbiguous {
                let index = occurrences[row.key, default: 0]
                occurrences[row.key] = index + 1
                metrics.append(Metric(
                    id: "scoped:ambiguous:\(index):\(row.key)", title: title,
                    content: .status("Ambiguous: several limits share this name")
                ))
            } else {
                metrics.append(Self.metric(
                    id: "scoped:resolved:\(row.key)", title: title, state: row.state, isSession: false, now: now, time: time
                ))
            }
        }
        self.metrics = metrics
        extra = Self.extra(status.extra, time: time)
    }

    /// `Sonnet weekly` (a trailing "only" is dropped, as CodexBar does); `Model weekly` without a name.
    static func scopedTitle(_ displayName: String?) -> String {
        guard let name = displayName?
            .replacingOccurrences(of: #"\s+only\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return "Model weekly" }
        return "\(name) weekly"
    }

    static func metric(
        id: String, title: String, state: MetricState, isSession: Bool, now: Date, time: TimeFormat
    ) -> Metric {
        let content: Metric.Content
        switch state.presentation {
        case let .fresh(value):
            content = value.window.map {
                .usage(usage($0, staleText: nil, allowsForecast: state.allowsForecast, isSession: isSession, now: now))
            } ?? .status("Unavailable")
        case let .stale(value, lastSeenAt):
            content = value.window.map {
                .usage(usage($0, staleText: "Stale · seen \(time(lastSeenAt))", allowsForecast: false,
                             isSession: isSession, now: now))
            } ?? .status("Unavailable")
        case let .waitingForFreshData(lastSeenAt):
            content = .status("Reset passed · waiting for fresh data (seen \(time(lastSeenAt)))")
        case .unavailable:
            content = .status("Unavailable")
        }
        return Metric(id: id, title: title, content: content)
    }

    static func usage(
        _ window: UsageWindow, staleText: String?, allowsForecast: Bool, isSession: Bool, now: Date
    ) -> Usage {
        let pace = allowsForecast ? UsagePace.forCard(window: window, isSession: isSession, now: now) : nil
        return Usage(
            percentLeft: min(100, max(0, 100 - window.usedPercent)),
            percentText: UsageFormatter.percentLeftText(usedPercent: window.usedPercent),
            resetText: UsageFormatter.resetText(window.reset, now: now),
            paceText: pace.map { UsageFormatter.paceText($0, isSession: isSession, now: now) },
            // As CodexBar: no marker when on track; otherwise the expected point on the remaining scale.
            pacePercent: pace.flatMap { $0.stage == .onTrack ? nil : 100 - $0.expectedUsedPercent },
            paceOnTop: pace.map { $0.actualUsedPercent <= $0.expectedUsedPercent } ?? true,
            staleText: staleText
        )
    }

    /// Never observed and explicitly disabled extra usage are hidden; enabled extra usage shows its
    /// amounts or its specific state, marked stale when it is a last-known value. No reset, no pace.
    static func extra(_ state: MetricState, time: TimeFormat) -> Extra? {
        let value: MetricValue
        let staleText: String?
        switch state.presentation {
        case let .fresh(fresh):
            value = fresh
            staleText = nil
        case let .stale(stale, lastSeenAt):
            value = stale
            staleText = "Stale · seen \(time(lastSeenAt))"
        case .waitingForFreshData, .unavailable:
            return nil
        }
        guard case let .extra(.enabled(usage)) = value else { return nil }

        let used = usage.used.map { UsageFormatter.money($0, currency: usage.currency) } ?? "—"
        var notes: [String] = []
        var percentUsed: Double?
        let spendText: String
        switch usage.cap {
        case let .amount(cap):
            spendText = "This month: \(used) / \(UsageFormatter.money(cap, currency: usage.currency))"
            percentUsed = cap > 0 ? (usage.used.map { $0 / cap * 100 } ?? usage.utilization) : usage.utilization
        case .none:
            spendText = "This month: \(used)"
            notes.append("No monthly cap")
        case .zero:
            spendText = "This month: \(used)"
            notes.append("Monthly cap is 0")
        case .unknown:
            spendText = "This month: \(used)"
            notes.append("Monthly cap unknown")
        }
        if usage.currency == nil { notes.append("currency unknown") }
        let clamped = percentUsed.map { min(100, max(0, $0)) }
        return Extra(
            title: "Extra usage",
            percentLeft: clamped.map { 100 - $0 },
            spendText: spendText,
            percentText: clamped.map { UsageFormatter.percentText($0, suffix: "used") },
            noteText: notes.isEmpty ? nil : notes.joined(separator: " · "),
            staleText: staleText
        )
    }
}
