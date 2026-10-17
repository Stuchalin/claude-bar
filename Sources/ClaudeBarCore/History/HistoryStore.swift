import Foundation

/// Usage history in one SQLite file, as runs of unchanged values per stream with explicit breaks.
///
/// One connection lives on a private serial queue: `record(_:)` and `clear(at:completion:)`
/// enqueue and return at once, reads are `async` on the same queue, so every operation applies in
/// call order. Each event is one `BEGIN IMMEDIATE` transaction. A file that is damaged or written
/// by a newer schema is never modified, deleted or recreated: history turns off (`health`) and
/// recording becomes a no-op while live usage keeps working.
public final class HistoryStore: HistoryRecording, @unchecked Sendable {
    public static let schemaVersion = 1
    static let retention: TimeInterval = 365 * 24 * 60 * 60
    static let retentionCheckInterval: TimeInterval = 24 * 60 * 60
    /// Two resets closer than this are the same boundary (CodexBar
    /// `areEquivalentPlanUtilizationResetBoundaries`).
    static let resetTolerance: TimeInterval = 120
    /// Join gap in manual mode, equal to the manual stale age.
    static let manualJoinGap: TimeInterval = 10 * 60
    static let joinGapFactor = 2.5

    /// Test hook: places where an injected fault aborts the current event's transaction.
    enum FaultPoint: Sendable {
        /// After a run was closed and before its successor is opened.
        case afterClose
        /// Just before COMMIT.
        case beforeCommit
    }

    struct InjectedFault: Error {}

