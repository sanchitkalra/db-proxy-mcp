import ArgumentParser
import Foundation
import Logging
import PostgresNIO

@main
enum Entry {
    static func main() async {
        // Double-clicked in Finder: no arguments and no terminal. Run the guided setup instead of printing help.
        if CommandLine.arguments.dropFirst().allSatisfy({ $0.hasPrefix("-psn_") }), isatty(STDIN_FILENO) == 0,
           AppBundle.url != nil {
            await FirstRun.run()
            return
        }
        await DBProxy.main()
    }
}

struct DBProxy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db-proxy",
        abstract: "One local MCP server in front of all your Postgres databases.",
        subcommands: [Serve.self, Check.self, Edit.self, Agent.self, Password.self, Token.self, Restart.self, Service.self, Install.self])
}

struct ConfigOption: ParsableArguments {
    @Option(help: "Path to databases.toml.")
    var config: String = Config.defaultPath
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the HTTP MCP server on 127.0.0.1.")
    @OptionGroup var options: ConfigOption
    @Option(help: "Port to listen on.") var port = 7432
    @Option(help: "Directory for the query log.") var logDir = QueryLog.defaultDir.path
    @Option(help: "Append stdout/stderr to this file (\"~/\" allowed). Used by the background service.") var logFile: String?

