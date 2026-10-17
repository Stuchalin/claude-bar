@testable import ClaudeBarCore
import Foundation
import Testing

private let t0 = RefreshFixtures.t0
private let hour: TimeInterval = 3600
private let day = 24 * hour
private let session = UsageWindow.sessionDuration
private let week = UsageWindow.weeklyDuration
private let source = "https://a.proxy.example.com"

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Builds runs of one stream with sequential ids.
private struct Runs {
    var stream: Int64 = 1
    var runs: [HistoryRun] = []

    /// A run seen from `first` to `last` (seconds from t0); `closed` defaults to `last` for a closed run.
    mutating func add(
        _ first: TimeInterval, _ last: TimeInterval, used: Double, reset: ResetState,
        close: HistoryCloseReason?, closedAt: TimeInterval? = nil
    ) {
        runs.append(HistoryRun(
            id: Int64(runs.count + 1), streamID: stream, firstSeenAt: at(first), lastSeenAt: at(last),
            usedPercent: used, reset: reset, closedAt: close == nil ? nil : at(closedAt ?? last), closeReason: close
        ))
    }
}

private func brk(_ seconds: TimeInterval, stream: Int64?, reason: HistoryBreakReason = .failure) -> HistoryBreak {
    HistoryBreak(id: Int64(seconds), source: source, at: at(seconds), reason: reason, streamID: stream)
}

private func chart(_ state: BurndownChartState) throws -> BurndownChartModel {
    guard case let .chart(chart) = state else {
        Issue.record("expected a chart, got \(state)")
        throw CancellationError()
    }
    return chart
}

@Suite("Burn-down chart model")
struct BurndownChartModelTests {
    /// Session window ending 2 h after t0, so it started 3 h before.
    private let reset = ResetState.at(at(2 * hour))

