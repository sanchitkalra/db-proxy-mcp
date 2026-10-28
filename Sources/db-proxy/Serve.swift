import Foundation
import HTTPTypes
import Hummingbird
import Logging
import MCP
import PostgresNIO

struct BearerValidator: HTTPRequestValidator {
    let tokens: Set<String>
    func validate(_ request: MCP.HTTPRequest, context: HTTPValidationContext) -> MCP.HTTPResponse? {
        guard let auth = request.header("Authorization"), auth.hasPrefix("Bearer "),
              tokens.contains(String(auth.dropFirst("Bearer ".count)))
        else { return .error(statusCode: 401, .invalidRequest("missing or invalid bearer token")) }
        return nil
    }
}

func serve(config: Config, port: Int, logDir: URL) async throws {
    let logger = Logger(label: "db-proxy")

    let agents = try Keychain.agentTokens()  // token -> agent name
    guard !agents.isEmpty else { throw ConfigError("no agent tokens; run `db-proxy token add <agent>` first") }

    // One pool per (server, user, database). Pools open no connections until first use.
    var pools: [String: PostgresClient] = [:]
    var diagnoses: [String: @Sendable () async -> String] = [:]
    var missingPasswords: Set<String> = []
    for t in config.targets {
        for user in Set([t.server.readUser, t.server.writeUser].compactMap { $0 }) {
            let account = "\(t.serverName)/\(user)"
            guard let password = try Keychain.get(account) else { missingPasswords.insert(account); continue }
            pools["\(account)/\(t.db)"] = PostgresClient(
                configuration: config.connectionConfig(t, user: user, password: password), backgroundLogger: logger)
            diagnoses["\(account)/\(t.db)"] = config.diagnosis(t, user: user, password: password)
        }
    }
    for account in missingPasswords.sorted() {
        logger.warning("no Keychain password for \(account); its databases will error until `db-proxy password set \(account)`")
    }

    let queryLog = try QueryLog(dir: logDir)
    queryLog.prune()

    // MARK: MCP

    let transport = StatelessHTTPServerTransport(
        validationPipeline: StandardValidationPipeline(validators: [
            OriginValidator.localhost(port: port),
            BearerValidator(tokens: Set(agents.keys)),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ]),
        logger: logger)

    let server = Server(name: "db-proxy", version: "0.1.0", capabilities: .init(tools: .init()))

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(name: "list_databases",
                 description: "List available databases as env/name with allowed modes.",
                 inputSchema: .object(["type": "object", "properties": .object([:])])),
            Tool(name: "query",
                 description: "Run ONE Postgres SQL statement. Returns {columns, rows, row_count}. Use information_schema / pg_catalog for schema discovery. mode=read (default) runs in a read-only transaction.",
                 inputSchema: .object([
                     "type": "object",
                     "required": .array(["env", "db", "sql"]),
                     "properties": .object([
                         "env": .object(["type": "string", "description": "e.g. local, dev, prod"]),
                         "db": .object(["type": "string", "description": "Postgres database name, e.g. orders"]),
                         "sql": .object(["type": "string"]),
                         "mode": .object(["type": "string", "enum": .array(["read", "write"]), "default": "read"]),
                     ]),
                 ])),
        ])
    }

    @Sendable func reply(_ json: String, isError: Bool) -> CallTool.Result {
        .init(content: [.text(json)], isError: isError)
    }

    await server.withMethodHandler(CallTool.self) { [pools, diagnoses] params in
        switch params.name {
        case "list_databases":
            let list = config.targets.map { ["env": $0.server.env, "db": $0.db, "modes": $0.modes] as [String: Any] }
            return reply(serialize(["databases": list]), isError: false)

        case "query":
            let auth = Server.currentHandlerContext?.httpContext?.header("Authorization") ?? ""
            let agent = agents[String(auth.dropFirst("Bearer ".count))] ?? "unknown"
            let a = params.arguments ?? [:]
            let env = a["env"]?.stringValue ?? "", db = a["db"]?.stringValue ?? ""
            guard let sql = a["sql"]?.stringValue else { return reply(serialize(["error": "sql is required"]), isError: true) }
            guard let mode = Mode(rawValue: a["mode"]?.stringValue ?? "read") else {
                return reply(serialize(["error": "mode must be read or write"]), isError: true)
            }

            let started = ContinuousClock.now
            let outcome: QueryOutcome
            if let t = config.target(env: env, db: db) {
                if let user = t.user(for: mode) {
                    if let pool = pools["\(t.serverName)/\(user)/\(db)"] {
                        outcome = await execute(
                            client: pool, serverName: t.serverName, sql: sql, mode: mode,
                            settings: QuerySettings(statementTimeout: config.statementTimeout(t.server),
                                                    lockTimeout: config.lockTimeout(t.server),
                                                    maxResultBytes: config.maxResultBytes,
                                                    diagnose: diagnoses["\(t.serverName)/\(user)/\(db)"]!),
                            logger: logger)
                    } else {
                        outcome = .init(json: serialize(["error": "no password for \(t.serverName)/\(user); run `db-proxy password set \(t.serverName)/\(user)`"]), rowCount: nil, isError: true)
                    }
                } else {
                    outcome = .init(json: serialize(["error": "mode 'write' not available for \(env)/\(db) (read-only)"]), rowCount: nil, isError: true)
                }
            } else {
                outcome = .init(json: serialize(["error": "unknown db '\(env)/\(db)'. Call list_databases."]), rowCount: nil, isError: true)
            }
            let elapsed = ContinuousClock.now - started
            queryLog.write(agent: agent, env: env, db: db, mode: mode.rawValue, sql: sql,
                           durationMs: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000),
                           outcome: outcome)
            return reply(outcome.json, isError: outcome.isError)

        default:
            return reply(serialize(["error": "unknown tool \(params.name)"]), isError: true)
        }
    }

    try await server.start(transport: transport)

    // One Server serves every agent, so every agent's `initialize` must succeed. The SDK's built-in
    // handler (registered by start) only accepts the first one; replace it with a stateless answer.
    await server.withMethodHandler(Initialize.self) { params in
        .init(protocolVersion: Version.supported.contains(params.protocolVersion) ? params.protocolVersion : Version.latest,
              capabilities: .init(tools: .init()),
              serverInfo: .init(name: "db-proxy", version: "0.1.0"),
              instructions: nil)
    }

    // MARK: HTTP listener

    let router = Router()
    let mcpHandler: @Sendable (Request, BasicRequestContext) async throws -> Response = { request, _ in
        var headers: [String: String] = [:]
        for field in request.headers { headers[field.name.canonicalName] = field.value }
        if let authority = request.head.authority { headers["Host"] = authority }  // HTTP/1 Host lives in :authority
        let body = try await request.body.collect(upTo: 10_000_000)
        let r = await transport.handleRequest(MCP.HTTPRequest(
            method: request.method.rawValue, headers: headers, body: Data(buffer: body), path: request.uri.path))
        var out = HTTPFields()
        for (k, v) in r.headers { if let name = HTTPField.Name(k) { out[name] = v } }
        return Response(status: .init(code: r.statusCode), headers: out,
                        body: .init(byteBuffer: ByteBuffer(data: r.bodyData ?? Data())))
    }
    router.post("/mcp", use: mcpHandler)
    router.get("/mcp", use: mcpHandler)
    router.delete("/mcp", use: mcpHandler)

    let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: port)), logger: logger)
    logger.info("serving \(config.targets.count) databases to \(agents.count) agent token(s)")

    try await withThrowingDiscardingTaskGroup { group in
        for pool in pools.values { group.addTask { await pool.run() } }
        group.addTask {
            // Returns after SIGTERM/SIGINT (launchd stop). Pools and the prune loop have nothing to
            // flush (SQLite commits per row), so exit instead of waiting on them.
            try await app.runService()
            exit(0)
        }
        group.addTask {
            while true {
                try await Task.sleep(for: .seconds(3600))
                queryLog.prune()
            }
        }
    }
}
