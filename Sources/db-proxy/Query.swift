import Foundation
import Logging
import os
import PostgresNIO

enum Mode: String, Sendable { case read, write }

/// A failure the proxy itself reports (not a Postgres error).
struct QueryError: Error {
    let message: String
    init(_ m: String) { message = m }
}

/// A finished call, already serialized: `json` is exactly what the agent receives and what gets logged.
struct QueryOutcome: Sendable {
    let json: String
    let rowCount: Int?
    let isError: Bool
}

struct QuerySettings: Sendable {
    let statementTimeout: String
    let lockTimeout: String?
    let maxResultBytes: Int
    /// Explains a lease timeout (unreachable host, bad password, missing database, busy pool).
    let diagnose: @Sendable () async -> String
    var leaseTimeout: Duration = .seconds(5)
}

/// Runs one agent call. Read calls get one retry on a fresh connection if the connection broke
/// (e.g. VPN blip); writes never retry, since the first attempt may have committed.
func execute(client: PostgresClient, serverName: String, sql: String, mode: Mode,
             settings: QuerySettings, logger: Logger) async -> QueryOutcome {
    func attempt() async throws -> QueryOutcome {
        try await runQuery(client: client, sql: sql, mode: mode, settings: settings, logger: logger)
    }
    do {
        do {
            return try await attempt()
        } catch where mode == .read && isConnectionFailure(error) {
            logger.info("retrying read on \(serverName) after connection failure: \(error)")
            return try await attempt()
        }
    } catch is LeaseTimeout {
        return QueryOutcome(json: serialize(["error": await settings.diagnose()]), rowCount: nil, isError: true)
    } catch {
        return QueryOutcome(json: serialize(errorBody(error)), rowCount: nil, isError: true)
    }
}

private struct LeaseTimeout: Error {}

/// Broken connection rather than a Postgres error or a proxy-side rejection.
private func isConnectionFailure(_ error: Error) -> Bool {
    if let e = error as? PSQLError { return e.serverInfo == nil }
    return false
}

/// One call = one unit of work: lease, run a single statement in its own transaction, reset, release.
private func runQuery(client: PostgresClient, sql: String, mode: Mode,
                      settings: QuerySettings, logger: Logger) async throws -> QueryOutcome {
    try await withLeaseTimeout(settings.leaseTimeout) { leased in
        try await client.withConnection { conn in
            leased()
            func exec(_ s: String) async throws { try await conn.query(PostgresQuery(unsafeSQL: s), logger: logger) }

            try await exec(mode == .read ? "BEGIN READ ONLY" : "BEGIN")
            try await exec("SET LOCAL statement_timeout = '\(settings.statementTimeout)'")
            if let lockTimeout = settings.lockTimeout { try await exec("SET LOCAL lock_timeout = '\(lockTimeout)'") }

            var columns: [String] = []
            var rows: [[Any]] = []
            do {
                // PostgresNIO always uses the extended protocol: Parse rejects multi-statement strings,
                // so `COMMIT; DROP ...` cannot escape the read-only transaction.
                var bytes = 0
                for try await row in try await conn.query(PostgresQuery(unsafeSQL: sql), logger: logger) {
                    if columns.isEmpty { columns = row.map(\.columnName) }
                    rows.append(row.map { cell in
                        bytes += cell.bytes?.readableBytes ?? 0
                        return jsonValue(cell)
                    })
                    if bytes > settings.maxResultBytes {
                        // ponytail: PostgresNIO has no CancelRequest and would drain the rest; closing the
                        // connection makes Postgres abort the query. The pool replaces the connection.
                        try? await conn.close()
                        throw QueryError("result exceeded \(settings.maxResultBytes / 1_000_000) MB, add LIMIT or select fewer columns")
                    }
                }
                try await exec(mode == .read ? "ROLLBACK" : "COMMIT")
            } catch let error as QueryError {
                throw error
            } catch {
                try? await exec("ROLLBACK")
                try? await exec("DISCARD ALL")
                throw error
            }
            try await exec("DISCARD ALL")
            // ponytail: zero-row results return no column names; PostgresRowSequence keeps them internal.
            return QueryOutcome(json: serialize(["columns": columns, "rows": rows, "row_count": rows.count]),
                                rowCount: rows.count, isError: false)
        }
    }
}

/// Fails if no connection is leased within `timeout` (server unreachable, or every pooled connection busy).
/// Once leased, the query itself is bounded by statement_timeout, not by this.
private func withLeaseTimeout<T: Sendable>(
    _ timeout: Duration,
    _ body: @escaping @Sendable (_ leased: @escaping @Sendable () -> Void) async throws -> T
) async throws -> T {
    let leased = OSAllocatedUnfairLock(initialState: false)
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body { leased.withLock { $0 = true } } }
        group.addTask {
            try await Task.sleep(for: timeout)
            if !leased.withLock({ $0 }) { throw LeaseTimeout() }
            return nil
        }
        while let result = try await group.next() {
            if let result { group.cancelAll(); return result }
        }
        throw CancellationError()
    }
}