    @Test("only runs of the current window are plotted, by their observed endpoints")
    func currentWindowFiltering() throws {
        var r = Runs()
        // Previous window, ended by a reset.
        r.add(-6 * hour, -4 * hour, used: 70, reset: .at(at(-3 * hour)), close: .reset, closedAt: -2.5 * hour)
        // Current window: 10 % held for 30 min, then 20 % until now.
        r.add(-2.5 * hour, -2 * hour, used: 10, reset: reset, close: .changed, closedAt: -1.9 * hour)
        r.add(-1.9 * hour, 0, used: 20, reset: .at(at(2 * hour + 60)), close: nil)

        let model = try chart(BurndownChartModel.make(runs: r.runs, breaks: [], duration: session, now: t0))

        #expect(model.start == at(-3 * hour + 60))
        #expect(model.reset == at(2 * hour + 60))
        #expect(model.ideal == [
            .init(date: model.start, remainingPercent: 100), .init(date: model.reset, remainingPercent: 0),
        ])
        #expect(model.segments.count == 1)
        #expect(model.segments[0].samples == [
            .init(date: at(-2.5 * hour), remainingPercent: 90), .init(date: at(-2 * hour), remainingPercent: 90),
            .init(date: at(-1.9 * hour), remainingPercent: 80), .init(date: t0, remainingPercent: 80),
        ])
        #expect(model.latest == .init(date: t0, remainingPercent: 80))
    }

    @Test(
        "a run ended by a failure, a missing metric, a source change, a gap or a reset starts a new piece",
        arguments: [HistoryCloseReason.failure, .missing, .source, .gap, .reset]
    )
    func splitsAtDiscontinuities(reason: HistoryCloseReason) throws {
        var r = Runs()
        r.add(-2 * hour, -1.5 * hour, used: 10, reset: reset, close: reason)
        r.add(-1 * hour, 0, used: 15, reset: reset, close: nil)

        let model = try chart(BurndownChartModel.make(runs: r.runs, breaks: [], duration: session, now: t0))

        #expect(model.segments.map(\.samples.count) == [2, 2])
    }

    @Test("a break of the source or of this stream splits even a changed-value join; other streams' do not")
    func splitsAtBreaks() throws {
        func pieces(_ breaks: [HistoryBreak]) throws -> Int {
            var r = Runs()
            r.add(-2 * hour, -1.5 * hour, used: 10, reset: reset, close: .changed, closedAt: -1 * hour)
            r.add(-1 * hour, 0, used: 15, reset: reset, close: nil)
            return try chart(BurndownChartModel.make(runs: r.runs, breaks: breaks, duration: session, now: t0))
                .segments.count
        }
        #expect(try pieces([]) == 1)
        #expect(try pieces([brk(-1.2 * hour, stream: nil)]) == 2)
        #expect(try pieces([brk(-1.2 * hour, stream: 1, reason: .missing)]) == 2)
        #expect(try pieces([brk(-1.2 * hour, stream: 2, reason: .missing)]) == 1)
        #expect(try pieces([brk(-1.8 * hour, stream: nil)]) == 1, "a break inside the first run's span is not between runs")
    }

    @Test("an isolated single observation is its own one-sample piece")
    func singleSample() throws {
        var r = Runs()
        r.add(-1 * hour, -1 * hour, used: 5, reset: reset, close: .failure)
        r.add(-0.5 * hour, 0, used: 8, reset: reset, close: nil)

        let model = try chart(BurndownChartModel.make(runs: r.runs, breaks: [], duration: session, now: t0))

        #expect(model.segments.map(\.samples.count) == [1, 2])
    }

    @Test("a reset with no observation of the new window yet shows no current window")
    func resetPassed() {
        var r = Runs()
        r.add(-4 * hour, -1 * hour, used: 90, reset: .at(at(-10)), close: nil)
        #expect(BurndownChartModel.make(runs: r.runs, breaks: [], duration: session, now: t0) == .noCurrentWindow)
    }

    @Test("unknown and not-started resets have no current window; no runs means no observations")
    func allMissing() {
        #expect(BurndownChartModel.make(runs: [], breaks: [], duration: session, now: t0) == .noObservations)
        for state in [ResetState.unknown, .notStarted] {
            var r = Runs()
            r.add(-1 * hour, 0, used: 0, reset: state, close: nil)
            #expect(BurndownChartModel.make(runs: r.runs, breaks: [], duration: session, now: t0) == .noCurrentWindow)
        }
    }

    @Test("remaining share is clamped to 0…100")
    func clamped() throws {
        var r = Runs()
        r.add(-1 * hour, 0, used: 130, reset: reset, close: nil)
        let model = try chart(BurndownChartModel.make(runs: r.runs, breaks: [], duration: session, now: t0))
        #expect(model.latest.remainingPercent == 0)
    }

    @Test("a dense week is downsampled per time bucket, keeping each piece's endpoints and peaks")
    func downsampling() throws {
        let weekReset = ResetState.at(at(1 * day))
        var r = Runs()
        // One-minute changes for 6 days: 8640 runs, 17 280 samples, one continuous piece.
        let count = 6 * 24 * 60
        for minute in 0..<count {
            let first = -6 * day + Double(minute) * 60
            let isLast = minute == count - 1
            r.add(first, first + 30, used: Double(minute) / Double(count) * 90, reset: weekReset,
                  close: isLast ? nil : .changed, closedAt: first + 60)
        }
        let model = try chart(BurndownChartModel.make(runs: r.runs, breaks: [], duration: week, now: t0))

        #expect(model.segments.count == 1)
        let samples = model.segments[0].samples
        #expect(samples.count <= BurndownChartModel.maxPoints + 3)
        #expect(samples.count > BurndownChartModel.maxPoints / 2)
        #expect(samples.first?.date == at(-6 * day))
        #expect(samples.last?.date == r.runs.last?.lastSeenAt)
        #expect(samples.map(\.date) == samples.map(\.date).sorted())
        #expect(samples.map(\.remainingPercent).min() == model.latest.remainingPercent)
    }

    @Test("downsampling leaves small inputs untouched and keeps every piece's endpoints")
    func downsamplingPieces() {
        typealias S = BurndownChartModel.Sample
        let pieces: [[S]] = [
            (0..<50).map { S(date: at(Double($0) * 60), remainingPercent: 100 - Double($0)) },
            (0..<50).map { S(date: at(10 * hour + Double($0) * 60), remainingPercent: 50 - Double($0) / 2) },
        ]
        #expect(BurndownChartModel.downsample(pieces, start: t0, end: at(day), maxPoints: 100) == pieces)

        let thinned = BurndownChartModel.downsample(pieces, start: t0, end: at(day), maxPoints: 10)
        #expect(thinned.count == 2)
        for (piece, original) in zip(thinned, pieces) {
            #expect(piece.first == original.first)
            #expect(piece.last == original.last)
            #expect(piece.count < original.count)
        }
    }
}

