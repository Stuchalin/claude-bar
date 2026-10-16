@testable import ClaudeBarCore
import Foundation
import Testing

private typealias F = RefreshFixtures

private let sourceA = F.endpointA.normalizedString
private let sourceB = F.endpointB.normalizedString

private func at(_ seconds: TimeInterval) -> Date { F.t0.addingTimeInterval(seconds) }

private func observed(
    _ seconds: TimeInterval,
    source: String = sourceA,
    interval: RefreshInterval = .oneMinute,
    session: Double? = 10,
    sessionReset: ResetState = .at(F.farReset),
    weekly: Double? = 1,
    scoped: [ScopedWeeklyLimit] = []
) -> HistoryEvent {
    let snapshot = F.snapshot(
        session: session.map { F.window(used: $0, reset: sessionReset) },
        weekly: weekly.map { F.window(used: $0, duration: UsageWindow.weeklyDuration) },
        scoped: scoped
    )
    return .observed(source: source, at: at(seconds), interval: interval, snapshot: snapshot)
}

@Suite("HistoryStore", .timeLimit(.minutes(1)))
struct HistoryStoreTests {
    // MARK: - Open

    @Test("a missing file is created as schema v1 inside a new folder")
    func createsSchema() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        await store.flush()
        #expect(store.health.availability == .ready)
        #expect(store.health.message == nil)
        store.close()

