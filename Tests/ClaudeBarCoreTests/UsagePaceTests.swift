@testable import ClaudeBarCore
import Foundation
import Testing

@Suite("UsagePace")
struct UsagePaceTests {
    private static let now = RefreshFixtures.t0
    private static let week = UsageWindow.weeklyDuration
    private static let session = UsageWindow.sessionDuration

    /// A window of `duration` with `elapsed` seconds gone at `now`.
    private static func window(
        used: Double, elapsed: TimeInterval, duration: TimeInterval = week
    ) -> UsageWindow {
        RefreshFixtures.window(used: used, reset: .at(now.addingTimeInterval(duration - elapsed)), duration: duration)
    }

    @Test("zero elapsed: on track at 0 % used, no pace once anything is used")
    func zeroElapsed() throws {
        let pace = try #require(UsagePace.linear(window: Self.window(used: 0, elapsed: 0), now: Self.now))
        #expect(pace.expectedUsedPercent == 0)
        #expect(pace.stage == .onTrack)
        #expect(pace.etaSeconds == nil)
        #expect(!pace.willLastToReset)
        #expect(UsagePace.linear(window: Self.window(used: 5, elapsed: 0), now: Self.now) == nil)
    }

    @Test("0 % used halfway: far behind, lasts until reset")
    func zeroUsed() throws {
        let pace = try #require(UsagePace.linear(window: Self.window(used: 0, elapsed: Self.week / 2), now: Self.now))
        #expect(pace.expectedUsedPercent == 50)
        #expect(pace.deltaPercent == -50)
        #expect(pace.stage == .farBehind)
        #expect(pace.willLastToReset)
        #expect(pace.etaSeconds == nil)
        #expect(UsageFormatter.paceText(pace, isSession: false, now: Self.now) == "50% in reserve · Lasts until reset")
    }

    @Test("100 % used: the raw pace runs out now, the card shows no pace")
    func fullyUsed() throws {
        let window = Self.window(used: 100, elapsed: Self.week / 2)
        let pace = try #require(UsagePace.linear(window: window, now: Self.now))
        #expect(pace.etaSeconds == 0)
        #expect(pace.stage == .farAhead)
        #expect(UsagePace.forCard(window: window, isSession: false, now: Self.now) == nil)
        #expect(UsagePace.forCard(window: window, isSession: true, now: Self.now) == nil)
    }

    @Test("a reset at or before now gives no pace")
    func pastReset() {
        for offset: TimeInterval in [0, -1, -3600] {
            let window = RefreshFixtures.window(
                used: 10, reset: .at(Self.now.addingTimeInterval(offset)), duration: Self.week
            )
            #expect(UsagePace.linear(window: window, now: Self.now) == nil)
        }
    }

    @Test("a reset further away than the window length is implausible and gives no pace")
    func farFutureReset() {
        let beyond = RefreshFixtures.window(
            used: 10, reset: .at(Self.now.addingTimeInterval(Self.week + 1)), duration: Self.week
        )
        #expect(UsagePace.linear(window: beyond, now: Self.now) == nil)
        let edge = RefreshFixtures.window(
            used: 0, reset: .at(Self.now.addingTimeInterval(Self.week)), duration: Self.week
        )
        #expect(UsagePace.linear(window: edge, now: Self.now) != nil)
    }

    @Test("unknown and not-started resets give no pace")
    func noResetDate() {
        for reset in [ResetState.unknown, .notStarted] {
            let window = RefreshFixtures.window(used: 0, reset: reset, duration: Self.week)
            #expect(UsagePace.linear(window: window, now: Self.now) == nil)
        }
    }

    @Test(
        "stage thresholds at |delta| 2 / 6 / 12 (inclusive)",
        arguments: [
            (50.0, UsagePace.Stage.onTrack),
            (52, .onTrack),
            (52.5, .slightlyAhead),
            (56, .slightlyAhead),
            (56.5, .ahead),
            (62, .ahead),
            (62.5, .farAhead),
            (48, .onTrack),
            (47.5, .slightlyBehind),
            (44, .slightlyBehind),
            (43.5, .behind),
            (38, .behind),
            (37.5, .farBehind),
        ]
    )
    func thresholds(used: Double, stage: UsagePace.Stage) throws {
        let pace = try #require(UsagePace.linear(window: Self.window(used: used, elapsed: Self.week / 2), now: Self.now))
        #expect(pace.expectedUsedPercent == 50)
        #expect(pace.stage == stage)
    }

    @Test("the 3 % elapsed guard applies to the session only")
    func sessionGuard() throws {
        let early = Self.window(used: 1, elapsed: 0.029 * Self.session, duration: Self.session)
        #expect(UsagePace.forCard(window: early, isSession: true, now: Self.now) == nil)
        #expect(UsagePace.forCard(window: early, isSession: false, now: Self.now) != nil)

        let later = Self.window(used: 1, elapsed: 0.031 * Self.session, duration: Self.session)
        #expect(UsagePace.forCard(window: later, isSession: true, now: Self.now) != nil)

        let earlyWeek = Self.window(used: 1, elapsed: 0.01 * Self.week)
        #expect(UsagePace.forCard(window: earlyWeek, isSession: false, now: Self.now) != nil)
    }

    @Test("ETA wording: weekly runs out, session is projected empty")
    func etaWording() throws {
        let weekly = try #require(UsagePace.linear(window: Self.window(used: 60, elapsed: Self.week / 2), now: Self.now))
        #expect(weekly.etaSeconds == 201_600)
        #expect(UsageFormatter.paceText(weekly, isSession: false, now: Self.now) == "10% in deficit · Runs out in 2d 8h")

        let session = try #require(UsagePace.linear(
            window: Self.window(used: 60, elapsed: Self.session / 2, duration: Self.session), now: Self.now
        ))
        #expect(UsageFormatter.paceText(session, isSession: true, now: Self.now)
            == "10% in deficit · Projected empty in 1h 40m")
    }

    @Test("on-pace wording when the rounded delta is 0 or within the on-track band")
    func onPaceWording() throws {
        let exact = try #require(UsagePace.linear(window: Self.window(used: 50, elapsed: Self.week / 2), now: Self.now))
        #expect(UsageFormatter.paceText(exact, isSession: false, now: Self.now) == "On pace · Lasts until reset")
        let band = try #require(UsagePace.linear(window: Self.window(used: 51.6, elapsed: Self.week / 2), now: Self.now))
        #expect(band.stage == .onTrack)
        #expect(UsageFormatter.paceText(band, isSession: false, now: Self.now).hasPrefix("On pace"))
    }
}
