// The per-window bar layout (one capped bar per reset window, at most 30, newest last) follows
// CodexBar (https://github.com/steipete/CodexBar), Sources/CodexBar/PlanUtilizationHistoryChartMenuView.swift
// at commit a91669f. Copyright (c) 2026 Peter Steinberger. MIT License; see THIRD_PARTY_NOTICES.md.
// Unlike CodexBar, windows are never placed on a reconstructed lattice and unobserved stretches are
// not drawn as 0 %.

import Foundation

/// Observed peak usage of each past window of one stream.
///
/// A window exists only where a reset boundary was observed: runs are grouped by their `resets_at`
/// (two resets closer than `HistoryStore.resetTolerance` are one boundary). Where consecutive
/// observed windows are further apart than one window length, a single `unobserved` slot marks the
/// stretch: it carries no value and no claim about how many windows it held.
public struct PeakChartModel: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// The observed reset that ended the window.
        public let resetAt: Date
        /// Highest used share seen in the window. Sampling may have missed the true peak.
        public let peakUsedPercent: Double
        public let firstSeenAt: Date
        public let lastSeenAt: Date
    }

    public enum Slot: Equatable, Sendable {
        case observed(Window)
        /// A stretch with no observed window, from the previous observed reset to the start of the
        /// next observed window.
        case unobserved(from: Date, to: Date)

        public var isObserved: Bool {
            if case .observed = self { true } else { false }
        }
    }

    /// Oldest first.
    public let slots: [Slot]

    public static let maxSlots = 30

    public var observedWindows: [Window] {
        slots.compactMap { if case let .observed(window) = $0 { window } else { nil } }
    }

    /// Past windows only: those whose reset is at or before `now`. Runs with an unknown or
    /// not-started reset belong to no window and are skipped.
    public static func make(
        runs: [HistoryRun],
        duration: TimeInterval,
        now: Date,
        maxSlots: Int = PeakChartModel.maxSlots
    ) -> PeakChartModel {
        let clusters = clusters(runs)
        let windows = clusters.compactMap { cluster -> Window? in
            guard let newest = cluster.max(by: { ($0.run.lastSeenAt, $0.run.id) < ($1.run.lastSeenAt, $1.run.id) }),
                  newest.reset <= now
            else { return nil }
            return Window(
                resetAt: newest.reset,
                peakUsedPercent: cluster.map(\.run.usedPercent).max() ?? 0,
                firstSeenAt: cluster.map(\.run.firstSeenAt).min() ?? newest.run.firstSeenAt,
                lastSeenAt: cluster.map(\.run.lastSeenAt).max() ?? newest.run.lastSeenAt
            )
        }

        var slots: [Slot] = []
        for window in windows {
            if let previous = slots.last, case let .observed(prior) = previous,
               window.resetAt.timeIntervalSince(prior.resetAt) > duration + HistoryStore.resetTolerance {
                slots.append(.unobserved(from: prior.resetAt, to: window.resetAt.addingTimeInterval(-duration)))
            }
            slots.append(.observed(window))
        }

        var trimmed = Array(slots.suffix(max(0, maxSlots)))
        while let first = trimmed.first, !first.isObserved { trimmed.removeFirst() }
        return PeakChartModel(slots: trimmed)
    }

    /// Runs with an observed reset grouped into windows, oldest reset first; each group is sorted by
    /// reset, so its first entry holds the earliest reset. A run joins the current group when its
    /// reset is within `HistoryStore.resetTolerance` of the group's first reset. The loader decides
    /// completeness per group with this same rule.
    static func clusters(_ runs: [HistoryRun]) -> [[(reset: Date, run: HistoryRun)]] {
        let dated = runs.compactMap { run -> (reset: Date, run: HistoryRun)? in
            if case let .at(reset) = run.reset { (reset, run) } else { nil }
        }.sorted { ($0.reset, $0.run.id) < ($1.reset, $1.run.id) }
        return group(dated, reset: \.reset)
    }

    /// Reset dates grouped by the same rule as `clusters(_:)`, oldest first.
    static func clusters(resetDates: [Date]) -> [[Date]] {
        group(resetDates.sorted(), reset: { $0 })
    }

    /// Groups items already sorted by reset: an item joins the current group when its reset is
    /// within `HistoryStore.resetTolerance` of the group's first reset.
    private static func group<T>(_ sorted: [T], reset: (T) -> Date) -> [[T]] {
        var groups: [[T]] = []
        for item in sorted {
            if let anchor = groups.last?.first.map(reset),
               reset(item).timeIntervalSince(anchor) < HistoryStore.resetTolerance {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }
        return groups
    }

    /// The caption under the bar chart for `slot` (the newest when the caller passes `slots.last`).
    public static func detailText(_ slot: Slot?, date: (Date) -> String) -> String {
        switch slot {
        case let .observed(window):
            "Ended \(date(window.resetAt)): observed peak \(UsageFormatter.percentText(window.peakUsedPercent, suffix: "used"))"
        case let .unobserved(from, to):
            "\(date(from)) – \(date(to)): not observed"
        case nil:
            "No past windows observed yet"
        }
    }
}
