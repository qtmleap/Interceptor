import Foundation
import SQLite3

// No SQL or raw SQLite handles are exposed by the public API.
final class SQLiteDatabase {
    enum Value { case text(String), integer(Int64), real(Double), blob(Data), null }
    let handle: OpaquePointer
    init(url: URL) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw WorkflowStorageError.sqlite(rc)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ bindings: [Value] = []) throws { _ = try query(sql, bindings) }
    func query(_ sql: String, _ bindings: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw error(code) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            let i = Int32(index + 1), rc: Int32
            switch binding {
            case .text(let value): rc = value.withCString { sqlite3_bind_text(statement, i, $0, -1, transient) }
            case .integer(let value): rc = sqlite3_bind_int64(statement, i, value)
            case .real(let value): rc = sqlite3_bind_double(statement, i, value)
            case .blob(let value):
                rc = value.withUnsafeBytes { buffer in
                    if buffer.isEmpty { return sqlite3_bind_zeroblob(statement, i, 0) }
                    return sqlite3_bind_blob(statement, i, buffer.baseAddress, Int32(buffer.count), transient)
                }
            case .null: rc = sqlite3_bind_null(statement, i)
            }
            guard rc == SQLITE_OK else { throw error(rc) }
        }
        var rows: [[Value]] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var row: [Value] = []
            for i in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, i)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, i)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, i))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    row.append(.blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, i)!, count: count)))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
    }
    private func error(_ rc: Int32) -> WorkflowStorageError {
        if rc & 0xff == SQLITE_CORRUPT || rc & 0xff == SQLITE_NOTADB { return .corruptStore }
        return .sqlite(rc)
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body(); try execute("COMMIT"); return value
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
extension SQLiteDatabase.Value {
    var data: Data? { if case .blob(let data) = self { return data }; return nil }
    var int: Int64? { if case .integer(let n) = self { return n }; return nil }
}
