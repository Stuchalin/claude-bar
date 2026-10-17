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
