import Foundation

/// Both history charts for every recorded stream of one source, computed at `generatedAt`.
public struct UsageHistoryCharts: Equatable, Sendable {
    public struct Series: Equatable, Sendable, Identifiable {
        /// `session`, `weekly` or `scoped:<model key>`.
        public let id: String
        public let title: String
        public let metric: HistoryMetric
        public let burndown: BurndownChartState
        public let peaks: PeakChartModel
    }

    /// Session, Weekly, then scoped streams in the order they were first recorded.
    public let series: [Series]
    public let generatedAt: Date

    /// Reads the streams of `source` and builds both charts per stream. The burn-down reads runs and
    /// breaks of the last window length by observation time (the current window starts no earlier);
    /// the peaks read whole windows by their stored reset (`peakRuns`).
    /// `scopedNames` maps a scoped key to the display name from the latest snapshot, when known.
    public static func load(
        from reader: any UsageHistoryReading,
        source: String,
        scopedNames: [String: String] = [:],
        now: Date
    ) async throws -> UsageHistoryCharts {
        let streams = try await reader.streams()
            .filter { $0.source == source }
            .sorted { (order($0.metric), $0.id) < (order($1.metric), $1.id) }

        var series: [Series] = []
        for stream in streams {
            let duration = duration(for: stream.metric)
            let windowStart = now.addingTimeInterval(-duration)
            let windowRuns = try await reader.runs(streamID: stream.id, from: windowStart, to: now)
            let breaks = try await reader.breaks(source: source, from: windowStart, to: now)
            let pastRuns = try await peakRuns(reader: reader, streamID: stream.id, now: now)
            // Older history without a recent observation means no current window, not no data.
            let burndown = windowRuns.isEmpty && !pastRuns.isEmpty
                ? BurndownChartState.noCurrentWindow
                : BurndownChartModel.make(runs: windowRuns, breaks: breaks, duration: duration, now: now)
            series.append(Series(
                id: seriesID(stream),
                title: title(metric: stream.metric, modelKey: stream.modelKey, scopedNames: scopedNames),
                metric: stream.metric,
                burndown: burndown,
                peaks: PeakChartModel.make(runs: pastRuns, duration: duration, now: now)
            ))
        }
        return UsageHistoryCharts(series: series, generatedAt: now)
    }

    /// Every run of the newest `maxSlots` past windows of one stream (and of any later window),
    /// selected by their stored reset, never by when they were observed.
    ///
    /// All distinct reset dates are grouped with `PeakChartModel`'s rule. The oldest included group
    /// is the `maxSlots`-th newest whose resets all lie at or before `now`; every run whose reset is
    /// at or after that group's first reset is read. Grouping only looks forward from a group's first
    /// reset, so `PeakChartModel` regroups these runs exactly as it would the full history, and no
    /// included window is ever truncated.
    static func peakRuns(
        reader: any UsageHistoryReading,
        streamID: Int64,
        now: Date,
        maxSlots: Int = PeakChartModel.maxSlots
    ) async throws -> [HistoryRun] {
        let groups = PeakChartModel.clusters(resetDates: try await reader.resetDates(streamID: streamID))
        let past = groups.filter { ($0.last ?? .distantFuture) <= now }
        guard let oldest = past.suffix(max(1, maxSlots)).first?.first ?? groups.first?.first else { return [] }
        return try await reader.runs(streamID: streamID, resetsFrom: oldest)
    }

    static func seriesID(_ stream: HistoryStream) -> String {
        stream.metric == .scoped ? "scoped:\(stream.modelKey)" : stream.metric.rawValue
    }

    static func order(_ metric: HistoryMetric) -> Int {
        switch metric {
        case .session: 0
        case .weekly: 1
        case .scoped: 2
        }
    }

    public static func duration(for metric: HistoryMetric) -> TimeInterval {
        metric == .session ? UsageWindow.sessionDuration : UsageWindow.weeklyDuration
    }

    /// `Session`, `Weekly`, or the scoped card title (`Sonnet weekly`). Without a current display
    /// name the title comes from the key: `name:` and `legacy:` keys carry a name, an `id:` key
    /// shows the model id.
    static func title(metric: HistoryMetric, modelKey: String, scopedNames: [String: String]) -> String {
        switch metric {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .scoped:
            if let name = scopedNames[modelKey] { return MenuCardModel.scopedTitle(name) }
            if modelKey.hasPrefix("name:") { return MenuCardModel.scopedTitle(String(modelKey.dropFirst(5))) }
            if modelKey.hasPrefix("id:") { return MenuCardModel.scopedTitle(String(modelKey.dropFirst(3))) }
            switch modelKey {
            case "legacy:seven_day_sonnet": return "Sonnet weekly"
            case "legacy:seven_day_opus": return "Opus weekly"
            default: return MenuCardModel.scopedTitle(nil)
            }
        }
    }
}
