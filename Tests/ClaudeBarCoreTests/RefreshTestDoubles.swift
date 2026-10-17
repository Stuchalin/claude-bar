@testable import ClaudeBarCore
import Foundation

/// A clock that only moves when the test advances it.
///
/// The coordinator's driver parks in `sleep(until:)`, also while a request is in flight;
/// `waitForSleeper(after:)` returns once it has parked again, which makes "the driver finished
/// reacting" a deterministic sync point. Every park gets a sequence number.
final class ManualClock: RefreshClock, @unchecked Sendable {
    private struct Sleeper {
        let sequence: Int
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledBeforeStart: Set<UUID> = []
    private var sleeperWaiters: [(after: Int, continuation: CheckedContinuation<Date, Never>)] = []
    private var parks = 0

    init(_ start: Date) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    var sleeperCount: Int { lock.withLock { sleepers.count } }
    /// Sequence number of the latest park.
    var parkCount: Int { lock.withLock { parks } }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action {
                    case resume
                    case cancel
                    case parked([CheckedContinuation<Date, Never>])
                }
                let action: Action = lock.withLock {
                    if cancelledBeforeStart.remove(id) != nil { return .cancel }
                    if deadline <= current { return .resume }
                    parks += 1
                    sleepers[id] = Sleeper(sequence: parks, deadline: deadline, continuation: continuation)
                    let ready = sleeperWaiters.filter { $0.after < parks }.map(\.continuation)
                    sleeperWaiters.removeAll { $0.after < parks }
                    return .parked(ready)
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case let .parked(waiters): waiters.forEach { $0.resume(returning: deadline) }
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                if let sleeper = sleepers.removeValue(forKey: id) { return sleeper }
                cancelledBeforeStart.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Returns the deadline of a parked sleeper whose sequence is above `after`, waiting for one
    /// to park if none is.
    @discardableResult
    func waitForSleeper(after: Int = 0) async -> Date {
        await withCheckedContinuation { continuation in
            let deadline: Date? = lock.withLock {
                if let earliest = sleepers.values.filter({ $0.sequence > after }).map(\.deadline).min() {
                    return earliest
                }
                sleeperWaiters.append((after, continuation))
                return nil
            }
            if let deadline { continuation.resume(returning: deadline) }
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline has been reached.
    func advance(to date: Date) {
        let due: [Sleeper] = lock.withLock {
            precondition(date >= current, "ManualClock cannot go back in time")
            current = date
            let dueIDs = sleepers.filter { $0.value.deadline <= date }.map(\.key)
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        due.forEach { $0.continuation.resume() }
    }
}

/// A fetcher whose calls suspend until the test resolves them, oldest first. It reads the secret
/// from `secrets` like the production fetcher and records the secret each call would send.
final class ScriptedFetcher: UsageFetching, @unchecked Sendable {
    typealias Outcome = Result<UsageSnapshot, UsageFetchError>

    private struct Pending {
        let id: UUID
        let continuation: CheckedContinuation<Outcome, Never>
    }

    private struct Call {
        let endpoint: ProxyEndpoint
        let secret: String
    }

    let secrets: any SecretStore
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var cancelledBeforeStart: Set<UUID> = []
    private var calls: [Call] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var reads = 0
    private var readWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    var callCount: Int { lock.withLock { calls.count } }
    var endpoints: [ProxyEndpoint] { lock.withLock { calls.map(\.endpoint) } }
    /// The secret each call would send, in call order.
    var sentSecrets: [String] { lock.withLock { calls.map(\.secret) } }

    func readSecret() throws(UsageFetchError) -> String {
        defer {
            let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                reads += 1
                let ready = readWaiters.filter { $0.count <= reads }.map(\.continuation)
                readWaiters.removeAll { $0.count <= reads }
                return ready
            }
            ready.forEach { $0.resume() }
        }
        return try UsageClient.readSecret(from: secrets)
    }

    /// Waits until at least `count` attempts have read their secret.
    func waitForSecretReads(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if reads >= count { return true }
                readWaiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }

    func fetchUsage(endpoint: ProxyEndpoint, secret: String) async throws(UsageFetchError) -> UsageSnapshot {
        let id = UUID()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let (cancelled, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    calls.append(Call(endpoint: endpoint, secret: secret))
                    let isReady = { (waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)) in
                        waiter.count <= self.calls.count
                    }
                    let ready = callWaiters.filter(isReady).map(\.continuation)
                    callWaiters.removeAll(where: isReady)
                    if cancelledBeforeStart.remove(id) != nil { return (true, ready) }
                    pending.append(Pending(id: id, continuation: continuation))
                    return (false, ready)
                }
                if cancelled { continuation.resume(returning: .failure(.cancelled)) }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let call = lock.withLock { () -> Pending? in
                if let index = pending.firstIndex(where: { $0.id == id }) { return pending.remove(at: index) }
                cancelledBeforeStart.insert(id)
                return nil
            }
            call?.continuation.resume(returning: .failure(.cancelled))
        }
        return try outcome.get()
    }

    /// Waits until at least `count` fetches have started.
    func waitForCalls(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if calls.count >= count { return true }
                callWaiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Completes the oldest unresolved fetch.
    func resolveNext(_ outcome: Outcome) {
        let call = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        guard let call else { preconditionFailure("no fetch in flight") }
        call.continuation.resume(returning: outcome)
    }
}

/// Snapshot builders for refresh tests.
enum RefreshFixtures {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let endpointA = try! ProxyEndpoint(validating: "https://a.proxy.example.com")
    static let endpointB = try! ProxyEndpoint(validating: "https://b.proxy.example.com")

    /// A reset far beyond any test's horizon.
    static let farReset = t0.addingTimeInterval(7 * 24 * 60 * 60)

    static func window(
        used: Double,
        reset: ResetState = .at(farReset),
        duration: TimeInterval = UsageWindow.sessionDuration
    ) -> UsageWindow {
        UsageWindow(usedPercent: used, reset: reset, duration: duration, source: .window(field: "test"))
    }

    static func scoped(_ key: String, used: Double?, ambiguous: Bool = false) -> ScopedWeeklyLimit {
        let reading: ScopedWeeklyLimit.Reading = if ambiguous {
            .ambiguous
        } else if let used {
            .available(window(used: used, duration: UsageWindow.weeklyDuration))
        } else {
            .unavailable
        }
        return ScopedWeeklyLimit(key: key, displayName: key.uppercased(), isActive: true, reading: reading)
    }

    static func snapshot(
        session: UsageWindow? = window(used: 12),
        weekly: UsageWindow? = window(used: 1, duration: UsageWindow.weeklyDuration),
        scoped: [ScopedWeeklyLimit] = [],
        extra: ExtraUsageState = .disabled
    ) -> UsageSnapshot {
        UsageSnapshot(session: session, weekly: weekly, scopedWeeklies: scoped, extraUsage: extra, fetchedAt: t0)
    }
}

/// A coordinator wired to a manual clock and a scripted fetcher.
@MainActor
final class RefreshHarness {
    let clock = ManualClock(RefreshFixtures.t0)
    let secrets = InMemorySecretStore(secret: Fixture.dummy)
    let fetcher: ScriptedFetcher
    let coordinator: RefreshCoordinator

    init(
        interval: RefreshInterval,
        endpoint: ProxyEndpoint? = RefreshFixtures.endpointA,
        history: any HistoryRecording = NoHistoryRecording()
    ) {
        fetcher = ScriptedFetcher(secrets: secrets)
        coordinator = RefreshCoordinator(
            fetcher: fetcher, clock: clock, history: history, endpoint: endpoint, secretRevision: 0, interval: interval
        )
        coordinator.start()
    }

    var status: RefreshStatus { coordinator.status }

    /// `t0 + seconds`.
    func at(_ seconds: TimeInterval) -> Date {
        RefreshFixtures.t0.addingTimeInterval(seconds)
    }

    func advance(to seconds: TimeInterval) {
        clock.advance(to: at(seconds))
    }

    /// Waits for fetch number `call` (1-based), resolves it, and returns once the driver parks.
    @discardableResult
    func complete(call: Int, with outcome: ScriptedFetcher.Outcome) async -> Date {
        await fetcher.waitForCalls(call)
        return await resolve(outcome)
    }

    /// Resolves the oldest in-flight fetch and returns the deadline of the driver's next park.
    /// The driver parks during the request too, so first wait for that park, then for a newer one.
    @discardableResult
    func resolve(_ outcome: ScriptedFetcher.Outcome) async -> Date {
        await clock.waitForSleeper()
        let mark = clock.parkCount
        fetcher.resolveNext(outcome)
        return await clock.waitForSleeper(after: mark)
    }

    func stop() {
        coordinator.stop()
    }
}

/// A flag set from an observation `onChange` callback.
final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool { lock.withLock { raised } }

    func raise() {
        lock.withLock { raised = true }
    }
}
