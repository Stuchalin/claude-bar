import Foundation
import Observation

/// Main-actor state of the "Usage history" submenu: the charts of the current source, loaded off
/// the main actor on demand, and the selected series.
@MainActor
@Observable
public final class UsageHistoryMenuModel {
    public enum State: Equatable, Sendable {
        case loading
        case loaded(UsageHistoryCharts)
        /// No proxy URL is configured, so there is no source to show.
        case notConfigured
        case failed(String)
    }

    public private(set) var state = State.loading
    /// The picked series id; the first series is shown when it is `nil` or no longer present.
    public var selectedSeriesID: String?
    /// `true` when the charts show synthetic fixture data instead of the history file.
    public let isFixture: Bool

    @ObservationIgnored private let reader: any UsageHistoryReading
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadToken = 0
    /// The source the current state belongs to (`nil` before the first reload or when unconfigured).
    @ObservationIgnored private(set) var currentSource: String?
    /// Every load still running, superseded ones included, for tests.
    @ObservationIgnored private var runningLoads: [Int: Task<Void, Never>] = [:]

    public init(reader: any UsageHistoryReading, isFixture: Bool, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.isFixture = isFixture
        self.now = now
    }

    /// The series the charts show.
    public var selectedSeries: UsageHistoryCharts.Series? {
        guard case let .loaded(charts) = state else { return nil }
        return charts.series.first { $0.id == selectedSeriesID } ?? charts.series.first
    }

    /// Re-reads history for `source` (`nil` when unconfigured). A newer call supersedes an older
    /// one still running, whose result is never published. For the same source the last loaded
    /// charts stay visible until the new ones arrive; a different source hides them at once and
    /// resets the selection.
    public func reload(source: String?, scopedNames: [String: String] = [:]) {
        loadToken += 1
        let token = loadToken
        loadTask?.cancel()
        if source != currentSource {
            currentSource = source
            selectedSeriesID = nil
            state = .loading
        }
        guard let source else {
            state = .notConfigured
            return
        }
        if case .loaded = state {} else { state = .loading }
        let reader = reader
        let date = now()
        loadTask = Task { [weak self] in
            let result: State
            do {
                result = try await .loaded(UsageHistoryCharts.load(
                    from: reader, source: source, scopedNames: scopedNames, now: date
                ))
            } catch HistoryStoreError.unavailable {
                result = .failed("History is unavailable.")
            } catch {
                result = .failed("History could not be read: \(error)")
            }
            guard let self else { return }
            self.runningLoads[token] = nil
            guard token == self.loadToken, !Task.isCancelled else { return }
            self.state = result
        }
        runningLoads[token] = loadTask
    }

    /// Waits for the current load, for tests.
    func waitForLoad() async {
        await loadTask?.value
    }

    /// Waits for every load still running, superseded ones included, for tests.
    func waitForAllLoads() async {
        for task in runningLoads.values { await task.value }
    }
}