@Suite("Peak chart model")
struct PeakChartModelTests {
    /// A closed window rising to `peak`, ended by the reset at `resetHours` from t0.
    private func window(_ r: inout Runs, resetHours: Double, peak: Double, duration: TimeInterval = session) {
        let reset = resetHours * hour
        r.add(reset - duration * 0.8, reset - duration * 0.5, used: peak / 2, reset: .at(at(reset)), close: .changed,
              closedAt: reset - duration * 0.4)
        r.add(reset - duration * 0.4, reset - duration * 0.1, used: peak, reset: .at(at(reset)), close: .reset,
              closedAt: reset)
    }

    @Test("each observed past window shows its observed peak; the current window is excluded")
    func multiplePastWindows() {
        var r = Runs()
        window(&r, resetHours: -10, peak: 40)
        window(&r, resetHours: -5, peak: 85)
        window(&r, resetHours: 0, peak: 60)
        window(&r, resetHours: 5, peak: 20) // current: resets after now

        let model = PeakChartModel.make(runs: r.runs, duration: session, now: t0)

        #expect(model.slots.allSatisfy { $0.isObserved })
        #expect(model.observedWindows.map(\.peakUsedPercent) == [40, 85, 60])
        #expect(model.observedWindows.map(\.resetAt) == [at(-10 * hour), at(-5 * hour), t0])
        #expect(model.observedWindows[0].firstSeenAt == at(-14 * hour))
    }

    @Test("resets within the store's tolerance belong to one window")
    func resetTolerance() {
        var r = Runs()
        r.add(-4 * hour, -3 * hour, used: 30, reset: .at(at(-1 * hour)), close: .changed)
        r.add(-3 * hour, -2 * hour, used: 50, reset: .at(at(-1 * hour + 90)), close: .reset)
        let model = PeakChartModel.make(runs: r.runs, duration: session, now: t0)
        #expect(model.observedWindows.map(\.peakUsedPercent) == [50])
    }

    @Test("a stretch without observed windows is one unobserved slot with no value, never 0 %")
    func unobservedWindows() {
        var r = Runs()
        window(&r, resetHours: -30, peak: 40)
        window(&r, resetHours: -25, peak: 50) // adjacent: no slot between
        window(&r, resetHours: -5, peak: 70) // 20 h later: unobserved stretch

        let model = PeakChartModel.make(runs: r.runs, duration: session, now: t0)

        #expect(model.slots == [
            .observed(model.observedWindows[0]),
            .observed(model.observedWindows[1]),
            .unobserved(from: at(-25 * hour), to: at(-10 * hour)),
            .observed(model.observedWindows[2]),
        ])
        #expect(PeakChartModel.detailText(model.slots[2], date: { "t\(Int($0.timeIntervalSince(t0) / hour))" })
            == "t-25 – t-10: not observed")
    }

    @Test("runs without an observed reset boundary make no window; no runs make no slots")
    func allMissing() {
        #expect(PeakChartModel.make(runs: [], duration: session, now: t0).slots.isEmpty)
        var r = Runs()
        r.add(-10 * hour, -9 * hour, used: 30, reset: .unknown, close: .failure)
        r.add(-8 * hour, -7 * hour, used: 0, reset: .notStarted, close: .reset)
        #expect(PeakChartModel.make(runs: r.runs, duration: session, now: t0).slots.isEmpty)
    }

    @Test("only the newest slots are kept, never starting with an unobserved one")
    func slotLimit() {
        var r = Runs()
        for index in 0..<40 { window(&r, resetHours: -Double(index + 1) * 5, peak: Double(index)) }
        let model = PeakChartModel.make(runs: r.runs, duration: session, now: t0)
        #expect(model.slots.count == PeakChartModel.maxSlots)
        #expect(model.observedWindows.last?.peakUsedPercent == 0)
        #expect(model.observedWindows.first?.peakUsedPercent == Double(PeakChartModel.maxSlots - 1))

        var gapped = Runs()
        window(&gapped, resetHours: -100, peak: 10)
        window(&gapped, resetHours: -50, peak: 20)
        window(&gapped, resetHours: -45, peak: 30)
        let trimmed = PeakChartModel.make(runs: gapped.runs, duration: session, now: t0, maxSlots: 3)
        #expect(trimmed.slots.first?.isObserved == true)
        #expect(trimmed.observedWindows.map(\.peakUsedPercent) == [20, 30])
    }

    @Test("the caption calls a value an observed peak")
    func caption() {
        var r = Runs()
        window(&r, resetHours: -1, peak: 87)
        let model = PeakChartModel.make(runs: r.runs, duration: session, now: t0)
        #expect(PeakChartModel.detailText(model.slots.last, date: { _ in "Oct 16" }) == "Ended Oct 16: observed peak 87% used")
        #expect(PeakChartModel.detailText(nil, date: { _ in "" }) == "No past windows observed yet")
    }
}

