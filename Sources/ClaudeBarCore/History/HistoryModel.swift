import Foundation

/// What the refresh coordinator reports to history, with values captured at acceptance time.
public enum HistoryEvent: Equatable, Sendable {
    /// A successful fetch of the current generation accepted at `at`.
    case observed(source: String, at: Date, interval: RefreshInterval, snapshot: UsageSnapshot)
    /// An accepted failed attempt (any error except cancellation).
    case failed(source: String, at: Date)
    /// The proxy URL changed away from `oldSource`.
    case sourceChanged(oldSource: String, at: Date)

    /// The source whose streams the event affects.
    public var source: String {
        switch self {
        case let .observed(source, _, _, _), let .failed(source, _): source
        case let .sourceChanged(oldSource, _): oldSource
        }
    }

    public var at: Date {
        switch self {
        case let .observed(_, at, _, _), let .failed(_, at), let .sourceChanged(_, at): at
        }
    }
}

/// Receives history events synchronously on the main actor; implementations must return quickly.
public protocol HistoryRecording: Sendable {
    func record(_ event: HistoryEvent)
}

/// Records nothing; the coordinator's default.
public struct NoHistoryRecording: HistoryRecording {
    public init() {}
    public func record(_ event: HistoryEvent) {}
}

/// Which metric a stream follows. Extra usage is not recorded.
public enum HistoryMetric: String, Sendable, CaseIterable {
    case session
    case weekly
    case scoped
}

/// One recorded series: a metric (and scoped model key) observed through one proxy URL.
public struct HistoryStream: Equatable, Sendable, Identifiable {
    public let id: Int64
    /// Normalized proxy URL.
    public let source: String
    public let metric: HistoryMetric
    /// The scoped provenance key (`id:…`, `name:…`, `legacy:…`); empty for session and weekly.
    public let modelKey: String
}

/// Why a run ended.
public enum HistoryCloseReason: String, Sendable, CaseIterable {
    /// The used share changed.
    case changed
    /// The window's reset identity changed.
    case reset
    /// A failed attempt, or a lost write (closed at the run's own last observation).
    case failure
    /// The metric was missing, unavailable or ambiguous in a successful observation.
    case missing
    /// The proxy URL changed.
    case source
    /// No observation within the join gap, or a run left open by an earlier app run; closed at
    /// the run's last observation.
    case gap
}

/// A span of identical observations of one stream, from `firstSeenAt` to `lastSeenAt`.
public struct HistoryRun: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let streamID: Int64
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let usedPercent: Double
    public let reset: ResetState
    /// `nil` while the run is open.
    public let closedAt: Date?
    public let closeReason: HistoryCloseReason?

    public var isOpen: Bool { closedAt == nil }
}

/// Why a break record was written.
public enum HistoryBreakReason: String, Sendable, CaseIterable {
    case failure
    case missing
    case source
}

/// An explicit discontinuity: charts never draw across one.
public struct HistoryBreak: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let source: String
    public let at: Date
    public let reason: HistoryBreakReason
    /// The affected stream, `nil` for a break of the whole source.
    public let streamID: Int64?
}

/// Why the history file cannot be used. The file is never modified, deleted or recreated.
public enum HistoryUnavailableReason: Equatable, Sendable {
    /// `PRAGMA user_version` is newer than this build supports.
    case newerSchema(version: Int)
    /// A database without a version that already has tables of its own.
    case unrecognizedSchema
    /// The file is in WAL mode or has a `-wal` sidecar; this build only uses the rollback journal.
    case walMode
    /// Not a database, or the integrity check failed.
    case corrupt(String)
    /// The file or its folder could not be opened or created.
    case openFailed(String)
}

/// Nonfatal storage state shown in the menu and Settings; live usage never depends on it.
public struct HistoryHealth: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case opening
        case ready
        case unavailable(HistoryUnavailableReason)
    }

    public var availability: Availability
    /// The last failed write, cleared by the next successful one.
    public var writeError: String?

    public init(availability: Availability = .opening, writeError: String? = nil) {
        self.availability = availability
        self.writeError = writeError
    }

    /// One user-facing line, `nil` while history works.
    public var message: String? {
        switch availability {
        case let .unavailable(reason):
            let detail = switch reason {
            case let .newerSchema(version): "it was written by a newer ClaudeBar (schema \(version))"
            case .unrecognizedSchema: "the file is not a ClaudeBar history database"
            case .walMode: "the file uses a write-ahead log, which this ClaudeBar does not write"
            case let .corrupt(message): "the file looks damaged (\(message))"
            case let .openFailed(message): "it cannot be opened (\(message))"
            }
            return "History is off: \(detail). The file was left untouched."
        case .opening, .ready:
            return writeError.map { "History could not be saved: \($0)" }
        }
    }
}

/// A read or clear could not run.
public enum HistoryStoreError: Error, Equatable, Sendable {
    case unavailable
    case database(String)
}
