// The burn-down shape (remaining share from window start to reset against a dashed straight line)
// follows CodexBar (https://github.com/steipete/CodexBar), Sources/CodexBar/QuotaBurndownModel.swift
// at commit a91669f. Copyright (c) 2026 Peter Steinberger. MIT License; see THIRD_PARTY_NOTICES.md.
// Unlike CodexBar, samples come from recorded runs split at breaks and gaps, and no live value is
// appended: only observed endpoints are plotted.

import Foundation

/// The current window of one stream as a burn-down: observed remaining share over time, split into
/// pieces that are never joined across a break, gap or reset, plus the ideal straight line.
public struct BurndownChartModel: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let date: Date
        /// 0…100, the remaining share (100 − used, clamped).
        public let remainingPercent: Double

        public init(date: Date, remainingPercent: Double) {
            self.date = date
            self.remainingPercent = remainingPercent
        }
    }

    /// A continuous piece of the observed line.
    public struct Segment: Equatable, Sendable, Identifiable {
        public let id: Int
        public let samples: [Sample]
    }

    /// Window start (`reset − duration`).
    public let start: Date
    public let reset: Date
    public let segments: [Segment]
    /// From 100 % at `start` to 0 % at `reset`.
    public let ideal: [Sample]
    /// The latest observation in the window.
    public let latest: Sample

    /// Upper bound for plotted points before downsampling kicks in (plus the endpoints of each
    /// segment). A week at one-minute polling would otherwise be ~20 000 points.
    public static let maxPoints = 240
}

/// What the burn-down section shows for a stream.
public enum BurndownChartState: Equatable, Sendable {
    case chart(BurndownChartModel)
    /// The stream has no recorded runs in range.
    case noObservations
    /// The latest observation has no future reset (unknown, not started, or already passed).
    case noCurrentWindow
}

extension BurndownChartModel {
    /// Builds the current window of one stream. `runs` are that stream's runs, `breaks` may include
    /// other streams' breaks of the same source (they are filtered by stream).
    public static func make(
        runs: [HistoryRun],
        breaks: [HistoryBreak],
        duration: TimeInterval,
        now: Date,
        maxPoints: Int = BurndownChartModel.maxPoints
    ) -> BurndownChartState {
        guard let latestRun = runs.max(by: { ($0.lastSeenAt, $0.id) < ($1.lastSeenAt, $1.id) }) else {
            return .noObservations
        }
        guard duration > 0, case let .at(reset) = latestRun.reset, reset > now else { return .noCurrentWindow }
        let start = reset.addingTimeInterval(-duration)
        guard start <= now else { return .noCurrentWindow }

        let windowRuns = runs.filter {
            HistoryStore.sameResetBoundary($0.reset, .at(reset)) && $0.lastSeenAt >= start && $0.firstSeenAt <= now
        }
        let pieces = HistorySegments.split(windowRuns, breaks: breaks).map { piece in
            piece.flatMap { run -> [Sample] in
                let remaining = min(100, max(0, 100 - run.usedPercent))
                let first = max(run.firstSeenAt, start)
                var samples = [Sample(date: first, remainingPercent: remaining)]
                if run.lastSeenAt > first {
                    samples.append(Sample(date: run.lastSeenAt, remainingPercent: remaining))
                }
                return samples
            }
        }.filter { !$0.isEmpty }
        let downsampled = downsample(pieces, start: start, end: reset, maxPoints: maxPoints)
        guard let latest = downsampled.last?.last else { return .noObservations }

        return .chart(BurndownChartModel(
            start: start,
            reset: reset,
            segments: downsampled.enumerated().map { Segment(id: $0.offset, samples: $0.element) },
            ideal: [Sample(date: start, remainingPercent: 100), Sample(date: reset, remainingPercent: 0)],
            latest: latest
        ))
    }

    /// Thins segments when they hold more than `maxPoints` samples in total: each segment keeps its
    /// first and last sample, and between them one sample per time bucket of width
    /// `(end − start) / maxPoints` — the one with the least remaining (the bucket's observed peak).
    static func downsample(_ segments: [[Sample]], start: Date, end: Date, maxPoints: Int) -> [[Sample]] {
        let total = segments.reduce(0) { $0 + $1.count }
        let span = end.timeIntervalSince(start)
        guard total > maxPoints, maxPoints > 0, span > 0 else { return segments }
        let width = span / Double(maxPoints)

        return segments.map { samples in
            guard samples.count > 2, let first = samples.first, let last = samples.last else { return samples }
            var kept = [first]
            var bucket: Int?
            var best: Sample?
            for sample in samples.dropFirst().dropLast() {
                let index = Int(floor(sample.date.timeIntervalSince(start) / width))
                if index != bucket {
                    if let best { kept.append(best) }
                    bucket = index
                    best = sample
                } else if let current = best, sample.remainingPercent <= current.remainingPercent {
                    best = sample
                }
            }
            if let best { kept.append(best) }
            kept.append(last)
            return kept
        }
    }
}

/// Splits one stream's runs into continuous pieces.
enum HistorySegments {
    /// Consecutive runs join only when the earlier one ended because the value changed and no break
    /// of the whole source or of this stream lies between them. Failures, missing metrics, source
    /// changes, gaps and resets all start a new piece.
    static func split(_ runs: [HistoryRun], breaks: [HistoryBreak]) -> [[HistoryRun]] {
        let sorted = runs.sorted { ($0.firstSeenAt, $0.id) < ($1.firstSeenAt, $1.id) }
        var pieces: [[HistoryRun]] = []
        for run in sorted {
            if let previous = pieces.last?.last, joins(previous, run, breaks: breaks) {
                pieces[pieces.count - 1].append(run)
            } else {
                pieces.append([run])
            }
        }
        return pieces
    }

    static func joins(_ previous: HistoryRun, _ next: HistoryRun, breaks: [HistoryBreak]) -> Bool {
        guard previous.closeReason == .changed, next.firstSeenAt >= previous.lastSeenAt else { return false }
        return !breaks.contains { brk in
            (brk.streamID == nil || brk.streamID == previous.streamID)
                && brk.at >= previous.lastSeenAt && brk.at <= next.firstSeenAt
        }
    }
}
