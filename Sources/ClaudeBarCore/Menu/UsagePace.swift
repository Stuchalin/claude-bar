// Adapted from CodexBar (https://github.com/steipete/CodexBar), Sources/CodexBarCore/UsagePace.swift
// and Sources/CodexBar/UsagePaceText.swift (sessionPace) at commit a91669f.
// Copyright (c) 2026 Peter Steinberger. MIT License; see THIRD_PARTY_NOTICES.md.
// Kept: the linear pace, stage thresholds and ETA. Dropped: work-day weighting, run-out
// probability and the headroom multiplier.

import Foundation

/// Average pace since the window started: how far actual use is ahead of or behind a straight
/// line from 0 % at the window start to 100 % at its reset.
public struct UsagePace: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case onTrack
        case slightlyAhead
        case ahead
        case farAhead
        case slightlyBehind
        case behind
        case farBehind
    }

    public let stage: Stage
    /// `actual − expected`; positive means using faster than the straight line (deficit).
    public let deltaPercent: Double
    /// `elapsed / duration · 100`, clamped to 0…100.
    public let expectedUsedPercent: Double
    /// Used percent clamped to 0…100.
    public let actualUsedPercent: Double
    /// Seconds until 100 % at the average rate so far; 0 when already exhausted; `nil` when the
    /// window lasts until reset or no rate exists yet.
    public let etaSeconds: TimeInterval?
    public let willLastToReset: Bool

    public init(
        stage: Stage,
        deltaPercent: Double,
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool
    ) {
        self.stage = stage
        self.deltaPercent = deltaPercent
        self.expectedUsedPercent = expectedUsedPercent
        self.actualUsedPercent = actualUsedPercent
        self.etaSeconds = etaSeconds
        self.willLastToReset = willLastToReset
    }

    /// CodexBar's `UsagePace.weekly` without work-day weighting. `nil` when the reset is unknown,
    /// not in the future, or further away than the window length (implausible), and when time has
    /// not started yet but usage is already above 0.
    public static func linear(window: UsageWindow, now: Date) -> UsagePace? {
        guard case let .at(resetsAt) = window.reset else { return nil }
        let duration = window.duration
        guard duration > 0 else { return nil }
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }
        let elapsed = min(max(duration - timeUntilReset, 0), duration)
        let expected = min(max(elapsed / duration * 100, 0), 100)
        let actual = min(max(window.usedPercent, 0), 100)
        if elapsed == 0, actual > 0 { return nil }
        let delta = actual - expected

        var etaSeconds: TimeInterval?
        var willLastToReset = false
        if actual >= 100 {
            etaSeconds = 0
        } else if elapsed > 0, actual > 0 {
            let rate = actual / elapsed
            if rate > 0 {
                let candidate = (100 - actual) / rate
                if candidate >= timeUntilReset {
                    willLastToReset = true
                } else {
                    etaSeconds = candidate
                }
            }
        } else if elapsed > 0, actual == 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset
        )
    }

    /// Pace shown on a menu card. Nothing once the window is exhausted (as CodexBar's session and
    /// weekly pace details); the session additionally needs ≥ 3 % of the window elapsed
    /// (CodexBar `UsagePaceText.sessionPace`).
    public static func forCard(window: UsageWindow, isSession: Bool, now: Date) -> UsagePace? {
        guard window.usedPercent < 100, let pace = linear(window: window, now: now) else { return nil }
        if isSession, pace.expectedUsedPercent < 3 { return nil }
        return pace
    }

    static func stage(for delta: Double) -> Stage {
        let absDelta = abs(delta)
        if absDelta <= 2 { return .onTrack }
        if absDelta <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if absDelta <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }
}
