@testable import ClaudeBarCore
import Foundation
import Testing

private typealias F = RefreshFixtures

private let sourceA = F.endpointA.normalizedString
private let sourceB = F.endpointB.normalizedString

/// The coordinator with a real store on a temporary file, plus a spy on the event stream.
@MainActor
private final class HistoryHarness {
    let temp = TempHistoryDirectory()
    let spy = RecordingSpy()
    let store: HistoryStore
    let refresh: RefreshHarness

    init(interval: RefreshInterval = .fiveMinutes) {
        store = temp.makeStore()
        refresh = RefreshHarness(interval: interval, history: FanOutRecording(recorders: [spy, store]))
    }

    var coordinator: RefreshCoordinator { refresh.coordinator }

    func runs(_ metric: HistoryMetric, source: String = sourceA, modelKey: String = "") async throws -> [HistoryRun] {
        try await store.runs(source: source, metric: metric, modelKey: modelKey)
    }

    func stop() {
        refresh.stop()
    }
}

@MainActor
@Suite("History end to end", .timeLimit(.minutes(1)))
struct HistoryEndToEndTests {
    @Test("each accepted result is recorded once, at acceptance time, under the captured source")
    func acceptedOnce() async throws {
        let h = HistoryHarness()
        defer { h.stop() }
        await h.refresh.fetcher.waitForCalls(1)
        h.refresh.advance(to: 4) // acceptance happens after the attempt started
        await h.refresh.resolve(.success(F.snapshot(session: F.window(used: 10))))
        h.refresh.advance(to: 300)
        await h.refresh.complete(call: 2, with: .success(F.snapshot(session: F.window(used: 10))))
        h.refresh.advance(to: 600)
        await h.refresh.complete(call: 3, with: .success(F.snapshot(session: F.window(used: 25))))

        #expect(h.spy.events.count == 3)
        #expect(h.spy.events.map(\.at) == [h.refresh.at(4), h.refresh.at(300), h.refresh.at(600)])
        #expect(h.spy.events.allSatisfy { $0.source == sourceA })
        guard case let .observed(_, _, interval, _) = h.spy.events[0] else {
            Issue.record("expected an observation")
            return
        }
        #expect(interval == .fiveMinutes)

        let session = try await h.runs(.session)
        #expect(session.map(\.usedPercent) == [10, 25])
        #expect(session[0].firstSeenAt == h.refresh.at(4))
        #expect(session[0].lastSeenAt == h.refresh.at(300))
        #expect(session[0].closeReason == .changed)
        #expect(try await h.runs(.weekly).map(\.lastSeenAt) == [h.refresh.at(600)])
        #expect(try await h.store.streams().count == 2)
    }

    @Test("every accepted failure is recorded, including 401; cancellation is not")
    func failures() async throws {
        let h = HistoryHarness(interval: .manual)
        defer { h.stop() }
        h.coordinator.trigger(.manualRefresh)
        await h.refresh.complete(call: 1, with: .success(F.snapshot()))
        h.coordinator.trigger(.manualRefresh)
        await h.refresh.complete(call: 2, with: .failure(.unauthorized))
        h.coordinator.trigger(.manualRefresh)
        await h.refresh.complete(call: 3, with: .failure(.cancelled))

        #expect(h.spy.events.count == 2)
        #expect(h.spy.events.last == .failed(source: sourceA, at: F.t0))
        #expect(try await h.runs(.session).map(\.closeReason) == [.failure])
        #expect(try await h.store.breaks(source: sourceA).map(\.reason) == [.failure])
    }

    @Test("a late result from the old URL is not written; the URL change closes the old source")
    func lateResultAfterURLChange() async throws {
        let h = HistoryHarness()
        defer { h.stop() }
        await h.refresh.complete(call: 1, with: .success(F.snapshot(session: F.window(used: 10))))
        h.coordinator.trigger(.manualRefresh)
        await h.refresh.fetcher.waitForCalls(2)

        h.refresh.advance(to: 5)
        h.coordinator.configure(endpoint: F.endpointB, secretRevision: 0, interval: .fiveMinutes)
        h.refresh.fetcher.resolveNext(.success(F.snapshot(session: F.window(used: 50))))
        await h.refresh.complete(call: 3, with: .success(F.snapshot(session: F.window(used: 70))))

        #expect(h.spy.events.count == 3)
        #expect(h.spy.events[1] == .sourceChanged(oldSource: sourceA, at: h.refresh.at(5)))
        #expect(h.spy.events[2].source == sourceB)
        let a = try await h.runs(.session)
        #expect(a.map(\.usedPercent) == [10])
        #expect(a[0].closeReason == .source)
        #expect(try await h.runs(.session, source: sourceB).map(\.usedPercent) == [70])
        #expect(try await h.store.breaks(source: sourceA).map(\.reason) == [.source])
    }

