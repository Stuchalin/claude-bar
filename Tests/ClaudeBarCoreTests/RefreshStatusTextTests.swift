@testable import ClaudeBarCore
import Foundation
import Testing

@Suite("RefreshStatusText")
struct RefreshStatusTextTests {
    private typealias F = RefreshFixtures
    private let time: RefreshStatusText.TimeFormat = { date in
        "t+\(Int(date.timeIntervalSince(RefreshFixtures.t0)))"
    }

    @Test("remaining percent is rounded and clamped")
    func remaining() {
        #expect(RefreshStatusText.remainingPercent(F.window(used: 12.4)) == 88)
        #expect(RefreshStatusText.remainingPercent(F.window(used: 0)) == 100)
        #expect(RefreshStatusText.remainingPercent(F.window(used: 130)) == 0)
    }

    @Test("title shows remaining percent, a dash when unknown and a star when stale")
    func title() {
        var status = RefreshStatus()
        #expect(RefreshStatusText.statusTitle(status) == "S — · W —")
        status.session = MetricState(presentation: .fresh(.window(F.window(used: 12))), allowsForecast: true)
        status.weekly = MetricState(presentation: .stale(.window(F.window(used: 1)), lastSeenAt: F.t0), allowsForecast: false)
        #expect(RefreshStatusText.statusTitle(status) == "S 88% · W 99%*")
    }

    @Test("metric lines")
    func metricLines() {
        let window = F.window(used: 12, reset: .at(F.t0.addingTimeInterval(60)))
        let fresh = MetricState(presentation: .fresh(.window(window)), allowsForecast: true)
        #expect(RefreshStatusText.metricLine(title: "Session", state: fresh, time: time) == "Session: 88% left · resets t+60")
        let stale = MetricState(presentation: .stale(.window(window), lastSeenAt: F.t0), allowsForecast: false)
        #expect(RefreshStatusText.metricLine(title: "Session", state: stale, time: time)
            == "Session: 88% left · resets t+60 (stale, seen t+0)")
        let waiting = MetricState(presentation: .waitingForFreshData(lastSeenAt: F.t0), allowsForecast: false)
        #expect(RefreshStatusText.metricLine(title: "Weekly", state: waiting, time: time)
            == "Weekly: reset passed, waiting for fresh data (seen t+0)")
        #expect(RefreshStatusText.metricLine(title: "Weekly", state: .unavailable, time: time) == "Weekly: unavailable")
    }

    @Test("updated line and timing wording per mode")
    func updatedAndTiming() {
        var status = RefreshStatus()
        #expect(RefreshStatusText.updatedLine(status, time: time) == "Set the proxy URL and secret in Settings.")
        status.isConfigured = true
        #expect(RefreshStatusText.updatedLine(status, time: time) == "Not updated yet")
        status.lastSuccessAt = F.t0
        #expect(RefreshStatusText.updatedLine(status, time: time) == "Updated t+0")
        status.isStale = true
        #expect(RefreshStatusText.updatedLine(status, time: time) == "Stale — last updated t+0")

        #expect(RefreshStatusText.timingLine(status, time: time) == nil)
        status.nextAttemptAt = F.t0.addingTimeInterval(300)
        #expect(RefreshStatusText.timingLine(status, time: time) == "Next attempt at t+300")
        status.nextAttemptAt = nil
        status.retryAvailableAt = F.t0.addingTimeInterval(90)
        #expect(RefreshStatusText.timingLine(status, time: time) == "Retry available at t+90")
    }
}