@Suite("Usage history charts")
struct UsageHistoryChartsTests {
    @Test("series are per stream of the requested source, Session and Weekly first, with titles")
    func seriesOfSource() async throws {
        let reader = InMemoryUsageHistory(
            streams: [
                HistoryStream(id: 1, source: source, metric: .scoped, modelKey: "name:Sonnet"),
                HistoryStream(id: 2, source: source, metric: .weekly, modelKey: ""),
                HistoryStream(id: 3, source: "https://b.proxy.example.com", metric: .session, modelKey: ""),
                HistoryStream(id: 4, source: source, metric: .session, modelKey: ""),
                HistoryStream(id: 5, source: source, metric: .scoped, modelKey: "id:claude-x"),
            ],
            runs: [],
            breaks: []
        )
        let charts = try await UsageHistoryCharts.load(
            from: reader, source: source, scopedNames: ["id:claude-x": "Fable only"], now: t0
        )
        #expect(charts.series.map(\.id) == ["session", "weekly", "scoped:name:Sonnet", "scoped:id:claude-x"])
        #expect(charts.series.map(\.title) == ["Session", "Weekly", "Sonnet weekly", "Fable weekly"])
        #expect(charts.series.allSatisfy { $0.burndown == .noObservations && $0.peaks.slots.isEmpty })
    }

    @Test("scoped titles without a current name come from the key")
    func titles() {
        #expect(UsageHistoryCharts.title(metric: .scoped, modelKey: "legacy:seven_day_opus", scopedNames: [:]) == "Opus weekly")
        #expect(UsageHistoryCharts.title(metric: .scoped, modelKey: "legacy:other", scopedNames: [:]) == "Model weekly")
        #expect(UsageHistoryCharts.title(metric: .scoped, modelKey: "id:m-1", scopedNames: [:]) == "m-1 weekly")
    }

    @Test("charts read from a real store split at a recorded failure", .timeLimit(.minutes(1)))
    func endToEndWithStore() async throws {
        typealias F = RefreshFixtures
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        defer { store.close() }
        let source = F.endpointA.normalizedString
        let reset = ResetState.at(at(2 * hour))
        func observe(_ seconds: TimeInterval, _ used: Double) {
            store.record(.observed(
                source: source, at: at(seconds), interval: .oneMinute,
                snapshot: F.snapshot(session: F.window(used: used, reset: reset), weekly: nil)
            ))
        }
        observe(-50 * 60, 10)
        observe(-49 * 60, 12)
        store.record(.failed(source: source, at: at(-48 * 60)))
        observe(-47 * 60, 12)
        observe(-46 * 60, 13)
        await store.flush()

        let charts = try await UsageHistoryCharts.load(from: store, source: source, now: t0)
        let series = try #require(charts.series.first)
        let model = try chart(series.burndown)
        #expect(charts.series.map(\.id) == ["session"])
        #expect(model.segments.map { $0.samples.map(\.remainingPercent) } == [[90, 88], [88, 87]])
    }
}

@Suite("Usage history fixtures and menu model")
@MainActor
struct UsageHistoryFixtureTests {
    @Test("fixtures populate both charts for every series, with a break or gap and an unobserved stretch")
    func fixturesPopulateCharts() async throws {
        let charts = try await UsageHistoryCharts.load(
            from: UsageHistoryFixtures.make(now: t0), source: UsageHistoryFixtures.source, now: t0
        )
        #expect(charts.series.map(\.title) == ["Session", "Weekly", "Sonnet weekly"])
        for series in charts.series {
            let model = try chart(series.burndown)
            #expect(!model.segments.isEmpty)
            #expect(series.peaks.observedWindows.count >= 5)
        }
        #expect(try chart(charts.series[0].burndown).segments.count == 2)
        #expect(try chart(charts.series[1].burndown).segments.count == 2)
        #expect(charts.series[0].peaks.slots.contains { !$0.isObserved })
        #expect(charts.series[1].peaks.slots.contains { !$0.isObserved })
    }

