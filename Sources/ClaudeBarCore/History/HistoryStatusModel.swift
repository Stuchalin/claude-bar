import Foundation
import Observation

/// Main-actor view of the history store for the menu and Settings: its health and Clear history.
@MainActor
@Observable
public final class HistoryStatusModel {
    public private(set) var health = HistoryHealth()
    /// Outcome of the last Clear history, shown next to the button.
    public private(set) var clearMessage: String?
    public private(set) var isClearing = false

    @ObservationIgnored private var store: HistoryStore?

    public init() {}

    /// A health callback for `HistoryStore(onHealthChange:)` that delivers changes in order on the
    /// main queue.
    public nonisolated func healthSink() -> @Sendable (HistoryHealth) -> Void {
        { [weak self] health in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.health = health }
            }
        }
    }

    public func attach(_ store: HistoryStore) {
        self.store = store
        health = store.health
    }

    public var canClear: Bool { store != nil && health.availability == .ready && !isClearing }

    /// Deletes ClaudeBar's history, ordered after every event recorded before this call.
    public func clearHistory(at date: Date = Date()) {
        guard let store, !isClearing else { return }
        isClearing = true
        clearMessage = nil
        store.clear(at: date) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isClearing = false
                    self.clearMessage = switch result {
                    case .success: "History cleared."
                    case .failure(.unavailable): "History is unavailable; nothing was cleared."
                    case let .failure(.database(message)): "Could not clear history: \(message)"
                    }
                }
            }
        }
    }
}
