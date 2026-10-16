@testable import ClaudeBarCore
import Foundation

/// A fresh directory under the temporary directory, removed when released. History tests never
/// touch ~/Library/Application Support.
final class TempHistoryDirectory {
    let directory: URL
    let url: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeBarHistoryTests.\(UUID().uuidString)", directoryHint: .isDirectory)
        url = directory.appending(path: "nested/history.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var path: String { url.path(percentEncoded: false) }

    /// Opens a store on the file; `now` drives retention.
    func makeStore(now: @escaping @Sendable () -> Date = { RefreshFixtures.t0 }) -> HistoryStore {
        HistoryStore(url: url, now: now)
    }

    /// Writes `data` as the history file, creating its folder.
    func seed(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func contents() throws -> Data {
        try Data(contentsOf: url)
    }

    /// The history file and every SQLite sidecar that exists, by suffix.
    func fileAndSidecars() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let file = URL(filePath: path + suffix)
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                result[suffix] = try Data(contentsOf: file)
            }
        }
        return result
    }

    /// Builds a WAL-mode database in a writer folder: `checkpointed` is written and checkpointed
    /// into the main file, `walOnly` is committed but left in the `-wal` (autocheckpoint off).
    /// With `copyWhileOpen` the main file and every sidecar are copied while the writer is still
    /// open (WAL content present); otherwise after a clean close (WAL-mode header; the `-wal`
    /// is absent or empty, macOS's SQLite may keep an empty one).
    func seedWAL(checkpointed: String, walOnly: String?, copyWhileOpen: Bool) throws {
        let writerDir = directory.appending(path: "wal-writer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: writerDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writerPath = writerDir.appending(path: "w.sqlite").path(percentEncoded: false)
        let writer = try SQLiteDatabase(path: writerPath, create: true)
        _ = try writer.query("PRAGMA journal_mode = WAL") { _ in () }
        try writer.execute("PRAGMA wal_autocheckpoint = 0")
        try writer.execute(checkpointed)
        _ = try writer.query("PRAGMA wal_checkpoint(TRUNCATE)") { _ in () }
        if let walOnly { try writer.execute(walOnly) }
        if !copyWhileOpen { writer.close() }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: writerPath + suffix) {
            try FileManager.default.copyItem(atPath: writerPath + suffix, toPath: path + suffix)
        }
        writer.close()
    }

    /// Leaves the history file in the state of a writer killed mid-transaction: `committed` is
    /// committed, `uncommitted` runs in an open transaction with a tiny page cache so its pages
    /// spill into the main file (it should rewrite existing rows, so original pages are journaled), and the main file plus its hot `-journal` are copied at that
    /// moment. Returns `true` when the copied main file differs from the committed state, i.e.
    /// the journal is really needed to recover it.
    func seedHotJournal(committed: String, uncommitted: String) throws -> Bool {
        let writerDir = directory.appending(path: "writer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: writerDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writerPath = writerDir.appending(path: "w.sqlite").path(percentEncoded: false)
        let writer = try SQLiteDatabase(path: writerPath, create: true)
        try writer.execute(committed)
        try writer.execute("PRAGMA cache_size = 10; PRAGMA cache_spill = 10;")
        try writer.execute("BEGIN IMMEDIATE")
        try writer.execute(uncommitted)
        try FileManager.default.copyItem(atPath: writerPath, toPath: path)
        try FileManager.default.copyItem(atPath: writerPath + "-journal", toPath: path + "-journal")
        try writer.execute("ROLLBACK")
        writer.close()
        let committedState = try Data(contentsOf: URL(filePath: writerPath))
        return try contents() != committedState
    }

    /// Names of files in the history folder (to spot stray journals).
    func folderContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path(percentEncoded: false)).sorted()
    }
}

/// A clock value tests can move between store operations.
final class MutableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Collects the coordinator's history events.
final class RecordingSpy: HistoryRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HistoryEvent] = []

    var events: [HistoryEvent] { lock.withLock { recorded } }

    func record(_ event: HistoryEvent) {
        lock.withLock { recorded.append(event) }
    }
}

/// Forwards each event to several recorders.
struct FanOutRecording: HistoryRecording {
    let recorders: [any HistoryRecording]

    func record(_ event: HistoryEvent) {
        recorders.forEach { $0.record(event) }
    }
}

extension HistoryStore {
    /// Runs of the stream `metric`/`modelKey` of `source`, or `[]` when the stream does not exist.
    func runs(source: String, metric: HistoryMetric, modelKey: String = "") async throws -> [HistoryRun] {
        await flush()
        guard let stream = try await streams().first(where: {
            $0.source == source && $0.metric == metric && $0.modelKey == modelKey
        }) else { return [] }
        return try await runs(streamID: stream.id)
    }
}