    @Test("fixture mode is on only with the launch argument, never from the executable path")
    func launchArgument() {
        #expect(UsageHistoryFixtures.isRequested(arguments: ["/x/ClaudeBar", "--history-fixtures"]))
        #expect(!UsageHistoryFixtures.isRequested(arguments: ["/x/ClaudeBar"]))
        #expect(!UsageHistoryFixtures.isRequested(arguments: ["--history-fixtures"]))
        #expect(!UsageHistoryFixtures.source.hasPrefix("http"))
    }

    @Test("the menu model loads, reports a missing source and an unavailable store, and falls back in selection")
    func menuModel() async throws {
        let model = UsageHistoryMenuModel(reader: UsageHistoryFixtures.make(now: t0), isFixture: true, now: { t0 })
        model.reload(source: nil)
        #expect(model.state == .notConfigured)

        model.reload(source: UsageHistoryFixtures.source)
        #expect(model.state == .loading)
        await model.waitForLoad()
        #expect(model.selectedSeries?.id == "session")
        model.selectedSeriesID = "weekly"
        #expect(model.selectedSeries?.id == "weekly")
        model.selectedSeriesID = "scoped:gone"
        #expect(model.selectedSeries?.id == "session")

        let temp = TempHistoryDirectory()
        try temp.seed(Data("not a database at all".utf8))
        let store = temp.makeStore()
        defer { store.close() }
        let failing = UsageHistoryMenuModel(reader: store, isFixture: false, now: { t0 })
        failing.reload(source: source)
        await failing.waitForLoad()
        #expect(failing.state == .failed("History is unavailable."))
    }
}

@Suite("Usage history loader bounds")
struct UsageHistoryLoaderBoundsTests {
    private func load(_ r: Runs) async throws -> UsageHistoryCharts.Series {
        let reader = InMemoryUsageHistory(
            streams: [HistoryStream(id: 1, source: source, metric: .session, modelKey: "")], runs: r.runs, breaks: []
        )
        return try #require(try await UsageHistoryCharts.load(from: reader, source: source, now: t0).series.first)
    }

    @Test("a window straddling the first read's start keeps its full runs, so its peak is complete")
    func cutoffBoundary() async throws {
        // 30 session window lengths = 150 h; this window ends at −148 h and peaked at −152 h.
        var r = Runs()
        r.add(-152 * hour, -151 * hour, used: 90, reset: .at(at(-148 * hour)), close: .changed, closedAt: -149 * hour)
        r.add(-149 * hour, -148.5 * hour, used: 40, reset: .at(at(-148 * hour)), close: .reset, closedAt: -148 * hour)
        let series = try await load(r)
        #expect(series.peaks.observedWindows.map(\.peakUsedPercent) == [90])
    }

    @Test("with more than 30 past windows the oldest shown one is complete and older ones are dropped")
    func fullSlotsComplete() async throws {
        var r = Runs()
        for k in 1...31 {
            let reset = -Double(k) * 5 * hour
            r.add(reset - 4.5 * hour, reset - 4.4 * hour, used: k == 30 ? 95 : 50, reset: .at(at(reset)),
                  close: .changed, closedAt: reset - 1 * hour)
            r.add(reset - 1 * hour, reset - 0.5 * hour, used: 40, reset: .at(at(reset)), close: .reset, closedAt: reset)
        }
        let peaks = try await load(r).peaks
        #expect(peaks.observedWindows.count == PeakChartModel.maxSlots)
        #expect(peaks.observedWindows.first?.resetAt == at(-150 * hour))
        #expect(peaks.observedWindows.first?.peakUsedPercent == 95)
    }

    @Test("history older than 30 window lengths after a long pause still shows its windows")
    func sparseHistory() async throws {
        var r = Runs()
        for reset in [-400.0, -395] {
            r.add((reset - 3) * hour, (reset - 1) * hour, used: 70, reset: .at(at(reset * hour)), close: .reset,
                  closedAt: reset * hour)
        }
        let series = try await load(r)
        #expect(series.peaks.observedWindows.map(\.resetAt) == [at(-400 * hour), at(-395 * hour)])
        #expect(series.burndown == .noCurrentWindow)
    }
}

