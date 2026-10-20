import Foundation
import SQLite3

public enum SQLValue: Equatable, Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null

    public var int64: Int64? {
        switch self {
        case .integer(let v): return v
        case .real(let v): return Int64(v)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }

    public var string: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    public var data: Data? {
        if case .blob(let v) = self { return v }
        return nil
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// Minimal synchronous SQLite wrapper. Callers keep access on one thread (the main thread).
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `path` may be ":memory:" for tests.
    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: result, message: message)
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
    }

    deinit {
        sqlite3_close(handle)
    }

    public var userVersion: Int {
        get { Int((try? query("PRAGMA user_version"))?.first?["user_version"]?.int64 ?? 0) }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    public func execute(_ sql: String, _ parameters: [SQLValue] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw error(result) }
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: SQLValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error(result) }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                row[name] = value(statement, index)
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw error(result) }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .integer(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(v.count), Self.transient)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func value(_ statement: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}
