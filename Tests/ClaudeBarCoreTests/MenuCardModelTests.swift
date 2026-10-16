@testable import ClaudeBarCore
import Foundation
import Testing

@Suite("UsageFormatter")
struct UsageFormatterTests {
    private let now = RefreshFixtures.t0

    private static let countdownCases: [(TimeInterval, String)] = [
        (0, "now"), (0.5, "now"), (30, "in 1m"), (59 * 60, "in 59m"), (3600, "in 1h"),
        (3660, "in 1h 1m"), (86400, "in 1d"), (86400 + 300, "in 1d 5m"),
        (2 * 86400 + 3 * 3600 + 300, "in 2d 3h"), (-60, "now"),
    ]

    @Test(
        "percent left is clamped, with <1% for a sliver",
        arguments: [(12.0, "88% left"), (0, "100% left"), (99.6, "<1% left"), (100, "0% left"), (130, "0% left")]
    )
    func percentLeft(used: Double, text: String) {
        #expect(UsageFormatter.percentLeftText(usedPercent: used) == text)
    }

    @Test(
        "countdown rounds minutes up and drops the smallest unit after days",
        arguments: countdownCases
    )
    func countdown(seconds: TimeInterval, text: String) {
        #expect(UsageFormatter.countdown(to: now.addingTimeInterval(seconds), now: now) == text)
    }

    @Test("reset wording per reset state")
    func resetWording() {
        #expect(UsageFormatter.resetText(.at(now.addingTimeInterval(4 * 3600 + 12 * 60)), now: now) == "Resets in 4h 12m")
        #expect(UsageFormatter.resetText(.at(now), now: now) == "Resets now")
        #expect(UsageFormatter.resetText(.notStarted, now: now) == "Not started")
        #expect(UsageFormatter.resetText(.unknown, now: now) == "Reset unknown")
    }

    @Test("money uses the currency when known and a bare amount otherwise")
    func money() {
        #expect(UsageFormatter.money(12.34, currency: "USD") == "$12.34")
        #expect(UsageFormatter.money(12.34, currency: nil) == "12.34")
    }
}

@Suite("MenuCardModel")
struct MenuCardModelTests {
    private typealias F = RefreshFixtures
    private let time: MenuCardModel.TimeFormat = { "t+\(Int($0.timeIntervalSince(RefreshFixtures.t0)))" }
    private static let halfWeekReset = ResetState.at(RefreshFixtures.t0.addingTimeInterval(UsageWindow.weeklyDuration / 2))

    private func model(_ status: RefreshStatus, now: Date = RefreshFixtures.t0) -> MenuCardModel {
        MenuCardModel(status: status, now: now, time: time)
    }