        let db = try SQLiteDatabase(path: temp.path, create: false)
        #expect(try db.query("PRAGMA user_version") { $0.integer(0) } == [1])
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { $0.text(0) }
        #expect(tables == ["breaks", "meta", "runs", "streams"])
    }

    @Test("an empty file becomes schema v1")
    func emptyFile() async throws {
        let temp = TempHistoryDirectory()
        try temp.seed(Data())
        let store = temp.makeStore()
        store.record(observed(0))
        #expect(try await store.runs(source: sourceA, metric: .session).count == 1)
        #expect(store.health.availability == .ready)
    }

    @Test("a newer schema is refused and the file stays byte-identical")
    func newerSchema() async throws {
        let temp = TempHistoryDirectory()
        try temp.seed(Data())
        do {
            let db = try SQLiteDatabase(path: temp.path, create: false)
            try db.execute("CREATE TABLE future(x); INSERT INTO future VALUES (1); PRAGMA user_version = 2;")
        }
        let before = try temp.contents()
        let folderBefore = try temp.folderContents()

        let store = temp.makeStore()
        store.record(observed(0))
        store.clear(at: at(1))
        await store.flush()
        #expect(store.health.availability == .unavailable(.newerSchema(version: 2)))
        #expect(store.health.message?.contains("left untouched") == true)
        await #expect(throws: HistoryStoreError.unavailable) { try await store.streams() }
        store.close()
        #expect(try temp.contents() == before)
        #expect(try temp.folderContents() == folderBefore)
    }

    @Test("a file that is not a database is reported corrupt and left byte-identical")
    func notADatabase() async throws {
        let temp = TempHistoryDirectory()
        let garbage = Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try temp.seed(garbage)
        let store = temp.makeStore()
        store.record(observed(0))
        await store.flush()
        guard case .unavailable(.corrupt) = store.health.availability else {
            Issue.record("expected corrupt, got \(store.health.availability)")
            return
        }
        store.close()
        #expect(try temp.contents() == garbage)
        #expect(try temp.folderContents() == ["history.sqlite"])
    }

    @Test("a damaged v1 database fails the integrity check and is left byte-identical")
    func damagedDatabase() async throws {
        let temp = TempHistoryDirectory()
        let seedStore = temp.makeStore()
        for second in 0 ..< 200 { seedStore.record(observed(TimeInterval(second * 60), session: Double(second))) }
        await seedStore.flush()
        seedStore.close()

        var bytes = try temp.contents()
        let pageSize = 4096
        #expect(bytes.count > 3 * pageSize)
        for offset in (2 * pageSize) ..< (2 * pageSize + 512) { bytes[offset] = 0xA5 }
        try temp.seed(bytes)

        let store = temp.makeStore()
        store.record(observed(99_999))
        await store.flush()
        guard case .unavailable(.corrupt) = store.health.availability else {
            Issue.record("expected corrupt, got \(store.health.availability)")
            return
        }
        store.close()
        #expect(try temp.contents() == bytes)
    }

    @Test("a foreign database without a version is refused and left byte-identical")
    func unrecognizedSchema() async throws {
        let temp = TempHistoryDirectory()
        try temp.seed(Data())
        do {
            let db = try SQLiteDatabase(path: temp.path, create: false)
            try db.execute("CREATE TABLE other(x)")
        }
        let before = try temp.contents()
        let store = temp.makeStore()
        store.record(observed(0))
        await store.flush()
        #expect(store.health.availability == .unavailable(.unrecognizedSchema))
        store.close()
        #expect(try temp.contents() == before)
    }

    // MARK: - Runs

    @Test("an equal observation extends the open run")
    func extendsRun() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0))
        store.record(observed(60))
        store.record(observed(120))
        let runs = try await store.runs(source: sourceA, metric: .session)
        #expect(runs.count == 1)
        #expect(runs[0].firstSeenAt == at(0))
        #expect(runs[0].lastSeenAt == at(120))
        #expect(runs[0].isOpen)
        #expect(runs[0].usedPercent == 10)
        #expect(runs[0].reset == .at(F.farReset))
    }

    @Test("a changed value closes the run and opens a new one")
    func changedValue() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0, session: 10))
        store.record(observed(60, session: 10))
        store.record(observed(120, session: 11))
        let runs = try await store.runs(source: sourceA, metric: .session)
        #expect(runs.count == 2)
        #expect(runs[0].closeReason == .changed)
        #expect(runs[0].closedAt == at(120))
        #expect(runs[0].lastSeenAt == at(60))
        #expect(runs[1].firstSeenAt == at(120))
        #expect(runs[1].usedPercent == 11)
        #expect(runs[1].isOpen)
        // The weekly value did not change.
        #expect(try await store.runs(source: sourceA, metric: .weekly).count == 1)
    }

    @Test("resets: a shift under 120 s is the same boundary; repeated resets within an hour each start a run")
    func resets() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        let first = at(1800)
        store.record(observed(0, session: 40, sessionReset: .at(first)))
        store.record(observed(60, session: 40, sessionReset: .at(first.addingTimeInterval(119))))
        store.record(observed(120, session: 0, sessionReset: .notStarted))
        store.record(observed(180, session: 5, sessionReset: .at(at(3600))))
        store.record(observed(240, session: 5, sessionReset: .at(at(3720))))
        store.record(observed(300, session: 5, sessionReset: .unknown))
        let runs = try await store.runs(source: sourceA, metric: .session)
        #expect(runs.map(\.closeReason) == [.reset, .reset, .reset, .reset, nil])
        #expect(runs[0].lastSeenAt == at(60))
        #expect(runs[0].reset == .at(first))
        #expect(runs[1].reset == .notStarted)
        #expect(runs[2].reset == .at(at(3600)))
        #expect(runs[3].reset == .at(at(3720)))
        #expect(runs[4].reset == .unknown)
    }

    @Test("a gap beyond 2.5 × the captured interval closes the run at its last observation", arguments: [
        (RefreshInterval.oneMinute, 150.0),
        (.fiveMinutes, 750.0),
        (.manual, 600.0),
    ])
    func gaps(interval: RefreshInterval, gap: TimeInterval) async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0, interval: interval))
        store.record(observed(gap, interval: interval))
        store.record(observed(2 * gap + 1, interval: interval))
        let runs = try await store.runs(source: sourceA, metric: .session)
        #expect(runs.count == 2)
        #expect(runs[0].lastSeenAt == at(gap))
        #expect(runs[0].closeReason == .gap)
        #expect(runs[0].closedAt == at(gap))
        #expect(runs[1].firstSeenAt == at(2 * gap + 1))
        #expect(try await store.breaks(source: sourceA).isEmpty)
    }

    @Test("a failure closes every open run of the source and writes one global break")
    func failure() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0, scoped: [F.scoped("id:m", used: 3)]))
        store.record(observed(0, source: sourceB))
        store.record(.failed(source: sourceA, at: at(30)))
        store.record(observed(60))
        for metric in [HistoryMetric.session, .weekly] {
            let runs = try await store.runs(source: sourceA, metric: metric)
            #expect(runs.count == 2)
            #expect(runs[0].closeReason == .failure)
            #expect(runs[0].closedAt == at(30))
            #expect(runs[1].firstSeenAt == at(60))
        }
        let scoped = try await store.runs(source: sourceA, metric: .scoped, modelKey: "id:m")
        #expect(scoped.map(\.closeReason) == [.failure])
        let breaks = try await store.breaks(source: sourceA)
        #expect(breaks.map(\.reason) == [.failure])
        #expect(breaks.first?.at == at(30))
        #expect(breaks.first?.streamID == nil)
        #expect(try await store.runs(source: sourceB, metric: .session).allSatisfy(\.isOpen))
    }

    @Test("a missing, unavailable or ambiguous metric closes only its own stream", arguments: ["missing", "unavailable", "ambiguous"])
    func missingMetric(kind: String) async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0, scoped: [F.scoped("id:m", used: 3), F.scoped("id:n", used: 4)]))
        let rows: [ScopedWeeklyLimit] = switch kind {
        case "missing": [F.scoped("id:n", used: 4)]
        case "unavailable": [F.scoped("id:m", used: nil), F.scoped("id:n", used: 4)]
        default: [F.scoped("id:m", used: nil, ambiguous: true), F.scoped("id:m", used: nil, ambiguous: true), F.scoped("id:n", used: 4)]
        }
        store.record(observed(60, scoped: rows))
        let m = try await store.runs(source: sourceA, metric: .scoped, modelKey: "id:m")
        #expect(m.count == 1)
        #expect(m[0].closeReason == .missing)
        #expect(m[0].closedAt == at(60))
        #expect(m[0].lastSeenAt == at(0))
        let n = try await store.runs(source: sourceA, metric: .scoped, modelKey: "id:n")
        #expect(n.count == 1 && n[0].isOpen && n[0].lastSeenAt == at(60))
        #expect(try await store.runs(source: sourceA, metric: .session).allSatisfy(\.isOpen))

        let mStream = try #require(try await store.streams().first { $0.modelKey == "id:m" })
        let breaks = try await store.breaks(source: sourceA)
        #expect(breaks.count == 1)
        #expect(breaks.first?.reason == .missing)
        #expect(breaks.first?.streamID == mStream.id)

        // Still missing: no further break.
        store.record(observed(120, scoped: rows))
        #expect(try await store.breaks(source: sourceA).count == 1)
    }

    @Test("a missing session breaks session only")
    func missingSession() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0))
        store.record(observed(60, session: nil))
        #expect(try await store.runs(source: sourceA, metric: .session).map(\.closeReason) == [.missing])
        #expect(try await store.runs(source: sourceA, metric: .weekly).map(\.lastSeenAt) == [at(60)])
    }

    @Test("a source change closes the old source's runs with a break and leaves others alone")
    func sourceChange() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0))
        store.record(observed(0, source: sourceB))
        store.record(.sourceChanged(oldSource: sourceA, at: at(10)))
        store.record(observed(20, source: sourceB))
        let a = try await store.runs(source: sourceA, metric: .session)
        #expect(a.map(\.closeReason) == [.source])
        #expect(a[0].closedAt == at(10))
        #expect(try await store.breaks(source: sourceA).map(\.reason) == [.source])
        #expect(try await store.runs(source: sourceB, metric: .session).map(\.lastSeenAt) == [at(20)])
        #expect(try await store.breaks(source: sourceB).isEmpty)
    }

    // MARK: - Faults

    @Test("a rolled-back close/open leaves the old run intact; reopening finds one open run")
    func rollbackAndReopen() async throws {
        let temp = TempHistoryDirectory()
        do {
            let store = temp.makeStore()
            store.record(observed(0, session: 10))
            store.injectFault(at: .afterClose)
            store.record(observed(60, session: 20))
            await store.flush()
            #expect(store.health.writeError == "injected fault")
            #expect(store.health.message?.hasPrefix("History could not be saved") == true)
            let runs = try await store.runs(source: sourceA, metric: .session)
            #expect(runs.count == 1)
            #expect(runs[0].isOpen && runs[0].lastSeenAt == at(0) && runs[0].usedPercent == 10)
            #expect(try await store.runs(source: sourceA, metric: .weekly).map(\.lastSeenAt) == [at(0)])
            store.close()
        }
        let reopened = temp.makeStore()
        reopened.record(observed(90, session: 30))
        await reopened.flush()
        #expect(reopened.health.writeError == nil)
        let runs = try await reopened.runs(source: sourceA, metric: .session)
        #expect(runs.filter(\.isOpen).count == 1)
        #expect(runs.map(\.usedPercent) == [10, 30])
        #expect(runs[0].closeReason == .gap)
        #expect(runs[0].closedAt == at(0))
    }

    @Test("after a lost write an equal observation does not extend the old run")
    func pendingDiscontinuity() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0, session: 20))
        store.injectFault(at: .beforeCommit)
        store.record(.failed(source: sourceA, at: at(5)))
        store.record(observed(6, session: 20))
        let runs = try await store.runs(source: sourceA, metric: .session)
        #expect(runs.count == 2)
        #expect(runs[0].lastSeenAt == at(0))
        #expect(runs[0].closedAt == at(0))
        #expect(runs[0].closeReason == .failure)
        #expect(runs[1].firstSeenAt == at(6) && runs[1].isOpen)
        let breaks = try await store.breaks(source: sourceA)
        #expect(breaks.map(\.reason) == [.failure])
        #expect(breaks.first?.at == at(5))
        #expect(breaks.first?.streamID == nil)
        #expect(store.health.writeError == nil)
    }

    @Test("the partial unique index allows only one open run per stream")
    func uniqueOpenRun() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0))
        let stream = try #require(try await store.runs(source: sourceA, metric: .session).first?.streamID)
        store.close()

        let db = try SQLiteDatabase(path: temp.path, create: false)
        let insert = "INSERT INTO runs(stream_id, first_seen_at, last_seen_at, used_percent, reset_kind, closed_at) VALUES (?, 0, 0, 1, 'unknown', ?)"
        let error = #expect(throws: SQLiteError.self) { try db.run(insert, [.integer(stream), .null]) }
        #expect(error?.primaryCode == 19) // SQLITE_CONSTRAINT
        try db.run(insert, [.integer(stream), .real(1)]) // closed runs are unconstrained
    }

    // MARK: - Restart, retention, clear

    @Test("a new store on the same file reads the same runs and keeps extending them")
    func restart() async throws {
        let temp = TempHistoryDirectory()
        let first = temp.makeStore()
        first.record(observed(0, session: 10))
        first.record(observed(60, session: 12))
        let before = try await first.runs(source: sourceA, metric: .session)
        first.close()

        let second = temp.makeStore()
        #expect(try await second.runs(source: sourceA, metric: .session) == before)
        // A run left open by the previous instance is closed at its own last observation, never
        // extended across the restart.
        second.record(observed(120, session: 12))
        let after = try await second.runs(source: sourceA, metric: .session)
        try #require(after.map(\.usedPercent) == [10, 12, 12])
        #expect(after[1].closeReason == .gap)
        #expect(after[1].closedAt == at(60))
        #expect(after[2].firstSeenAt == at(120) && after[2].isOpen)
        // Later events of this instance extend as usual.
        second.record(observed(180, session: 12))
        #expect(try await second.runs(source: sourceA, metric: .session).last?.lastSeenAt == at(180))
    }

    @Test("a lost failure write followed by a restart never merges across the failure")
    func lostFailureThenRestart() async throws {
        let temp = TempHistoryDirectory()
        do {
            let store = temp.makeStore()
            store.record(observed(0, interval: .fiveMinutes, session: 20))
            store.injectFault(at: .beforeCommit)
            store.record(.failed(source: sourceA, at: at(300)))
            await store.flush()
            store.close()
        }
        let reopened = temp.makeStore()
        reopened.record(observed(360, interval: .fiveMinutes, session: 20))
        let runs = try await reopened.runs(source: sourceA, metric: .session)
        try #require(runs.count == 2)
        #expect(runs[0].lastSeenAt == at(0))
        #expect(runs[0].closedAt == at(0))
        #expect(runs[0].closeReason == .gap)
        #expect(runs[1].firstSeenAt == at(360) && runs[1].isOpen)
        #expect(try await reopened.runs(source: sourceA, metric: .weekly).count == 2)
    }

    @Test("a newer-schema file with a hot journal is refused; file and sidecars stay byte-identical")
    func newerSchemaWithHotJournal() async throws {
        let temp = TempHistoryDirectory()
        let needsRecovery = try temp.seedHotJournal(
            committed: """
            CREATE TABLE future(x);
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50)
            INSERT INTO future SELECT randomblob(3000) FROM n;
            PRAGMA user_version = 2;
            """,
            uncommitted: """
            UPDATE future SET x = randomblob(3000);
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
            INSERT INTO future SELECT randomblob(1500) FROM n;
            """
        )
        #expect(needsRecovery)
        let before = try temp.fileAndSidecars()
        #expect(Set(before.keys) == ["", "-journal"])

        let store = temp.makeStore()
        store.record(observed(0))
        await store.flush()
        #expect(store.health.availability == .unavailable(.newerSchema(version: 2)))
        store.close()
        #expect(try temp.fileAndSidecars() == before)
    }

    @Test("version 2 committed only in the WAL is refused before any read-write open; all files byte-identical")
    func newerSchemaInWAL() async throws {
        let temp = TempHistoryDirectory()
        try temp.seedWAL(
            checkpointed: try Self.schemaSQL(),
            walOnly: "PRAGMA user_version = 2; CREATE TABLE new(x); INSERT INTO new VALUES (1);",
            copyWhileOpen: true
        )
        let before = try temp.fileAndSidecars()
        #expect(before["-wal"].map { !$0.isEmpty } == true)

        let store = temp.makeStore()
        store.record(observed(0))
        store.clear(at: at(1))
        await store.flush()
        #expect(store.health.availability == .unavailable(.walMode))
        #expect(store.health.message?.contains("left untouched") == true)
        store.close()
        #expect(try temp.fileAndSidecars() == before)
    }

    @Test("a cleanly closed WAL-mode v1 file is refused and left byte-identical")
    func walModeV1() async throws {
        let temp = TempHistoryDirectory()
        try temp.seedWAL(checkpointed: try Self.schemaSQL(), walOnly: nil, copyWhileOpen: false)
        let before = try temp.fileAndSidecars()
        #expect(before["-wal"]?.isEmpty ?? true) // refused by the header alone
        #expect(HistoryStore.usesWriteAheadLog(path: temp.path))

        let store = temp.makeStore()
        store.record(observed(0))
        await store.flush()
        #expect(store.health.availability == .unavailable(.walMode))
        store.close()
        #expect(try temp.fileAndSidecars() == before)
    }

    @Test("our own v1 file with a hot journal is recovered and opened")
    func ownFileWithHotJournal() async throws {
        let temp = TempHistoryDirectory()
        let schema = try Self.schemaSQL()
        let needsRecovery = try temp.seedHotJournal(
            committed: schema + """
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50)
            INSERT INTO meta(key, value) SELECT 'filler' || i, hex(randomblob(1500)) FROM n;
            """,
            uncommitted: """
            UPDATE meta SET value = 'uncommitted' || hex(randomblob(1500));
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
            INSERT INTO meta(key, value) SELECT 'extra' || i, hex(randomblob(700)) FROM n;
            """
        )
        #expect(needsRecovery)
        let store = temp.makeStore()
        await store.flush()
        #expect(store.health.availability == .ready)
        store.close()
        #expect(try Set(temp.fileAndSidecars().keys) == [""])
        let db = try SQLiteDatabase(path: temp.path, create: false)
        #expect(try db.query("SELECT count(*) FROM meta") { $0.integer(0) } == [50])
        #expect(try db.query("SELECT count(*) FROM meta WHERE value LIKE 'uncommitted%'") { $0.integer(0) } == [0])
    }

    /// The v1 schema as an SQL script, read back from a scratch database.
    private static func schemaSQL() throws -> String {
        let scratch = TempHistoryDirectory()
        try FileManager.default.createDirectory(at: scratch.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: scratch.path, create: true)
        try HistoryStore.createSchema(db)
        let statements = try db.query("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY rowid") { $0.text(0) }
        db.close()
        return statements.joined(separator: ";\n") + ";\nPRAGMA user_version = 1;\n"
    }

    @Test("retention drops closed runs and breaks older than a year and orphan streams, on open and daily on write")
    func retention() async throws {
        let temp = TempHistoryDirectory()
        let day: TimeInterval = 24 * 60 * 60
        let now = MutableNow(F.t0)
        let store = temp.makeStore(now: { now.date })
        store.record(observed(0, scoped: [F.scoped("id:old", used: 1)])) // closed by the failure below
        store.record(.failed(source: sourceA, at: at(60)))
        store.record(observed(120, source: sourceB)) // stays open
        store.record(observed(200 * day, session: 50, weekly: nil)) // recent, closed by the change below
        store.record(observed(200 * day + 60, session: 51, weekly: nil))
        await store.flush()

        // The daily check runs on the next write once a day has passed since the last one.
        now.date = at(365 * day + 121)
        store.record(.failed(source: "https://unrelated.example.com", at: at(365 * day + 121)))
        let streams = try await store.streams()
        #expect(Set(streams.map { "\($0.source)|\($0.metric.rawValue)|\($0.modelKey)" }) == [
            "\(sourceA)|session|", "\(sourceB)|session|", "\(sourceB)|weekly|",
        ])
        #expect(try await store.runs(source: sourceA, metric: .session).map(\.usedPercent) == [50, 51])
        #expect(try await store.runs(source: sourceB, metric: .session).count == 1)
        #expect(try await store.breaks(source: sourceA).isEmpty)
        #expect(try await store.breaks(source: "https://unrelated.example.com").count == 1)
        store.close()

        // On open: a further year later only the open runs and their streams remain.
        let reopened = temp.makeStore(now: { at(800 * day) })
        await reopened.flush()
        #expect(try await reopened.runs(source: sourceA, metric: .session).map(\.usedPercent) == [51])
        #expect(try await reopened.breaks(source: sourceA).isEmpty)
        #expect(try await reopened.breaks(source: "https://unrelated.example.com").isEmpty)
    }

    @Test("clear removes everything recorded before it, also when queued, and ignores older events")
    func clear() async throws {
        let temp = TempHistoryDirectory()
        let store = temp.makeStore()
        store.record(observed(0))
        store.record(observed(60, session: 30))
        store.record(.failed(source: sourceA, at: at(90)))
        let cleared = await withCheckedContinuation { continuation in
            store.clear(at: at(100)) { continuation.resume(returning: $0) }
            store.record(observed(95, session: 40)) // accepted before the clear moment: ignored
            store.record(observed(100, session: 50))
        }
        #expect((try? cleared.get()) != nil)
        #expect(try await store.breaks(source: sourceA).isEmpty)
        let runs = try await store.runs(source: sourceA, metric: .session)
        #expect(runs.map(\.usedPercent) == [50])
        #expect(runs[0].firstSeenAt == at(100))
        store.close()

        // The cutoff survives a restart.
        let reopened = temp.makeStore()
        reopened.record(observed(99, session: 60))
        #expect(try await reopened.runs(source: sourceA, metric: .session).map(\.usedPercent) == [50])
        #expect(try temp.folderContents() == ["history.sqlite"])
    }

    @Test("clear on an unavailable store reports it and touches nothing")
    func clearUnavailable() async throws {
        let temp = TempHistoryDirectory()
        let garbage = Data(repeating: 0x42, count: 2048)
        try temp.seed(garbage)
        let store = temp.makeStore()
        let result = await withCheckedContinuation { continuation in
            store.clear(at: at(0)) { continuation.resume(returning: $0) }
        }
        guard case .failure(.unavailable) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        store.close()
        #expect(try temp.contents() == garbage)
    }
}
