// Wording adapted from CodexBar (https://github.com/steipete/CodexBar),
// Sources/CodexBarCore/UsageFormatter.swift and Sources/CodexBar/UsagePaceText.swift at commit
// a91669f. Copyright (c) 2026 Peter Steinberger. MIT License; see THIRD_PARTY_NOTICES.md.

import Foundation

/// Menu card wording: percentages, reset countdowns, pace lines and money.
public enum UsageFormatter {
    /// `88% left`; `<1% left` for a sliver above zero. Clamped to 0…100.
    public static func percentLeftText(usedPercent: Double) -> String {
        percentText(100 - usedPercent, suffix: "left")
    }

    /// `NN% <suffix>`, clamped to 0…100, `<1%` for values strictly between 0 and 1.
    public static func percentText(_ percent: Double, suffix: String) -> String {
        let clamped = min(100, max(0, percent))
        if clamped > 0, clamped < 1 { return "<1% \(suffix)" }
        return String(format: "%.0f%% %@", clamped, suffix)
    }

    /// `in 2d 3h`, `in 4h 12m`, `in 7m` or `now`; minutes are rounded up.
    public static func countdown(to date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds >= 1, let minutes = Int(exactly: ceil(seconds / 60)) else { return "now" }
        let totalMinutes = max(1, minutes)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let mins = totalMinutes % 60
        if days > 0 {
            if hours > 0 { return "in \(days)d \(hours)h" }
            if mins > 0 { return "in \(days)d \(mins)m" }
            return "in \(days)d"
        }
        if hours > 0 { return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h" }
        return "in \(totalMinutes)m"
    }

    /// `Resets in 4h 12m`, `Resets now`, `Not started` or `Reset unknown`.
    public static func resetText(_ reset: ResetState, now: Date) -> String {
        switch reset {
        case let .at(date):
            let countdown = countdown(to: date, now: now)
            return countdown == "now" ? "Resets now" : "Resets \(countdown)"
        case .notStarted:
            return "Not started"
        case .unknown:
            return "Reset unknown"
        }
    }

    /// `12% in reserve · Lasts until reset`, `5% in deficit · Runs out in 2d 3h`, `On pace`.
    /// The session uses "Projected empty" instead of "Runs out", as CodexBar does.
    public static func paceText(_ pace: UsagePace, isSession: Bool, now: Date) -> String {
        let left = paceLeftLabel(pace)
        guard let right = paceRightLabel(pace, isSession: isSession, now: now) else { return left }
        return "\(left) · \(right)"
    }

    static func paceLeftLabel(_ pace: UsagePace) -> String {
        let delta = Int(abs(pace.deltaPercent).rounded())
        guard delta != 0 else { return "On pace" }
        switch pace.stage {
        case .onTrack: return "On pace"
        case .slightlyAhead, .ahead, .farAhead: return "\(delta)% in deficit"
        case .slightlyBehind, .behind, .farBehind: return "\(delta)% in reserve"
        }
    }

    static func paceRightLabel(_ pace: UsagePace, isSession: Bool, now: Date) -> String? {
        if pace.willLastToReset { return "Lasts until reset" }
        guard let eta = pace.etaSeconds else { return nil }
        let countdown = countdown(to: now.addingTimeInterval(eta), now: now)
        if countdown == "now" { return isSession ? "Projected empty now" : "Runs out now" }
        let duration = String(countdown.dropFirst(3))
        return isSession ? "Projected empty in \(duration)" : "Runs out in \(duration)"
    }

    /// `$12.34` (en_US formatting, as CodexBar) when the currency is known, `12.34` otherwise.
    public static func money(_ value: Double, currency: String?) -> String {
        guard let currency else { return String(format: "%.2f", value) }
        return value.formatted(.currency(code: currency).locale(Locale(identifier: "en_US")))
    }
}