    func run() async throws {
        if let logFile {
            let path = (logFile as NSString).expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            freopen(path, "a", stdout)
            freopen(path, "a", stderr)
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        try await serve(config: Config.load(options.config), port: port, logDir: URL(filePath: logDir))
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate the config, Keychain entries and connectivity of every database.")
    @OptionGroup var options: ConfigOption

    func run() async throws {
        let config = try Config.load(options.config)
        print("config ok: \(options.config)")
        let agents = try Keychain.agentTokens().values.sorted()
        print("agent tokens: \(agents.isEmpty ? "none (run `db-proxy token add <agent>`)" : agents.joined(separator: ", "))")

        let probes = config.targets.flatMap { t in
            [(t, Mode.read)] + (t.server.writeUser == nil ? [] : [(t, Mode.write)])
        }
        let logger = {
            var l = Logger(label: "db-proxy.check")
            l.logLevel = .critical  // pool retry noise; failures are reported per database below
            return l
        }()
        let results = await withTaskGroup(of: (Int, String, Bool).self) { group in
            for (i, (t, mode)) in probes.enumerated() {
                group.addTask {
                    let user = t.user(for: mode)!
                    let label = "\(t.server.env)/\(t.db) \(mode.rawValue) as \(user)"
                    do {
                        guard let password = try Keychain.get("\(t.serverName)/\(user)") else {
                            return (i, "\(label): no password (`db-proxy password set \(t.serverName)/\(user)`)", false)
                        }
                        let client = PostgresClient(configuration: config.connectionConfig(t, user: user, password: password),
                                                    backgroundLogger: logger)
                        let runner = Task { await client.run() }
                        defer { runner.cancel() }
                        let outcome = await execute(
                            client: client, serverName: t.serverName, sql: "select 1", mode: mode,
                            settings: QuerySettings(statementTimeout: "5s", lockTimeout: nil, maxResultBytes: 1000,
                                                    diagnose: config.diagnosis(t, user: user, password: password)),
                            logger: logger)
                        return (i, outcome.isError ? "\(label): \(outcome.json)" : "\(label): ok", !outcome.isError)
                    } catch {
                        return (i, "\(label): \(error)", false)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }.sorted { $0.0 < $1.0 }
        }
        for (_, line, ok) in results { print("\(ok ? "ok  " : "FAIL") \(line)") }
        if results.contains(where: { !$0.2 }) { throw ExitCode.failure }
    }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit the config in $EDITOR (or TextEdit), validate it, and restart the service if it's valid.")
    @OptionGroup var options: ConfigOption

    func run() throws {
        let path = options.config
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let p = Process()  // inherits the terminal, so vim/nano work
        p.executableURL = URL(filePath: "/bin/sh")
        if let editor = ProcessInfo.processInfo.environment["VISUAL"] ?? ProcessInfo.processInfo.environment["EDITOR"], !editor.isEmpty {
            p.arguments = ["-c", "\(editor) \"$0\"", path]
        } else {
            p.arguments = ["-c", "open -W -t \"$0\"", path]  // waits until the TextEdit window closes
            print("opened in TextEdit; close the window when done")
        }
        try p.run()
        p.waitUntilExit()

        do {
            let config = try Config.load(path)
            print("config ok: \(config.targets.count) databases")
        } catch {
            print("config NOT applied, the running service keeps the previous one:\n  \(error)")
            throw ExitCode.failure
        }
        restartServiceIfInstalled()
    }
}

struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart the background service (reloads config, passwords, tokens).")
    func run() { restartServiceIfInstalled() }
}

struct Password: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Store or remove a database password in the Keychain.",
        subcommands: [Set.self, Remove.self])

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Store a password. Reads from the terminal without echo, or from stdin.")
        @OptionGroup var options: ConfigOption
        @Argument(help: "<server>/<user>, e.g. dev/readonly") var account: String

        func run() throws {
            let config = try Config.load(options.config)
            let parts = account.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let s = config.server[parts[0]], [s.readUser, s.writeUser].contains(parts[1]) else {
                throw ValidationError("\(account) is not a <server>/<user> pair in \(options.config)")
            }
            guard let password = readSecret(prompt: "Password for \(account): "), !password.isEmpty else {
                throw ValidationError("empty password")
            }
            try Keychain.set(account, password)
            print("stored \(account)")
            restartServiceIfInstalled()
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a stored password.")
        @Argument(help: "<server>/<user>") var account: String
        func run() throws {
            guard try Keychain.delete(account) else { return print("\(account) was not stored") }
            print("removed \(account)")
            restartServiceIfInstalled()
        }
    }
}

struct Token: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage per-agent bearer tokens. Changes apply when `serve` restarts.",
        subcommands: [Add.self, Remove.self])

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a token for an agent and print it once.")
        @Argument(help: "Agent name, e.g. claude-code") var agent: String
        func run() throws {
            guard agent.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil else { throw ValidationError("agent name: letters, digits, . _ - only") }
            let token = randomToken()
            try Keychain.set("token/\(agent)", token)
            print(token)
            restartServiceIfInstalled()
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Revoke an agent's token.")
        @Argument var agent: String
        func run() throws {
            guard try Keychain.delete("token/\(agent)") else { return print("no token for \(agent)") }
            print("revoked \(agent)")
            restartServiceIfInstalled()
        }
    }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install a launchd agent for a source build (the .app uses `service enable` instead).")
    @OptionGroup var options: ConfigOption
    static let label = "dev.db-proxy"

    func run() throws {
        guard let exe = Bundle.main.executablePath else { throw ValidationError("cannot find own executable path") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appending(path: "Library/LaunchAgents/\(Self.label).plist")
        let logFile = home.appending(path: "Library/Logs/db-proxy.log").path
        let config = URL(filePath: options.config).standardizedFileURL.path
        let body: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [exe, "serve", "--config", config],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logFile,
            "StandardErrorPath": logFile,
        ]
        try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0).write(to: plist)
        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", "\(domain)/\(Self.label)"])  // fine if it wasn't loaded
        guard launchctl(["bootstrap", domain, plist.path]) == 0 else { throw ValidationError("launchctl bootstrap failed") }
        print("""
            installed \(plist.path)
            running: \(exe) serve --config \(config)
            logs:    \(logFile)
            restart after config/token changes: launchctl kickstart -k \(domain)/\(Self.label)
            """)
    }

    private func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/launchctl")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Terminal: prompt without echo. Piped stdin: read one line (for scripts).
func readSecret(prompt: String) -> String? {
    guard isatty(STDIN_FILENO) != 0 else { return readLine(strippingNewline: true) }
    var buf = [CChar](repeating: 0, count: 1024)
    guard readpassphrase(prompt, &buf, buf.count, RPP_REQUIRE_TTY) != nil else { return nil }
    defer { buf.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress, 0, $0.count) } }
    return String(cString: buf)
}
