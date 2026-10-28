import ArgumentParser
import Foundation

/// Registers db-proxy as an MCP server named "db-proxy" in a coding agent's config, with its own token.
/// Formats (checked against each agent's docs, 2026-10):
///   claude: `claude mcp add --transport http --scope user <name> <url> --header ...`
///   cursor: ~/.cursor/mcp.json        { "mcpServers": { <name>: { "url", "headers" } } }
///   codex:  ~/.codex/config.toml      [mcp_servers.<name>] url = ..., http_headers = { ... }
enum AgentKind: String, CaseIterable, ExpressibleByArgument {
    case claude, cursor, codex

    static let serverName = "db-proxy"
    // Overridable so tests can edit copies instead of the real agent configs.
    private static let home = ProcessInfo.processInfo.environment["DB_PROXY_AGENT_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    private static var cursorFile: URL { home.appending(path: ".cursor/mcp.json") }
    private static var codexFile: URL { home.appending(path: ".codex/config.toml") }

    func register(url: String, token: String) throws {
        switch self {
        case .claude:
            _ = try? run("claude", ["mcp", "remove", "--scope", "user", Self.serverName])  // fine if absent
            try run("claude", ["mcp", "add", "--transport", "http", "--scope", "user", Self.serverName, url,
                               "--header", "Authorization: Bearer \(token)"])
        case .cursor:
            var json = try Self.readJSON(Self.cursorFile)
            var servers = json["mcpServers"] as? [String: Any] ?? [:]
            servers[Self.serverName] = ["url": url, "headers": ["Authorization": "Bearer \(token)"]]
            json["mcpServers"] = servers
            try Self.writeJSON(json, to: Self.cursorFile)
        case .codex:
            let kept = try Self.codexWithoutBlock()
            let block = """
                [mcp_servers.\(Self.serverName)]
                url = "\(url)"
                http_headers = { "Authorization" = "Bearer \(token)" }
                """
            try Self.write((kept.isEmpty ? "" : kept + "\n\n") + block + "\n", to: Self.codexFile)
        }
    }

    func unregister() throws {
        switch self {
        case .claude:
            _ = try? run("claude", ["mcp", "remove", "--scope", "user", Self.serverName])
        case .cursor:
            var json = try Self.readJSON(Self.cursorFile)
            var servers = json["mcpServers"] as? [String: Any] ?? [:]
            servers[Self.serverName] = nil
            json["mcpServers"] = servers
            try Self.writeJSON(json, to: Self.cursorFile)
        case .codex:
            guard FileManager.default.fileExists(atPath: Self.codexFile.path) else { return }
            try Self.write(try Self.codexWithoutBlock() + "\n", to: Self.codexFile)
        }
    }

    var isRegistered: Bool {
        switch self {
        case .claude:
            return (try? run("claude", ["mcp", "get", Self.serverName], quiet: true)) != nil
        case .cursor:
            return ((try? Self.readJSON(Self.cursorFile))?["mcpServers"] as? [String: Any])?[Self.serverName] != nil
        case .codex:
            return ((try? String(contentsOf: Self.codexFile, encoding: .utf8)) ?? "")
                .split(separator: "\n").contains { Self.isCodexHeader($0, sub: false) }
        }
    }

    // MARK: file helpers

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("\(url.path) is not a JSON object; not touching it")
        }
        return obj
    }

    private static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try write(String(decoding: data, as: UTF8.self) + "\n", to: url)
    }

    /// Writes atomically with mode 0600 (the file holds a token), keeping a one-time .bak of the original.
    private static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("bak-before-db-proxy")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
        try Data(text.utf8).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    /// config.toml with our `[mcp_servers.db-proxy]` table (and any `[mcp_servers.db-proxy.*]` sub-tables) removed.
    /// ponytail: line-based TOML edit; fine for tables we wrote ourselves. Use a TOML writer if users hand-edit ours.
    private static func codexWithoutBlock() throws -> String {
        guard let text = try? String(contentsOf: codexFile, encoding: .utf8) else { return "" }
        var out: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { skipping = isCodexHeader(line, sub: true) }
            if !skipping { out.append(line) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCodexHeader(_ line: Substring, sub: Bool) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return ["[mcp_servers.\(serverName)", "[mcp_servers.\"\(serverName)\""].contains { prefix in
            t == prefix + "]" || (sub && t.hasPrefix(prefix + "."))
        }
    }
}

@discardableResult
func run(_ tool: String, _ args: [String], quiet: Bool = false) throws -> String {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/env")
    p.arguments = [tool] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard p.terminationStatus == 0 else {
        throw ValidationError(quiet ? "\(tool) failed" : "\(tool) \(args.first ?? "") failed: \(text)")
    }
    return text
}

struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect coding agents to db-proxy (one token each).",
        subcommands: [Add.self, Remove.self, List.self])

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create/reuse the agent's token and register db-proxy in its MCP config.")
        @Argument(help: "One of: \(AgentKind.allCases.map(\.rawValue).joined(separator: ", "))") var agent: AgentKind
        @Option(help: "Port db-proxy serves on.") var port = 7432

        func run() throws {
            let account = "token/\(agent.rawValue)"
            var token = try Keychain.get(account)
            let isNew = token == nil
            if isNew {
                token = randomToken()
                try Keychain.set(account, token!)
            }
            try agent.register(url: "http://127.0.0.1:\(port)/mcp", token: token!)
            print("registered \(AgentKind.serverName) in \(agent.rawValue)")
            if isNew { restartServiceIfInstalled() }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Unregister db-proxy from the agent and revoke its token.")
        @Argument var agent: AgentKind

        func run() throws {
            try agent.unregister()
            let revoked = try Keychain.delete("token/\(agent.rawValue)")
            print("removed \(AgentKind.serverName) from \(agent.rawValue)\(revoked ? ", token revoked" : "")")
            if revoked { restartServiceIfInstalled() }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Show agents, tokens and registrations.")
        func run() throws {
            let tokens = Set(try Keychain.accounts().filter { $0.hasPrefix("token/") }.map { String($0.dropFirst(6)) })
            for kind in AgentKind.allCases {
                print("\(pad(kind.rawValue)) token: \(tokens.contains(kind.rawValue) ? "yes" : "no ")  registered: \(kind.isRegistered ? "yes" : "no")")
            }
            for other in tokens.subtracting(AgentKind.allCases.map(\.rawValue)).sorted() {
                print("\(pad(other)) token: yes  (manual: `db-proxy token rm \(other)` to revoke)")
            }
        }
    }
}

private func pad(_ s: String) -> String { s + String(repeating: " ", count: max(1, 13 - s.count)) }

func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Tokens are loaded when `serve` starts, so a new or revoked token needs a restart. Works for both the
/// app's SMAppService agent and a source build's `install` plist (same label).
func restartServiceIfInstalled() {
    if (try? run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(Install.label)"], quiet: true)) != nil {
        print("restarted the db-proxy service")
    } else {
        print("restart `db-proxy serve` to apply the token change")
    }
}