func serialize(_ body: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

func errorBody(_ error: Error) -> [String: Any] {
    if let e = error as? QueryError { return ["error": e.message] }
    if let e = error as? PSQLError, let info = e.serverInfo {
        var body: [String: Any] = ["error": info[.message] ?? "\(e)"]
        if let s = info[.sqlState] { body["sqlstate"] = s }
        if let p = info[.position], let n = Int(p) { body["position"] = n }
        if let d = info[.detail] { body["detail"] = d }
        if let h = info[.hint] { body["hint"] = h }
        return body
    }
    return ["error": String(describing: error)]
}

// MARK: - Cell -> JSON

// ISO8601DateFormatter is thread-safe; it just isn't annotated Sendable.
nonisolated(unsafe) private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Postgres sends timestamps as Int64 microseconds since 2000-01-01 UTC. Formatting from that keeps
/// full microsecond precision (Foundation's formatter stops at milliseconds).
private func timestamp(_ cell: PostgresCell, zulu: Bool) -> String {
    guard let micros = cell.bytes?.getInteger(at: cell.bytes!.readerIndex, as: Int64.self) else { return unsupported(cell) }
    if micros == .max { return "infinity" }
    if micros == .min { return "-infinity" }
    let (secs, frac) = (micros >= 0 ? micros / 1_000_000 : (micros - 999_999) / 1_000_000, ((micros % 1_000_000) + 1_000_000) % 1_000_000)
    let s = String(isoFormatter.string(from: Date(timeIntervalSince1970: 946_684_800 + Double(secs))).dropLast())  // drop "Z"
    return s + fraction(frac) + (zulu ? "Z" : "")
}

/// ".5" for 500000 µs, "" for 0 — trailing zeros trimmed like psql.
private func fraction(_ micros: Int64) -> String {
    micros == 0 ? "" : String(String(format: ".%06lld", micros).reversed().drop { $0 == "0" }.reversed())
}

/// Postgres sends an interval as (Int64 microseconds, Int32 days, Int32 months). Rendered in psql's
/// default style, e.g. "1 year 2 mons 3 days 04:05:06.5".
private func interval(_ cell: PostgresCell) -> String {
    guard var b = cell.bytes,
          let (micros, days, months) = b.readMultipleIntegers(endianness: .big, as: (Int64, Int32, Int32).self)
    else { return unsupported(cell) }
    func unit(_ n: Int32, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
    var parts = [unit(months / 12, "year", "years"), unit(months % 12, "mon", "mons"), unit(days, "day", "days")].compactMap { $0 }
    if micros != 0 || parts.isEmpty {
        let a = micros.magnitude
        parts.append((micros < 0 ? "-" : "")
            + String(format: "%02llu:%02llu:%02llu", a / 3_600_000_000, a / 60_000_000 % 60, a / 1_000_000 % 60)
            + fraction(Int64(a % 1_000_000)))
    }
    return parts.joined(separator: " ")
}

func jsonValue(_ cell: PostgresCell) -> Any {
    guard cell.bytes != nil else { return NSNull() }
    do {
        switch cell.dataType {
        case .bool: return try cell.decode(Bool.self)
        case .int2, .int4, .int8: return try cell.decode(Int.self)
        case .float4, .float8:
            let d = try cell.decode(Double.self)
            return d.isFinite ? d : "\(d)"
        case .numeric: return try cell.decode(Decimal.self).description  // string: keeps precision
        case .uuid: return try cell.decode(UUID.self).uuidString.lowercased()
        case .timestamptz: return timestamp(cell, zulu: true)
        case .timestamp: return timestamp(cell, zulu: false)
        case .date: return String(isoFormatter.string(from: try cell.decode(Date.self)).prefix(10))
        case .json, .jsonb:
            let s = try cell.decode(String.self)
            return (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) ?? s
        case .bytea: return "\\x" + cell.bytes!.readableBytesView.map { String(format: "%02x", $0) }.joined()
        case .text, .varchar, .bpchar, .name: return try cell.decode(String.self)
        case .interval: return interval(cell)
        // 1-D arrays without NULL elements; PostgresNIO throws on anything else, which lands in the placeholder.
        case .textArray, .varcharArray: return try cell.decode([String].self)
        case .int2Array, .int4Array, .int8Array: return try cell.decode([Int].self)
        case .float8Array: return try cell.decode([Double].self)
        case .boolArray: return try cell.decode([Bool].self)
        case .uuidArray: return try cell.decode([UUID].self).map { $0.uuidString.lowercased() }
        default:
            // Enums, citext, ltree etc. send text even in binary format. Other binary payloads
            // (inet, ranges, other arrays) contain control bytes, so reject those instead of returning garbage.
            // ponytail: printable-bytes heuristic; add explicit decoders when a type shows up often.
            let s = try cell.decode(String.self)
            if s.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r" }) { return s }
            return unsupported(cell)
        }
    } catch {
        return unsupported(cell)
    }
}

private func unsupported(_ cell: PostgresCell) -> String {
    "<unsupported type oid \(cell.dataType.rawValue); cast \(cell.columnName)::text>"
}