    private func usage(_ metric: MenuCardModel.Metric?) throws -> MenuCardModel.Usage {
        guard case let .usage(usage) = try #require(metric).content else {
            Issue.record("expected a usage row, got \(String(describing: metric))")
            throw CancellationError()
        }
        return usage
    }

    @Test("session and weekly stay visible as unavailable when never observed")
    func unavailableCoreMetrics() {
        let card = model(RefreshStatus())
        #expect(card.metrics.map(\.title) == ["Session", "Weekly"])
        #expect(card.metrics.map(\.content) == [.status("Unavailable"), .status("Unavailable")])
        #expect(card.extra == nil)
    }

    @Test("a fresh window with a future reset shows percent, reset, pace line and marker")
    func freshWithPace() throws {
        var status = RefreshStatus()
        let weekly = F.window(used: 60, reset: Self.halfWeekReset, duration: UsageWindow.weeklyDuration)
        status.weekly = MetricState(presentation: .fresh(.window(weekly)), allowsForecast: true)
        let row = try usage(model(status).metrics.first { $0.id == "weekly" })
        #expect(row.percentText == "40% left")
        #expect(row.percentLeft == 40)
        #expect(row.resetText == "Resets in 3d 12h")
        #expect(row.paceText == "10% in deficit · Runs out in 2d 8h")
        #expect(row.pacePercent == 50)
        #expect(row.paceOnTop == false)
        #expect(row.staleText == nil)
    }

    @Test("no pace when the coordinator does not allow a forecast, or when on track")
    func noPace() throws {
        var status = RefreshStatus()
        let weekly = F.window(used: 60, reset: Self.halfWeekReset, duration: UsageWindow.weeklyDuration)
        status.weekly = MetricState(presentation: .fresh(.window(weekly)), allowsForecast: false)
        let row = try usage(model(status).metrics[1])
        #expect(row.paceText == nil)
        #expect(row.pacePercent == nil)

        let onTrack = F.window(used: 51, reset: Self.halfWeekReset, duration: UsageWindow.weeklyDuration)
        status.weekly = MetricState(presentation: .fresh(.window(onTrack)), allowsForecast: true)
        let onTrackRow = try usage(model(status).metrics[1])
        #expect(onTrackRow.paceText?.hasPrefix("On pace") == true)
        #expect(onTrackRow.pacePercent == nil)
        #expect(onTrackRow.paceOnTop == false)
    }

    @Test("a stale value keeps its numbers, is marked with its timestamp and has no pace")
    func staleValue() throws {
        var status = RefreshStatus()
        let session = F.window(used: 12, reset: .at(F.t0.addingTimeInterval(3600)))
        status.session = MetricState(presentation: .stale(.window(session), lastSeenAt: F.t0), allowsForecast: false)
        let row = try usage(model(status, now: F.t0.addingTimeInterval(600)).metrics[0])
        #expect(row.percentText == "88% left")
        #expect(row.resetText == "Resets in 50m")
        #expect(row.staleText == "Stale · seen t+0")
        #expect(row.paceText == nil)
        #expect(row.pacePercent == nil)
    }

    @Test("waiting for fresh data shows no value, no renewed capacity and no pace")
    func waitingForFreshData() {
        var status = RefreshStatus()
        status.session = MetricState(presentation: .waitingForFreshData(lastSeenAt: F.t0), allowsForecast: false)
        #expect(model(status).metrics[0].content == .status("Reset passed · waiting for fresh data (seen t+0)"))
    }

    @Test("not-started and unknown resets have wording and no pace")
    func resetStates() throws {
        var status = RefreshStatus()
        status.session = MetricState(presentation: .fresh(.window(F.window(used: 0, reset: .notStarted))), allowsForecast: false)
        status.weekly = MetricState(presentation: .fresh(.window(F.window(used: 5, reset: .unknown))), allowsForecast: false)
        let card = model(status)
        #expect(try usage(card.metrics[0]).resetText == "Not started")
        #expect(try usage(card.metrics[1]).resetText == "Reset unknown")
        #expect(try usage(card.metrics[1]).paceText == nil)
    }

    @Test("scoped titles drop a trailing 'only' and fall back without a name")
    func scopedTitles() {
        #expect(MenuCardModel.scopedTitle("Sonnet only") == "Sonnet weekly")
        #expect(MenuCardModel.scopedTitle("Fable") == "Fable weekly")
        #expect(MenuCardModel.scopedTitle(nil) == "Model weekly")
        #expect(MenuCardModel.scopedTitle("  ") == "Model weekly")
    }

    @Test("ambiguous scoped rows show as ambiguous, without a value")
    func ambiguousScoped() {
        var status = RefreshStatus()
        status.scoped = [ScopedMetricState(key: "name:x", displayName: "X", isAmbiguous: true, state: .unavailable)]
        let card = model(status)
        #expect(card.metrics.count == 3)
        #expect(card.metrics[2] == MenuCardModel.Metric(
            id: "scoped:ambiguous:0:name:x", title: "X weekly", content: .status("Ambiguous: several limits share this name")
        ))
    }

    @Test("enabled extra usage with a cap shows spend, cap and percent; no reset, no pace")
    func extraWithCap() throws {
        var status = RefreshStatus()
        let extra = ExtraUsage(used: 12.5, cap: .amount(50), currency: "USD", utilization: nil)
        status.extra = MetricState(presentation: .fresh(.extra(.enabled(extra))), allowsForecast: false)
        let card = try #require(model(status).extra)
        #expect(card == MenuCardModel.Extra(
            title: "Extra usage", percentLeft: 75, spendText: "This month: $12.50 / $50.00",
            percentText: "25% used", noteText: nil, staleText: nil
        ))
    }

    @Test(
        "extra usage states without a usable cap or currency are distinct",
        arguments: [
            (ExtraUsage(used: 3, cap: .none, currency: "USD", utilization: nil), "This month: $3.00", "No monthly cap"),
            (ExtraUsage(used: 3, cap: .zero, currency: "USD", utilization: nil), "This month: $3.00", "Monthly cap is 0"),
            (ExtraUsage(used: 3, cap: .unknown, currency: "USD", utilization: nil), "This month: $3.00", "Monthly cap unknown"),
            (ExtraUsage(used: 3, cap: .amount(10), currency: nil, utilization: nil), "This month: 3.00 / 10.00", "currency unknown"),
            (ExtraUsage(used: nil, cap: .none, currency: "USD", utilization: nil), "This month: —", "No monthly cap"),
        ]
    )
    func extraStates(extra: ExtraUsage, spend: String, note: String) throws {
        var status = RefreshStatus()
        status.extra = MetricState(presentation: .fresh(.extra(.enabled(extra))), allowsForecast: false)
        let card = try #require(model(status).extra)
        #expect(card.spendText == spend)
        #expect(card.noteText == note)
    }

    @Test("explicitly disabled and never-observed extra usage are hidden")
    func extraHidden() {
        var status = RefreshStatus()
        status.extra = MetricState(presentation: .fresh(.extra(.disabled)), allowsForecast: false)
        #expect(model(status).extra == nil)
        status.extra = .unavailable
        #expect(model(status).extra == nil)
    }

    // MARK: - Through the coordinator

    @MainActor
    @Test("colliding scoped rows become ambiguous cards whose ids no other key can reproduce")
    func collidingScopedThroughCoordinator() async {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        let collide = ScopedWeeklyLimit(key: "id:x", displayName: "X", isActive: true, reading: .ambiguous)
        // Ordinary rows whose keys spell out the ambiguous ids of other schemes.
        let tricky = ["id:x#ambiguous-0", "ambiguous:0:id:x", "resolved:id:x"].map { key in
            ScopedWeeklyLimit(
                key: key, displayName: "Tricky", isActive: true,
                reading: .available(F.window(used: 10, duration: UsageWindow.weeklyDuration))
            )
        }
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 1, with: .success(F.snapshot(scoped: [collide, collide] + tricky)))

        let card = MenuCardModel(status: h.status, now: h.at(0), time: time)
        let scoped = Array(card.metrics.dropFirst(2))
        #expect(scoped.count == 5)
        #expect(Set(card.metrics.map(\.id)).count == card.metrics.count)
        #expect(scoped.map(\.id) == [
            "scoped:ambiguous:0:id:x", "scoped:ambiguous:1:id:x",
            "scoped:resolved:id:x#ambiguous-0", "scoped:resolved:ambiguous:0:id:x", "scoped:resolved:resolved:id:x",
        ])
        #expect(scoped.prefix(2).allSatisfy { $0.content == .status("Ambiguous: several limits share this name") })
    }

    @MainActor
    @Test("inactive scoped rows are shown; a known optional metric that goes missing stays visible as stale")
    func visibilityThroughCoordinator() async throws {
        let h = RefreshHarness(interval: .manual)
        defer { h.stop() }
        let extra = ExtraUsageState.enabled(ExtraUsage(used: 1, cap: .amount(10), currency: "USD", utilization: 10))
        let inactive = ScopedWeeklyLimit(
            key: "name:fable", displayName: "Fable", isActive: false,
            reading: .available(F.window(used: 30, duration: UsageWindow.weeklyDuration))
        )
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 1, with: .success(F.snapshot(scoped: [inactive], extra: extra)))

        var card = MenuCardModel(status: h.status, now: h.at(0), time: time)
        #expect(card.metrics.map(\.title) == ["Session", "Weekly", "Fable weekly"])
        #expect(try usage(card.metrics[2]).percentText == "70% left")
        #expect(card.extra?.staleText == nil)

        h.advance(to: 10)
        h.coordinator.trigger(.manualRefresh)
        await h.complete(call: 2, with: .success(F.snapshot(session: nil, scoped: [], extra: .unavailable)))

        card = MenuCardModel(status: h.status, now: h.at(10), time: time)
        #expect(card.metrics.map(\.title) == ["Session", "Weekly", "Fable weekly"])
        #expect(try usage(card.metrics[0]).staleText == "Stale · seen t+0")
        #expect(try usage(card.metrics[2]).staleText == "Stale · seen t+0")
        let staleExtra = try #require(card.extra)
        #expect(staleExtra.staleText == "Stale · seen t+0")
        #expect(staleExtra.spendText == "This month: $1.00 / $10.00")
    }
}
