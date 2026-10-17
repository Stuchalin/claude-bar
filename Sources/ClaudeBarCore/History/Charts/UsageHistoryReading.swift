import Foundation

/// Read access to recorded history, as the charts need it. `HistoryStore` is the real source; the
/// debug fixture mode and tests use `InMemoryUsageHistory`, so no chart path can write anywhere.
public protocol UsageHistoryReading: Sendable {
    func streams() async throws -> [HistoryStream]
    /// Runs of `streamID` overlapping `from…to`, oldest first.
    func runs(streamID: Int64, from: Date, to: Date) async throws -> [HistoryRun]
    /// Distinct observed reset dates of `streamID`, oldest first.
    func resetDates(streamID: Int64) async throws -> [Date]
    /// Every run of `streamID` with an observed reset at or after `resetsFrom`, regardless of
    /// when it was observed, ordered by first sighting.
    func runs(streamID: Int64, resetsFrom: Date) async throws -> [HistoryRun]
    /// Breaks of `source` within `from…to`, oldest first.
    func breaks(source: String, from: Date, to: Date) async throws -> [HistoryBreak]
}

extension HistoryStore: UsageHistoryReading {}

/// Immutable history held in memory, with the same overlap semantics as `HistoryStore`'s queries.
public struct InMemoryUsageHistory: UsageHistoryReading {
    public let allStreams: [HistoryStream]
    public let allRuns: [HistoryRun]
    public let allBreaks: [HistoryBreak]

    public init(streams: [HistoryStream], runs: [HistoryRun], breaks: [HistoryBreak]) {
        allStreams = streams
        allRuns = runs
        allBreaks = breaks
    }

    public func streams() async throws -> [HistoryStream] {
        allStreams.sorted { $0.id < $1.id }
    }

    public func runs(streamID: Int64, from: Date, to: Date) async throws -> [HistoryRun] {
        allRuns
            .filter { $0.streamID == streamID && $0.lastSeenAt >= from && $0.firstSeenAt <= to }
            .sorted { ($0.firstSeenAt, $0.id) < ($1.firstSeenAt, $1.id) }
    }

    public func resetDates(streamID: Int64) async throws -> [Date] {
        Set(allRuns.compactMap { run -> Date? in
            guard run.streamID == streamID, case let .at(reset) = run.reset else { return nil }
            return reset
        }).sorted()
    }

    public func runs(streamID: Int64, resetsFrom: Date) async throws -> [HistoryRun] {
        allRuns
            .filter { run in
                guard run.streamID == streamID, case let .at(reset) = run.reset else { return false }
                return reset >= resetsFrom
            }
            .sorted { ($0.firstSeenAt, $0.id) < ($1.firstSeenAt, $1.id) }
    }

    public func breaks(source: String, from: Date, to: Date) async throws -> [HistoryBreak] {
        allBreaks
            .filter { $0.source == source && $0.at >= from && $0.at <= to }
            .sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }
}
