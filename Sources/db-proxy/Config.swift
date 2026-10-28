import Foundation
import Logging
import NIOSSL
import PostgresNIO
import TOMLDecoder

struct Config: Decodable, Sendable {
    struct Defaults: Decodable, Sendable {
        var statementTimeout: String?
        var lockTimeout: String?
        var maxResultBytes: Int?
        var poolSize: Int?
    }

    struct Server: Decodable, Sendable {
        var env: String
        var host: String
        var port: Int?
        var tls: String?  // "disable" | "require"
        var readUser: String
        var writeUser: String?
        var databases: [String]
        var statementTimeout: String?
        var lockTimeout: String?
    }

    var defaults: Defaults?
    var server: [String: Server]

    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/db-proxy/databases.toml").path

    static func load(_ path: String) throws -> Config {
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) } catch {
            throw ConfigError("cannot read \(path): \(error.localizedDescription)")
        }
        let config = try TOMLDecoder(strategy: .init(key: .convertFromSnakeCase)).decode(Config.self, from: text)
        try config.validate()
        return config
    }

    private func validate() throws {
        var seen: [String: String] = [:]
        for (name, s) in server {
            guard ["disable", "require"].contains(s.tls ?? "require") else {
                throw ConfigError("server.\(name): tls must be \"disable\" or \"require\"")
            }
            for t in [s.statementTimeout, s.lockTimeout, defaults?.statementTimeout, defaults?.lockTimeout].compactMap({ $0 }) {
                // Interpolated into SET LOCAL, so only allow plain durations like "30s" or "500ms".
                guard t.wholeMatch(of: /[0-9]+(ms|s|min)?/) != nil else { throw ConfigError("server.\(name): bad timeout \"\(t)\"") }
            }
            for db in s.databases {
                let key = "\(s.env)/\(db)"
                if let other = seen[key] { throw ConfigError("\(key) is defined in both server.\(other) and server.\(name)") }
                seen[key] = name
            }
        }
    }

    var maxResultBytes: Int { defaults?.maxResultBytes ?? 10_000_000 }

    func statementTimeout(_ s: Server) -> String { s.statementTimeout ?? defaults?.statementTimeout ?? "30s" }
    func lockTimeout(_ s: Server) -> String? { s.lockTimeout ?? defaults?.lockTimeout }

    /// Every (env, db) an agent can address, sorted for stable output.
    var targets: [Target] {
        server.flatMap { name, s in s.databases.map { Target(serverName: name, server: s, db: $0) } }
            .sorted { ($0.server.env, $0.db) < ($1.server.env, $1.db) }
    }

    func target(env: String, db: String) -> Target? {
        targets.first { $0.server.env == env && $0.db == db }
    }

    func connectionConfig(_ t: Target, user: String, password: String?) -> PostgresClient.Configuration {
        var c = PostgresClient.Configuration(
            host: t.server.host, port: t.server.port ?? 5432,
            username: user, password: password, database: t.db,
            tls: t.server.tls == "disable" ? .disable : .require(Self.requireTLS))
        c.options.maximumConnections = defaults?.poolSize ?? 2
        c.options.connectTimeout = .seconds(5)
        return c
    }

    /// The pool retries failed connects silently, so a lease timeout alone can't say *why*.
    /// This makes one direct attempt with the same settings and reports its error.
    func diagnosis(_ t: Target, user: String, password: String?) -> @Sendable () async -> String {
        var c = PostgresConnection.Configuration(
            host: t.server.host, port: t.server.port ?? 5432,
            username: user, password: password, database: t.db,
            tls: t.server.tls == "disable" ? .disable : .require(try! NIOSSLContext(configuration: Self.requireTLS)))
        c.options.connectTimeout = .seconds(2)  // the pool already spent 5s trying
        let name = t.serverName, host = t.server.host
        return { [c] in
            do {
                let conn = try await PostgresConnection.connect(configuration: c, id: 0, logger: Logger(label: "db-proxy.diagnose"))
                try? await conn.close()
                return "no free connection to \(name) within 5s: all pooled connections are busy, try again"
            } catch let e as PSQLError where e.serverInfo != nil {
                return "cannot connect to \(name): \(e.serverInfo?[.message] ?? "\(e)")"
            } catch {
                return "cannot reach \(name) (\(host)), is the VPN up?"
            }
        }
    }

    // ponytail: "require" = encrypted, certificate not verified (same as libpq sslmode=require).
    // Add a "verify-full" mode with the RDS CA bundle if MITM on the VPN path becomes a concern.
    private static let requireTLS: TLSConfiguration = {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        return tls
    }()
}

struct Target: Sendable {
    let serverName: String
    let server: Config.Server
    let db: String

    func user(for mode: Mode) -> String? { mode == .read ? server.readUser : server.writeUser }
    var modes: [String] { server.writeUser == nil ? ["read"] : ["read", "write"] }
}

struct ConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