    /// `~/Library/Application Support/ClaudeBar/history.sqlite`.
    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "ClaudeBar", directoryHint: .isDirectory)
            .appending(path: "history.sqlite", directoryHint: .notDirectory)
    }

    public let url: URL

    private let queue = DispatchQueue(label: "ru.sdfpro.ClaudeBar.history")
    private let now: @Sendable () -> Date
    private let onHealthChange: (@Sendable (HistoryHealth) -> Void)?
    private let healthLock = NSLock()
    private var currentHealth = HistoryHealth()

    // Confined to `queue`.
    private var db: SQLiteDatabase?
    private var clearedAt: Date?
    private var lastRetentionAt: Date?
    /// Sources whose last write was rolled back, with the time of the first lost event.
    private var pendingDiscontinuity: [String: Date] = [:]
    /// Runs left open by an earlier store instance (id → source). The first event of their source
    /// never extends them: what happened between that instance and this one is unknown.
    private var inheritedOpenRuns: [Int64: String] = [:]
    private var pendingFault: FaultPoint?

    /// Opens (or creates) the file on the store's queue; `onHealthChange` is called on that queue.
    public init(
        url: URL = HistoryStore.defaultURL(),
        now: @escaping @Sendable () -> Date = { Date() },
        onHealthChange: (@Sendable (HistoryHealth) -> Void)? = nil
    ) {
        self.url = url
        self.now = now
        self.onHealthChange = onHealthChange
        queue.async { self.open() }
    }

    /// The latest storage state.
    public var health: HistoryHealth { healthLock.withLock { currentHealth } }

    // MARK: - Writes

    public func record(_ event: HistoryEvent) {
        queue.async { self.apply(event) }
    }

    /// Deletes every run, break and stream, and ignores later events older than `at`. Ordered with
    /// `record(_:)`: everything recorded before this call is gone afterwards.
    public func clear(at date: Date, completion: (@Sendable (Result<Void, HistoryStoreError>) -> Void)? = nil) {
        queue.async {
            let result = self.performClear(at: date)
            completion?(result)
        }
    }

    /// Closes the connection after pending work; later calls are no-ops.
    public func close() {
        queue.sync {
            db?.close()
            db = nil
        }
    }

    // MARK: - Reads

    public func streams() async throws -> [HistoryStream] {
        try await read { db in
            try db.query("SELECT id, source, metric, model_key FROM streams ORDER BY id") { row in
                HistoryStream(
                    id: row.integer(0),
                    source: row.text(1),
                    metric: HistoryMetric(rawValue: row.text(2)) ?? .session,
                    modelKey: row.text(3)
                )
            }
        }
    }

    /// Runs of `streamID` overlapping `from…to`, oldest first.
    public func runs(streamID: Int64, from: Date = .distantPast, to: Date = .distantFuture) async throws -> [HistoryRun] {
        try await read { db in
            try db.query(
                """
                SELECT id, stream_id, first_seen_at, last_seen_at, used_percent, reset_kind, resets_at, closed_at, close_reason
                FROM runs WHERE stream_id = ? AND last_seen_at >= ? AND first_seen_at <= ?
                ORDER BY first_seen_at, id
                """,
                [.integer(streamID), .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)],
                map: Self.run(from:)
            )
        }
    }

    /// Distinct observed reset dates (`reset_kind = 'at'`) of `streamID`, oldest first.
    public func resetDates(streamID: Int64) async throws -> [Date] {
        try await read { db in
            try db.query(
                "SELECT DISTINCT resets_at FROM runs WHERE stream_id = ? AND reset_kind = 'at' AND resets_at IS NOT NULL ORDER BY resets_at",
                [.integer(streamID)]
            ) { row in Date(timeIntervalSince1970: row.real(0)) }
        }
    }

    /// Every run of `streamID` with an observed reset at or after `resetsFrom`, whenever it was
    /// observed, ordered by first sighting.
    public func runs(streamID: Int64, resetsFrom: Date) async throws -> [HistoryRun] {
        try await read { db in
            try db.query(
                """
                SELECT id, stream_id, first_seen_at, last_seen_at, used_percent, reset_kind, resets_at, closed_at, close_reason
                FROM runs WHERE stream_id = ? AND reset_kind = 'at' AND resets_at >= ?
                ORDER BY first_seen_at, id
                """,
                [.integer(streamID), .real(resetsFrom.timeIntervalSince1970)],
                map: Self.run(from:)
            )
        }
    }

    /// Breaks of `source` within `from…to`, oldest first.
    public func breaks(source: String, from: Date = .distantPast, to: Date = .distantFuture) async throws -> [HistoryBreak] {
        try await read { db in
            try db.query(
                "SELECT id, source, at, reason, stream_id FROM breaks WHERE source = ? AND at >= ? AND at <= ? ORDER BY at, id",
                [.text(source), .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]
            ) { row in
                HistoryBreak(
                    id: row.integer(0),
                    source: row.text(1),
                    at: Date(timeIntervalSince1970: row.real(2)),
                    reason: HistoryBreakReason(rawValue: row.text(3)) ?? .failure,
                    streamID: row.optionalInteger(4)
                )
            }
        }
    }

    /// Waits until everything enqueued before this call has been applied.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Makes the next event's transaction fail at `point` (ordered with `record(_:)`).
    func injectFault(at point: FaultPoint) {
        queue.async { self.pendingFault = point }
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (SQLiteDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let db = self.db else { return continuation.resume(throwing: HistoryStoreError.unavailable) }
                do {
                    continuation.resume(returning: try body(db))
                } catch {
                    continuation.resume(throwing: HistoryStoreError.database(String(describing: error)))
                }
            }
        }
    }

    // MARK: - Open

    private func open() {
        let path = url.path(percentEncoded: false)
        let fileManager = FileManager.default
        let existingSize = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
        do {
            if existingSize == nil {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let isEmptyFile = (existingSize ?? 0) == 0
            if !isEmptyFile, Self.usesWriteAheadLog(path: path) {
                setHealth { $0.availability = .unavailable(.walMode) }
                return
            }
            if !isEmptyFile, let reason = try probe(path: path) {
                setHealth { $0.availability = .unavailable(reason) }
                return
            }
            // The probe confirmed our schema (or an empty file): opening read-write may now
            // recover a hot journal of our own file.
            let db = try SQLiteDatabase(path: path, create: existingSize == nil)
            if !isEmptyFile, let reason = try validate(db) {
                db.close()
                setHealth { $0.availability = .unavailable(reason) }
                return
            }
            try db.immediateTransaction {
                if try userVersion(db) == 0 { try Self.createSchema(db) }
            }
            inheritedOpenRuns = Dictionary(uniqueKeysWithValues: try db.query(
                "SELECT r.id, s.source FROM runs r JOIN streams s ON s.id = r.stream_id WHERE r.closed_at IS NULL"
            ) { ($0.integer(0), $0.text(1)) })
            clearedAt = try db.query("SELECT value FROM meta WHERE key = 'cleared_at'") { row in
                Double(row.text(0)).map(Date.init(timeIntervalSince1970:))
            }.first ?? nil
            self.db = db
            setHealth { $0.availability = .ready }
            pruneIfDue(force: true)
        } catch let error as SQLiteError where Self.isCorruption(error) {
            setHealth { $0.availability = .unavailable(.corrupt(error.message)) }
        } catch {
            setHealth { $0.availability = .unavailable(.openFailed(String(describing: error))) }
        }
    }

    /// `true` when the header says WAL mode (bytes 18/19 == 2) or a non-empty `-wal` sidecar exists.
    /// The immutable probe ignores the WAL and a read-write open would checkpoint it, so such a
    /// file is refused before any SQLite connection; only plain file reads happen here.
    static func usesWriteAheadLog(path: String) -> Bool {
        let walSize = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?.intValue ?? 0
        if walSize > 0 { return true }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20,
              header.prefix(16) == Data("SQLite format 3\0".utf8) else { return false }
        return header[18] == 2 || header[19] == 2
    }

    /// Inspects an existing non-empty file through an immutable read-only connection that cannot
    /// modify it or its sidecars. Returns why it must not be used: a newer schema, foreign tables,
    /// or a file that cannot be read as it is (also when only journal recovery would make it
    /// readable). `nil` when it is a v0-without-tables or v1 database.
    private func probe(path: String) throws -> HistoryUnavailableReason? {
        let probe = try SQLiteDatabase(probingImmutable: path)
        defer { probe.close() }
        return try schemaProblem(probe)
    }

    /// Re-checks the schema after a read-write open (recovery may have run) and the integrity.
    private func validate(_ db: SQLiteDatabase) throws -> HistoryUnavailableReason? {
        if let problem = try schemaProblem(db) { return problem }
        let check = try db.query("PRAGMA quick_check") { $0.text(0) }
        guard check == ["ok"] else { return .corrupt(check.prefix(3).joined(separator: "; ")) }
        return nil
    }

    private func schemaProblem(_ db: SQLiteDatabase) throws -> HistoryUnavailableReason? {
        let version = try userVersion(db)
        if version > Self.schemaVersion { return .newerSchema(version: version) }
        if version == 0 {
            let tables = try db.query("SELECT count(*) FROM sqlite_master") { $0.integer(0) }.first ?? 0
            if tables > 0 { return .unrecognizedSchema }
        }
        return nil
    }

    private func userVersion(_ db: SQLiteDatabase) throws -> Int {
        Int(try db.query("PRAGMA user_version") { $0.integer(0) }.first ?? 0)
    }

    private static func isCorruption(_ error: SQLiteError) -> Bool {
        error.primaryCode == 11 /* SQLITE_CORRUPT */ || error.primaryCode == 26 /* SQLITE_NOTADB */
    }

    static func createSchema(_ db: SQLiteDatabase) throws {
        try db.execute(
            """
            CREATE TABLE streams(
                id INTEGER PRIMARY KEY,
                source TEXT NOT NULL,
                metric TEXT NOT NULL CHECK (metric IN ('session', 'weekly', 'scoped')),
                model_key TEXT NOT NULL DEFAULT '',
                UNIQUE (source, metric, model_key)
            );
            CREATE TABLE runs(
                id INTEGER PRIMARY KEY,
                stream_id INTEGER NOT NULL REFERENCES streams(id),
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                used_percent REAL NOT NULL,
                reset_kind TEXT NOT NULL CHECK (reset_kind IN ('at', 'notStarted', 'unknown')),
                resets_at REAL,
                closed_at REAL,
                close_reason TEXT CHECK (close_reason IN ('changed', 'reset', 'failure', 'missing', 'source', 'gap'))
            );
            CREATE UNIQUE INDEX runs_one_open_per_stream ON runs(stream_id) WHERE closed_at IS NULL;
            CREATE INDEX runs_by_stream_time ON runs(stream_id, first_seen_at);
            CREATE TABLE breaks(
                id INTEGER PRIMARY KEY,
                source TEXT NOT NULL,
                at REAL NOT NULL,
                reason TEXT NOT NULL CHECK (reason IN ('failure', 'missing', 'source')),
                stream_id INTEGER REFERENCES streams(id)
            );
            CREATE INDEX breaks_by_source_time ON breaks(source, at);
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            PRAGMA user_version = \(schemaVersion);
            """
        )
    }

    // MARK: - Events

    private struct StreamKey: Hashable {
        let metric: HistoryMetric
        let modelKey: String
    }

    private struct OpenRun {
        let id: Int64
        let streamID: Int64
        let key: StreamKey
        let lastSeenAt: Date
        let usedPercent: Double
        let reset: ResetState
    }

    private func apply(_ event: HistoryEvent) {
        guard let db else { return }
        if let clearedAt, event.at < clearedAt { return }
        let source = event.source
        let fault = pendingFault
        pendingFault = nil
        do {
            try db.immediateTransaction {
                if let lostAt = pendingDiscontinuity[source] {
                    try closeOpenRunsAtLastSeen(db, source: source)
                    try insertBreak(db, source: source, at: lostAt, reason: .failure, streamID: nil)
                }
                switch event {
                case let .observed(_, at, interval, snapshot):
                    try applyObservation(db, source: source, at: at, interval: interval, snapshot: snapshot, fault: fault)
                case let .failed(_, at):
                    try closeOpenRuns(db, source: source, at: at, reason: .failure)
                    try insertBreak(db, source: source, at: at, reason: .failure, streamID: nil)
                case let .sourceChanged(_, at):
                    try closeOpenRuns(db, source: source, at: at, reason: .source)
                    try insertBreak(db, source: source, at: at, reason: .source, streamID: nil)
                }
                if fault == .beforeCommit { throw InjectedFault() }
            }
            pendingDiscontinuity[source] = nil
            if !inheritedOpenRuns.isEmpty { inheritedOpenRuns = inheritedOpenRuns.filter { $0.value != source } }
            if health.writeError != nil { setHealth { $0.writeError = nil } }
        } catch {
            if pendingDiscontinuity[source] == nil { pendingDiscontinuity[source] = event.at }
            let message = error is InjectedFault ? "injected fault" : String(describing: error)
            setHealth { $0.writeError = message }
        }
        pruneIfDue(force: false)
    }

    private func applyObservation(
        _ db: SQLiteDatabase,
        source: String,
        at: Date,
        interval: RefreshInterval,
        snapshot: UsageSnapshot,
        fault: FaultPoint?
    ) throws {
        let readings = Self.readings(snapshot)
        let maxJoinGap = interval.seconds.map { $0 * Self.joinGapFactor } ?? Self.manualJoinGap
        let open = try openRuns(db, source: source)
        let openByKey = Dictionary(open.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for run in open where readings[run.key] == nil {
            try closeRun(db, id: run.id, at: at, reason: .missing)
            try insertBreak(db, source: source, at: at, reason: .missing, streamID: run.streamID)
        }

        for (key, window) in readings.sorted(by: { ($0.key.metric.rawValue, $0.key.modelKey) < ($1.key.metric.rawValue, $1.key.modelKey) }) {
            let streamID: Int64
            if let run = openByKey[key] {
                let inherited = inheritedOpenRuns[run.id] != nil
                let reason: HistoryCloseReason? = if inherited || at.timeIntervalSince(run.lastSeenAt) > maxJoinGap {
                    .gap
                } else if !Self.sameResetBoundary(run.reset, window.reset) {
                    .reset
                } else if run.usedPercent != window.usedPercent {
                    .changed
                } else {
                    nil
                }
                guard let reason else {
                    try db.run("UPDATE runs SET last_seen_at = ? WHERE id = ?", [.real(at.timeIntervalSince1970), .integer(run.id)])
                    continue
                }
                try closeRun(db, id: run.id, at: reason == .gap ? run.lastSeenAt : at, reason: reason)
                if fault == .afterClose { throw InjectedFault() }
                streamID = run.streamID
            } else {
                streamID = try ensureStream(db, source: source, key: key)
            }
            let (kind, resetsAt) = Self.encode(window.reset)
            try db.run(
                """
                INSERT INTO runs(stream_id, first_seen_at, last_seen_at, used_percent, reset_kind, resets_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .integer(streamID), .real(at.timeIntervalSince1970), .real(at.timeIntervalSince1970),
                    .real(window.usedPercent), .text(kind), resetsAt.map(SQLiteValue.real) ?? .null,
                ]
            )
        }
    }

    /// The recordable windows of a snapshot. Rows without a window (unavailable, ambiguous) are
    /// absent; duplicate scoped keys are dropped rather than merged.
    private static func readings(_ snapshot: UsageSnapshot) -> [StreamKey: UsageWindow] {
        var readings: [StreamKey: UsageWindow] = [:]
        if let session = snapshot.session { readings[StreamKey(metric: .session, modelKey: "")] = session }
        if let weekly = snapshot.weekly { readings[StreamKey(metric: .weekly, modelKey: "")] = weekly }
        var keyCounts: [String: Int] = [:]
        for row in snapshot.scopedWeeklies { keyCounts[row.key, default: 0] += 1 }
        for row in snapshot.scopedWeeklies where keyCounts[row.key] == 1 {
            if let window = row.window { readings[StreamKey(metric: .scoped, modelKey: row.key)] = window }
        }
        return readings
    }

    static func sameResetBoundary(_ lhs: ResetState, _ rhs: ResetState) -> Bool {
        switch (lhs, rhs) {
        case let (.at(a), .at(b)): abs(a.timeIntervalSince(b)) < resetTolerance
        case (.notStarted, .notStarted), (.unknown, .unknown): true
        default: false
        }
    }

    private static func encode(_ reset: ResetState) -> (String, Double?) {
        switch reset {
        case let .at(date): ("at", date.timeIntervalSince1970)
        case .notStarted: ("notStarted", nil)
        case .unknown: ("unknown", nil)
        }
    }

    private static func decodeReset(kind: String, at: Double?) -> ResetState {
        switch (kind, at) {
        case let ("at", .some(at)): .at(Date(timeIntervalSince1970: at))
        case ("notStarted", _): .notStarted
        default: .unknown
        }
    }

    private static func run(from row: SQLiteRow) -> HistoryRun {
        HistoryRun(
            id: row.integer(0),
            streamID: row.integer(1),
            firstSeenAt: Date(timeIntervalSince1970: row.real(2)),
            lastSeenAt: Date(timeIntervalSince1970: row.real(3)),
            usedPercent: row.real(4),
            reset: decodeReset(kind: row.text(5), at: row.optionalReal(6)),
            closedAt: row.optionalReal(7).map(Date.init(timeIntervalSince1970:)),
            closeReason: row.optionalText(8).flatMap(HistoryCloseReason.init(rawValue:))
        )
    }

    private func openRuns(_ db: SQLiteDatabase, source: String) throws -> [OpenRun] {
        try db.query(
            """
            SELECT r.id, r.stream_id, s.metric, s.model_key, r.last_seen_at, r.used_percent, r.reset_kind, r.resets_at
            FROM runs r JOIN streams s ON s.id = r.stream_id
            WHERE s.source = ? AND r.closed_at IS NULL
            """,
            [.text(source)]
        ) { row in
            OpenRun(
                id: row.integer(0),
                streamID: row.integer(1),
                key: StreamKey(metric: HistoryMetric(rawValue: row.text(2)) ?? .session, modelKey: row.text(3)),
                lastSeenAt: Date(timeIntervalSince1970: row.real(4)),
                usedPercent: row.real(5),
                reset: Self.decodeReset(kind: row.text(6), at: row.optionalReal(7))
            )
        }
    }

    private func ensureStream(_ db: SQLiteDatabase, source: String, key: StreamKey) throws -> Int64 {
        let bindings: [SQLiteValue] = [.text(source), .text(key.metric.rawValue), .text(key.modelKey)]
        try db.run("INSERT OR IGNORE INTO streams(source, metric, model_key) VALUES (?, ?, ?)", bindings)
        let ids = try db.query(
            "SELECT id FROM streams WHERE source = ? AND metric = ? AND model_key = ?", bindings
        ) { $0.integer(0) }
        guard let id = ids.first else { throw HistoryStoreError.database("stream row missing after insert") }
        return id
    }

    private func closeRun(_ db: SQLiteDatabase, id: Int64, at: Date, reason: HistoryCloseReason) throws {
        try db.run(
            "UPDATE runs SET closed_at = ?, close_reason = ? WHERE id = ?",
            [.real(at.timeIntervalSince1970), .text(reason.rawValue), .integer(id)]
        )
    }

    private func closeOpenRuns(_ db: SQLiteDatabase, source: String, at: Date, reason: HistoryCloseReason) throws {
        try db.run(
            """
            UPDATE runs SET closed_at = ?, close_reason = ?
            WHERE closed_at IS NULL AND stream_id IN (SELECT id FROM streams WHERE source = ?)
            """,
            [.real(at.timeIntervalSince1970), .text(reason.rawValue), .text(source)]
        )
    }

    /// Closes every open run of `source` at its own last observation: the lost event's time is unknown.
    private func closeOpenRunsAtLastSeen(_ db: SQLiteDatabase, source: String) throws {
        try db.run(
            """
            UPDATE runs SET closed_at = last_seen_at, close_reason = 'failure'
            WHERE closed_at IS NULL AND stream_id IN (SELECT id FROM streams WHERE source = ?)
            """,
            [.text(source)]
        )
    }

    private func insertBreak(_ db: SQLiteDatabase, source: String, at: Date, reason: HistoryBreakReason, streamID: Int64?) throws {
        try db.run(
            "INSERT INTO breaks(source, at, reason, stream_id) VALUES (?, ?, ?, ?)",
            [.text(source), .real(at.timeIntervalSince1970), .text(reason.rawValue), streamID.map(SQLiteValue.integer) ?? .null]
        )
    }

    // MARK: - Clear and retention

    private func performClear(at date: Date) -> Result<Void, HistoryStoreError> {
        guard let db else { return .failure(.unavailable) }
        do {
            try db.immediateTransaction {
                try db.execute("DELETE FROM runs; DELETE FROM breaks; DELETE FROM streams;")
                try db.run(
                    "INSERT OR REPLACE INTO meta(key, value) VALUES ('cleared_at', ?)",
                    [.text(String(date.timeIntervalSince1970))]
                )
            }
            clearedAt = date
            pendingDiscontinuity = [:]
            inheritedOpenRuns = [:]
            return .success(())
        } catch {
            let message = String(describing: error)
            setHealth { $0.writeError = message }
            return .failure(.database(message))
        }
    }

    /// Deletes closed runs and breaks older than the retention period, then orphan streams.
    private func pruneIfDue(force: Bool) {
        guard let db else { return }
        let current = now()
        if !force, let lastRetentionAt, current.timeIntervalSince(lastRetentionAt) < Self.retentionCheckInterval { return }
        lastRetentionAt = current
        let cutoff = SQLiteValue.real(current.addingTimeInterval(-Self.retention).timeIntervalSince1970)
        do {
            try db.immediateTransaction {
                try db.run("DELETE FROM runs WHERE closed_at IS NOT NULL AND last_seen_at < ?", [cutoff])
                try db.run("DELETE FROM breaks WHERE at < ?", [cutoff])
                try db.run(
                    """
                    DELETE FROM streams
                    WHERE NOT EXISTS (SELECT 1 FROM runs WHERE runs.stream_id = streams.id)
                      AND NOT EXISTS (SELECT 1 FROM breaks WHERE breaks.stream_id = streams.id)
                    """
                )
            }
        } catch {
            let message = String(describing: error)
            setHealth { $0.writeError = message }
        }
    }

    private func setHealth(_ change: (inout HistoryHealth) -> Void) {
        let updated: HistoryHealth? = healthLock.withLock {
            var next = currentHealth
            change(&next)
            guard next != currentHealth else { return nil }
            currentHealth = next
            return next
        }
        if let updated { onHealthChange?(updated) }
    }
}
