import Foundation
import SQLite3

/// The smallest wrapper over the system's libsqlite3 that the history store
/// needs: no dependency, prepared statements reused, errors thrown.
final class SQLiteDatabase {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private(set) var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// SQLITE_TRANSIENT: SQLite copies bound text before the call returns.
    nonisolated(unsafe) private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(path)"
            sqlite3_close(handle)
            throw Failure(message: message)
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "error"
            sqlite3_free(error)
            throw Failure(message: "\(message) in: \(sql.prefix(80))")
        }
    }

    /// A cached prepared statement, reset and with bindings cleared.
    func statement(_ sql: String) throws -> Statement {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return Statement(handle: cached)
        }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw Failure(message: "\(String(cString: sqlite3_errmsg(handle))) in: \(sql.prefix(80))")
        }
        statements[sql] = prepared
        return Statement(handle: prepared)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    struct Statement {
        let handle: OpaquePointer

        @discardableResult
        func bind(_ values: Any?...) -> Statement {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case nil: sqlite3_bind_null(handle, index)
                case let v as Int: sqlite3_bind_int64(handle, index, Int64(v))
                case let v as Int64: sqlite3_bind_int64(handle, index, v)
                case let v as UInt8: sqlite3_bind_int64(handle, index, Int64(v))
                case let v as Bool: sqlite3_bind_int64(handle, index, v ? 1 : 0)
                case let v as Double: sqlite3_bind_double(handle, index, v)
                case let v as String: sqlite3_bind_text(handle, index, v, -1, SQLiteDatabase.transient)
                default: sqlite3_bind_null(handle, index)
                }
            }
            return self
        }

        /// Clears the last run and its bindings, to reuse within a transaction.
        func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        /// Runs a statement that returns no rows.
        func run() throws {
            let result = sqlite3_step(handle)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw Failure(message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
            }
        }

        /// Steps through the rows.
        func rows(_ body: (Row) throws -> Void) throws {
            while true {
                let result = sqlite3_step(handle)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else {
                    throw Failure(message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
                }
                try body(Row(handle: handle))
            }
        }
    }

    struct Row {
        let handle: OpaquePointer
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
        func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
        func string(_ column: Int32) -> String? {
            guard let text = sqlite3_column_text(handle, column) else { return nil }
            return String(cString: text)
        }
    }
}
