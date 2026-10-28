import Foundation
import SQLite3

/// Every call, including full results, in SQLite. Holds prod data, so: dir 0700 + file 0600,
/// excluded from Time Machine, deleted rows zeroed (secure_delete), 7-day retention.
final class QueryLog: @unchecked Sendable {  // all access goes through `lock`
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let retentionDays: Int

    static let defaultDir = URL.applicationSupportDirectory.appending(path: "db-proxy")

    init(dir: URL = QueryLog.defaultDir, retentionDays: Int = 7) throws {
        self.retentionDays = retentionDays
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Re-applied every start, so a deleted-and-recreated dir is excluded again. Covers -wal/-shm too.
        var dirURL = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dirURL.setResourceValues(values)

        let path = dir.appending(path: "log.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw ConfigError("cannot open log \(path)")
        }
        chmod(path, 0o600)
        try exec("""
            PRAGMA auto_vacuum = INCREMENTAL;
            PRAGMA journal_mode = WAL;
            PRAGMA secure_delete = ON;
            CREATE TABLE IF NOT EXISTS log (
                id INTEGER PRIMARY KEY,
                ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                agent TEXT NOT NULL, env TEXT NOT NULL, db TEXT NOT NULL, mode TEXT NOT NULL,
                sql TEXT NOT NULL, duration_ms INTEGER NOT NULL, row_count INTEGER,
                is_error INTEGER NOT NULL, response TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS log_ts ON log (ts);
            """)
    }

    func write(agent: String, env: String, db dbName: String, mode: String, sql: String,
               durationMs: Int, outcome: QueryOutcome) {
        lock.withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, """
                INSERT INTO log (agent, env, db, mode, sql, duration_ms, row_count, is_error, response)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, -1, &stmt, nil) == SQLITE_OK else { return }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, text) in [agent, env, dbName, mode, sql].enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), text, -1, transient)
            }
            sqlite3_bind_int64(stmt, 6, Int64(durationMs))
            if let n = outcome.rowCount { sqlite3_bind_int64(stmt, 7, Int64(n)) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_int(stmt, 8, outcome.isError ? 1 : 0)
            sqlite3_bind_text(stmt, 9, outcome.json, -1, transient)
            if sqlite3_step(stmt) != SQLITE_DONE {
                FileHandle.standardError.write(Data("query log write failed: \(String(cString: sqlite3_errmsg(db)))\n".utf8))
            }
        }
    }

    /// Deletes rows older than the retention window and returns freed pages to the filesystem.
    func prune() {
        lock.withLock {
            _ = try? exec("""
                DELETE FROM log WHERE ts < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-\(retentionDays) days');
                PRAGMA incremental_vacuum;
                """)
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            defer { sqlite3_free(err) }
            throw ConfigError("query log: \(err.map { String(cString: $0) } ?? "unknown error")")
        }
    }
}
