import Foundation
import SQLite3
import Darwin

struct SQLiteTable: Identifiable, Hashable, Sendable {
    let name: String
    let type: String
    let sql: String
    var id: String { name }
}

struct SQLiteSchema: Sendable {
    let tables: [SQLiteTable]
    let truncated: Bool
}

struct SQLitePage: Sendable {
    let columns: [String]
    let rows: [[String]]
    let hasMore: Bool
}

actor SQLiteDocument {
    static let pageSize = 100
    static let maximumOffset = 1_000_000
    private let url: URL

    init(url: URL) { self.url = url }

    func schema() throws -> SQLiteSchema {
        try withDatabase { database in
            try withStatement(database, sql: "SELECT name, type, coalesce(sql, '') FROM main.sqlite_schema WHERE type IN ('table', 'view') ORDER BY name COLLATE NOCASE LIMIT 513") { statement in
                var tables: [SQLiteTable] = []
                while try step(statement, database: database) {
                    if tables.count == 512 { return SQLiteSchema(tables: tables, truncated: true) }
                    let name = text(statement, column: 0, maximumBytes: 4096)
                    guard sqlite3_column_bytes(statement, 0) <= 4096 else { throw RunnerError(localized: "テーブル名が表示上限を超えています。") }
                    tables.append(SQLiteTable(name: name, type: text(statement, column: 1), sql: text(statement, column: 2, maximumBytes: 16_384)))
                }
                return SQLiteSchema(tables: tables, truncated: false)
            }
        }
    }

    func page(table: SQLiteTable, offset: Int) throws -> SQLitePage {
        guard offset >= 0, offset <= Self.maximumOffset else { throw RunnerError(localized: "表示できる行の範囲を超えています。") }
        // Identifiers cannot be bound; quote them rather than interpolating SQL.
        let identifier = "\"" + table.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return try withDatabase { database in
            try withStatement(database, sql: "SELECT * FROM main.\(identifier) LIMIT \(Self.pageSize + 1) OFFSET \(offset)") { statement in
                let columns = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
                var rows: [[String]] = []
                while try step(statement, database: database) {
                    if rows.count == Self.pageSize { return SQLitePage(columns: columns, rows: rows, hasMore: true) }
                    rows.append((0..<sqlite3_column_count(statement)).map { value(statement, column: $0) })
                }
                return SQLitePage(columns: columns, rows: rows, hasMore: false)
            }
        }
    }

    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try Task.checkCancellation()
        // NOFOLLOW rejects symlinked parents too (/var on Apple platforms).
        // Resolve only the private snapshot, never the source database.
        guard let path = realpath(url.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(path) }
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let connection { sqlite3_close(connection) } }
        guard result == SQLITE_OK, let database = connection else { throw databaseError(connection) }
        sqlite3_busy_timeout(database, 500)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 8 * 1024 * 1024)
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 1_048_576)
        sqlite3_limit(database, SQLITE_LIMIT_COLUMN, 128)
        sqlite3_limit(database, SQLITE_LIMIT_EXPR_DEPTH, 100)
        sqlite3_limit(database, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_limit(database, SQLITE_LIMIT_VDBE_OP, 100_000)
        let budget = QueryBudget()
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            return Unmanaged<QueryBudget>.fromOpaque(context).takeUnretainedValue().shouldStop ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            withExtendedLifetime(budget) {}
        }
        guard sqlite3_exec(database, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; PRAGMA cache_size=-2048;", nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        sqlite3_set_authorizer(database, { _, action, _, argument, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE: return SQLITE_OK
            case SQLITE_FUNCTION:
                return argument.map { String(cString: $0).lowercased() == "load_extension" } == true ? SQLITE_DENY : SQLITE_OK
            default: return SQLITE_DENY
            }
        }, nil)
        return try operation(database)
    }

    private func withStatement<T>(_ database: OpaquePointer, sql: String, operation: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard result == SQLITE_OK, let statement, sqlite3_stmt_readonly(statement) != 0 else { throw databaseError(database) }
        return try operation(statement)
    }

    private func step(_ statement: OpaquePointer, database: OpaquePointer) throws -> Bool {
        try Task.checkCancellation()
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError(database)
        }
    }

    private func text(_ statement: OpaquePointer, column: Int32, maximumBytes: Int = 1024) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: min(count, maximumBytes)), as: UTF8.self) + (count > maximumBytes ? L("…（省略）") : "")
    }

    private func value(_ statement: OpaquePointer, column: Int32) -> String {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL: return "NULL"
        case SQLITE_INTEGER: return String(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return String(sqlite3_column_double(statement, column))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let bytes = sqlite3_column_blob(statement, column) else { return "BLOB · 0 bytes" }
            let prefix = UnsafeRawBufferPointer(start: bytes, count: min(count, 32)).map { String(format: "%02X", $0) }.joined(separator: " ")
            return "BLOB · \(count) bytes · \(prefix)" + (count > 32 ? " …" : "")
        default:
            let value = text(statement, column: column)
            return value.isEmpty ? L("（空文字列）") : value
        }
    }

    private func databaseError(_ database: OpaquePointer?) -> RunnerError {
        if Task.isCancelled { return RunnerError(localized: "SQLiteの読み取りを中止しました。") }
        if let database, sqlite3_errcode(database) == SQLITE_INTERRUPT { return RunnerError(localized: "SQLiteの処理時間が上限（2秒）を超えました。") }
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? L("データベースを開けません。")
        return RunnerError(localized: "SQLite: \(String(describing: message))")
    }

    private final class QueryBudget {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var shouldStop: Bool {
            let cancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false }
            return cancelled || ProcessInfo.processInfo.systemUptime >= deadline
        }
    }
}