/// Wraps fixed history; while gated, each `streams()` call waits until the test releases it.
private final class GatedHistory: UsageHistoryReading, @unchecked Sendable {
    let base: InMemoryUsageHistory
    private let lock = NSLock()
    private var gated = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ base: InMemoryUsageHistory) { self.base = base }

    var waitingCount: Int { lock.withLock { waiting.count } }
    func setGated(_ value: Bool) { lock.withLock { gated = value } }

    /// Releases the call that started waiting `index`-th among those still waiting.
    func release(_ index: Int) {
        let continuation = lock.withLock { waiting.remove(at: index) }
        continuation.resume()
    }

    func waitUntil(waiting count: Int) async {
        for _ in 0..<10_000 where waitingCount < count { await Task.yield() }
    }

    func streams() async throws -> [HistoryStream] {
        if lock.withLock({ gated }) {
            await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
        }
        return try await base.streams()
    }

    func runs(streamID: Int64, from: Date, to: Date) async throws -> [HistoryRun] {
        try await base.runs(streamID: streamID, from: from, to: to)
    }

    func resetDates(streamID: Int64) async throws -> [Date] {
        try await base.resetDates(streamID: streamID)
    }

    func runs(streamID: Int64, resetsFrom: Date) async throws -> [HistoryRun] {
        try await base.runs(streamID: streamID, resetsFrom: resetsFrom)
    }

    func breaks(source: String, from: Date, to: Date) async throws -> [HistoryBreak] {
        try await base.breaks(source: source, from: from, to: to)
    }
}

@Suite("Usage history menu model sources", .timeLimit(.minutes(1)))
@MainActor
struct UsageHistoryMenuModelSourceTests {
    private let sourceA = UsageHistoryFixtures.source
    private let sourceB = source

    private func makeReader() -> GatedHistory {
        let fixtures = UsageHistoryFixtures.make(now: t0)
        return GatedHistory(InMemoryUsageHistory(
            streams: fixtures.allStreams + [HistoryStream(id: 99, source: sourceB, metric: .weekly, modelKey: "")],
            runs: fixtures.allRuns,
            breaks: fixtures.allBreaks
        ))
    }

    private func seriesIDs(_ state: UsageHistoryMenuModel.State) -> [String]? {
        if case let .loaded(charts) = state { charts.series.map(\.id) } else { nil }
    }

    @Test("switching source hides the old charts and selection at once; the same source keeps them")
    func switchHidesOldSource() async {
        let reader = makeReader()
        let model = UsageHistoryMenuModel(reader: reader, isFixture: false, now: { t0 })
        model.reload(source: sourceA)
        await model.waitForLoad()
        model.selectedSeriesID = "weekly"

        reader.setGated(true)
        model.reload(source: sourceA)
        #expect(seriesIDs(model.state) == ["session", "weekly", "scoped:name:Sonnet"], "same source keeps its charts")
        await reader.waitUntil(waiting: 1)
        reader.release(0)
        await model.waitForLoad()

        model.reload(source: sourceB)
        #expect(model.state == .loading)
        #expect(model.selectedSeries == nil)
        #expect(model.selectedSeriesID == nil)
        await reader.waitUntil(waiting: 1)
        reader.release(0)
        await model.waitForLoad()
        #expect(seriesIDs(model.state) == ["weekly"])

        model.reload(source: nil)
        #expect(model.state == .notConfigured)
    }

    @Test("a late result for the old source is never published")
    func lateOldResultDiscarded() async {
        let reader = makeReader()
        reader.setGated(true)
        let model = UsageHistoryMenuModel(reader: reader, isFixture: false, now: { t0 })
        model.reload(source: sourceA)
        await reader.waitUntil(waiting: 1)
        model.reload(source: sourceB)
        await reader.waitUntil(waiting: 2)

        reader.release(1) // B
        await model.waitForLoad()
        #expect(seriesIDs(model.state) == ["weekly"])

        reader.release(0) // A, late
        await model.waitForAllLoads()
        #expect(seriesIDs(model.state) == ["weekly"])
    }
}

