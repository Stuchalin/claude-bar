import Foundation
import SQLite3

/// An SQLite result code with the connection's error message.
struct SQLiteError: Error, Equatable, CustomStringConvertible {
    let code: Int32
    let message: String

    /// The primary result code (`SQLITE_CORRUPT`, `SQLITE_NOTADB`, `SQLITE_CONSTRAINT`, …).
    var primaryCode: Int32 { code & 0xFF }

    var description: String { "SQLite error \(code): \(message)" }
}

/// A value bound to a statement parameter.
enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}

/// The current row of a stepping statement.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    func optionalReal(_ column: Int32) -> Double? { isNull(column) ? nil : real(column) }
    func optionalInteger(_ column: Int32) -> Int64? { isNull(column) ? nil : integer(column) }
    func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
}

/// A single SQLite connection. Not thread-safe: the owner confines it to one serial queue.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Opens the file read-write; `create` also creates a missing file.
    init(path: String, create: Bool) throws {
        var flags = SQLITE_OPEN_READWRITE
        if create { flags |= SQLITE_OPEN_CREATE }
        var db: OpaquePointer?
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(db)
            throw SQLiteError(code: code, message: message)
        }
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 2000)
        handle = db
    }

    /// Opens the file through an `immutable=1` read-only URI: SQLite takes no locks, never runs
    /// hot-journal recovery and never creates or touches sidecar files, so the file and its
    /// `-journal`/`-wal`/`-shm` stay byte-identical whatever is inside.
    init(probingImmutable path: String) throws {
        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components.string else { throw SQLiteError(code: SQLITE_CANTOPEN, message: "bad path") }
        var db: OpaquePointer?
        let code = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(db)
            throw SQLiteError(code: code, message: message)
        }
        sqlite3_extended_result_codes(db, 1)
        handle = db
    }

    deinit { close() }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    /// Runs one or more statements without parameters or results.
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(connection(), sql, nil, nil, nil))
    }

    /// Runs one statement with parameters, discarding any result rows.
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        try withStatement(sql, bindings) { statement in
            while try step(statement) {}
        }
    }

    /// Runs one statement and maps every result row.
    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        try withStatement(sql, bindings) { statement in
            var rows: [T] = []
            while try step(statement) { rows.append(try map(SQLiteRow(statement: statement))) }
            return rows
        }
    }

    /// Runs `body` inside `BEGIN IMMEDIATE … COMMIT`, rolling back when it throws or the commit fails.
    func immediateTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Private

    private func connection() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "connection closed") }
        return handle
    }

    private func withStatement<T>(_ sql: String, _ bindings: [SQLiteValue], _ body: (OpaquePointer) throws -> T) throws -> T {
        let db = try connection()
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement else { throw SQLiteError(code: SQLITE_MISUSE, message: "empty statement") }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case let .integer(number): sqlite3_bind_int64(statement, index, number)
            case let .real(number): sqlite3_bind_double(statement, index, number)
            case let .text(string): sqlite3_bind_text(statement, index, string, -1, Self.transient)
            }
            try check(code)
        }
        return try body(statement)
    }

    /// Steps once; `true` when a row is available, `false` when done.
    private func step(_ statement: OpaquePointer) throws -> Bool {
        let code = sqlite3_step(statement)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error(code)
        }
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw error(code) }
    }

    private func error(_ code: Int32) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
        let extended = handle.map { sqlite3_extended_errcode($0) } ?? code
        return SQLiteError(code: extended == 0 ? code : extended, message: message)
    }

    /// `SQLITE_TRANSIENT`: SQLite copies bound text before the call returns.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
}