    @Test("a late result after a secret change is not written")
    func lateResultAfterSecretChange() async throws {
        let h = HistoryHarness()
        defer { h.stop() }
        await h.refresh.complete(call: 1, with: .success(F.snapshot(session: F.window(used: 10))))
        h.coordinator.trigger(.manualRefresh)
        await h.refresh.fetcher.waitForCalls(2)
        h.coordinator.configure(endpoint: F.endpointA, secretRevision: 1, interval: .fiveMinutes)
        h.refresh.fetcher.resolveNext(.success(F.snapshot(session: F.window(used: 50))))
        await h.refresh.complete(call: 3, with: .success(F.snapshot(session: F.window(used: 70))))

        #expect(h.spy.events.count == 2)
        #expect(try await h.runs(.session).map(\.usedPercent) == [10, 70])
        #expect(try await h.store.breaks(source: sourceA).isEmpty)
    }

    @Test("a request cancelled by stop is not written")
    func cancelledByStop() async throws {
        let h = HistoryHarness()
        await h.refresh.complete(call: 1, with: .success(F.snapshot()))
        h.coordinator.trigger(.manualRefresh)
        await h.refresh.fetcher.waitForCalls(2)
        h.stop()
        await h.store.flush()
        // Let the cancelled fetch task finish on the main actor.
        for _ in 0 ..< 10 { await Task.yield() }
        #expect(h.spy.events.count == 1)
        #expect(try await h.runs(.session).allSatisfy(\.isOpen))
    }

    @Test("a missing metric breaks only its own stream")
    func missingMetric() async throws {
        let h = HistoryHarness()
        defer { h.stop() }
        await h.refresh.complete(call: 1, with: .success(F.snapshot()))
        h.refresh.advance(to: 300)
        await h.refresh.complete(call: 2, with: .success(F.snapshot(weekly: nil)))

        #expect(try await h.runs(.weekly).map(\.closeReason) == [.missing])
        let session = try await h.runs(.session)
        #expect(session.count == 1 && session[0].isOpen && session[0].lastSeenAt == h.refresh.at(300))
        let breaks = try await h.store.breaks(source: sourceA)
        #expect(breaks.count == 1 && breaks[0].reason == .missing && breaks[0].streamID != nil)
    }

    @Test("a scoped name → id transition starts a new stream")
    func scopedKeyTransition() async throws {
        let h = HistoryHarness()
        defer { h.stop() }
        await h.refresh.complete(call: 1, with: .success(F.snapshot(scoped: [F.scoped("name:fable", used: 3)])))
        h.refresh.advance(to: 300)
        await h.refresh.complete(call: 2, with: .success(F.snapshot(scoped: [F.scoped("id:claude-fable", used: 3)])))

        let byName = try await h.runs(.scoped, modelKey: "name:fable")
        let byID = try await h.runs(.scoped, modelKey: "id:claude-fable")
        #expect(byName.map(\.closeReason) == [.missing])
        #expect(byID.count == 1 && byID[0].isOpen && byID[0].firstSeenAt == h.refresh.at(300))
        #expect(byName[0].streamID != byID[0].streamID)
    }

    @Test("a restarted store reads the same runs")
    func restart() async throws {
        let h = HistoryHarness()
        await h.refresh.complete(call: 1, with: .success(F.snapshot(scoped: [F.scoped("id:m", used: 3)])))
        h.stop()
        let before = try await h.store.streams()
        var runsBefore: [[HistoryRun]] = []
        for stream in before { runsBefore.append(try await h.store.runs(streamID: stream.id)) }
        h.store.close()

        let reopened = h.temp.makeStore()
        #expect(try await reopened.streams() == before)
        for (stream, runs) in zip(before, runsBefore) {
            #expect(try await reopened.runs(streamID: stream.id) == runs)
        }
        #expect(before.count == 3)
    }

    @Test("Clear history during a request: older data is gone, the result accepted afterwards is kept")
    func clearDuringFlight() async throws {
        let h = HistoryHarness()
        defer { h.stop() }
        let status = HistoryStatusModel()
        await h.store.flush() // opened
        status.attach(h.store)
        #expect(status.canClear)

        await h.refresh.complete(call: 1, with: .success(F.snapshot(session: F.window(used: 10))))
        h.coordinator.trigger(.manualRefresh)
        await h.refresh.fetcher.waitForCalls(2)
        h.refresh.advance(to: 10)
        status.clearHistory(at: h.refresh.at(10))
        #expect(!status.canClear)
        await h.refresh.resolve(.success(F.snapshot(session: F.window(used: 20))))

        #expect(try await h.runs(.session).map(\.usedPercent) == [20])
        #expect(try await h.runs(.session).first?.firstSeenAt == h.refresh.at(10))
        while status.isClearing { await Task.yield() }
        #expect(status.clearMessage == "History cleared.")
    }
}