extension UsageHistoryLoaderBoundsTests {
    @Test("a reset cluster straddling the read start is judged as one window, never split by run")
    func clusterAtBoundary() async throws {
        // Two runs of one window (resets 90 s apart): the 90 % run's window starts before the
        // first read (−150 h), plus 29 newer windows. Peak must come from the whole cluster.
        var r = Runs()
        r.add(-149 * hour, -149 * hour, used: 90, reset: .at(at(-145 * hour + 60)), close: .changed, closedAt: -149 * hour + 1)
        r.add(-148 * hour, -148 * hour, used: 40, reset: .at(at(-145 * hour + 150)), close: .changed, closedAt: -148 * hour + 1)
        for k in 0..<29 {
            let reset = Double(-140 + 5 * k) * hour
            r.add(reset - hour, reset - hour, used: 50, reset: .at(at(reset)), close: .changed, closedAt: reset - hour + 1)
        }
        let full = PeakChartModel.make(runs: r.runs, duration: session, now: t0)
        let peaks = try await load(r).peaks
        #expect(full.observedWindows.first?.peakUsedPercent == 90)
        #expect(peaks == full)
        #expect(peaks.observedWindows.count == PeakChartModel.maxSlots)
        #expect(peaks.observedWindows.first?.peakUsedPercent == 90)
    }
}

extension UsageHistoryLoaderBoundsTests {
    /// The reviewer's case: one window observed earlier than `reset − duration`, plus 29 newer ones.
    private static func earlyObservationRuns() -> Runs {
        var r = Runs()
        r.add(-151 * hour, -151 * hour, used: 90, reset: .at(at(-145 * hour + 150)), close: .changed, closedAt: -151 * hour + 1)
        r.add(-148 * hour, -148 * hour, used: 40, reset: .at(at(-145 * hour + 150)), close: .changed, closedAt: -148 * hour + 1)
        for k in 0..<29 {
            let reset = Double(-140 + 5 * k) * hour
            r.add(reset - hour, reset - hour, used: 50, reset: .at(at(reset)), close: .changed, closedAt: reset - hour + 1)
        }
        return r
    }

    @Test("runs of an included window are read by reset, even when observed before reset − duration")
    func observationBeforeWindowStart() async throws {
        let r = Self.earlyObservationRuns()
        let full = PeakChartModel.make(runs: r.runs, duration: session, now: t0)
        let peaks = try await load(r).peaks
        #expect(full.observedWindows.first?.peakUsedPercent == 90)
        #expect(peaks == full)
    }

    @Test("only the newest 30 past windows and later ones are read")
    func readsNewestWindowsOnly() async throws {
        var r = Runs()
        for k in 1...40 {
            let reset = -Double(k) * 5 * hour
            r.add(reset - hour, reset - hour, used: Double(k), reset: .at(at(reset)), close: .reset, closedAt: reset)
        }
        r.add(-1 * hour, 0, used: 7, reset: .at(at(1 * hour)), close: nil)
        r.add(-50 * hour, -49 * hour, used: 99, reset: .unknown, close: .failure)
        let reader = InMemoryUsageHistory(
            streams: [HistoryStream(id: 1, source: source, metric: .session, modelKey: "")], runs: r.runs, breaks: []
        )
        let runs = try await UsageHistoryCharts.peakRuns(reader: reader, streamID: 1, now: t0)
        #expect(Set(runs.map(\.usedPercent)) == Set((1...30).map(Double.init) + [7]))
    }

    @Test("the store reads runs by reset regardless of when they were observed", .timeLimit(.minutes(1)))
    func storeReadsByReset() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        defer { store.close() }
        let source = RefreshFixtures.endpointA.normalizedString
        func observe(_ seconds: TimeInterval, _ used: Double, reset: TimeInterval) {
            store.record(.observed(
                source: source, at: at(seconds), interval: .oneMinute,
                snapshot: RefreshFixtures.snapshot(session: RefreshFixtures.window(used: used, reset: .at(at(reset))), weekly: nil)
            ))
        }
        observe(-151 * hour, 90, reset: -145 * hour + 150)
        observe(-148 * hour, 40, reset: -145 * hour + 150)
        for k in 0..<29 {
            let reset = Double(-140 + 5 * k) * hour
            observe(reset - hour, 50, reset: reset)
        }
        await store.flush()

        #expect(try await store.resetDates(streamID: 1).count == 30)
        #expect(try await store.runs(streamID: 1, resetsFrom: at(-146 * hour)).count == 31)
        let charts = try await UsageHistoryCharts.load(from: store, source: source, now: t0)
        let peaks = try #require(charts.series.first).peaks
        #expect(peaks.observedWindows.count == PeakChartModel.maxSlots)
        #expect(peaks.observedWindows.first?.peakUsedPercent == 90)
    }
}
