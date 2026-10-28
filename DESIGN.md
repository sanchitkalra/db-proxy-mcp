# db-proxy

One local MCP server that fronts every Postgres database an agent needs, replacing one `postgres-mcp` server per database (22 today).

## Why

- **Context:** each `postgres-mcp` server advertises 9 tools / ~38K chars (mostly a bloated `outputSchema`). db-proxy advertises 2 tools / ~900 chars.
- **Reliability:** all 22 servers currently fail with `CONNECTION_CLOSED` (postgres-mcp 0.3.0 pins `pglast==7.2.0`, gone from PyPI; uvx falls back to 0.1.0, which rejects `--access-mode`).
- **Output:** postgres-mcp returns a Python `repr()` string, sent twice (`content` + `structuredContent`), uncapped, with SQL errors reported as `isError: false`, and multi-statement SQL silently dropping earlier results.
- **Secrets:** 22 plaintext connection strings in `~/.claude.json` → 5 Keychain items.

## Security model

**Postgres roles are the boundary. The proxy is a guardrail.** Nothing relies on the proxy parsing SQL.

| env | roles | write possible? |
|---|---|---|
| prod | `app_ro` (read-only) | no — DB enforces |
| dev | `dev_ro`, `dev_rw` | only with `mode: "write"` |
| local | a non-superuser role | only with `mode: "write"` |

Read mode (default) runs `BEGIN READ ONLY; <sql>; ROLLBACK`. Agent SQL is sent with the **extended query protocol**, which accepts exactly one statement. This blocks `COMMIT; DROP TABLE x` escapes without a parser: Parse rejects multi-statement strings (SQLSTATE 42601). A lone `SET TRANSACTION READ WRITE` *is* accepted (no snapshot taken yet), but it is the agent's only statement, so nothing can use it before the proxy's `ROLLBACK`.

## Architecture

```
Claude Code ─┐
Cursor ──────┼─ HTTP POST /mcp (Bearer <per-agent token>) ─▶ db-proxy serve (127.0.0.1)
other agent ─┘                                                   │
                                     one PostgresClient pool per (server, user, database)
                                                                 ▼
                                               local / dev-shared / prod-1 / prod-2
```

- **Transport:** MCP Streamable HTTP, stateless (`StatelessHTTPServerTransport` from the official Swift SDK). Bound to `127.0.0.1`. SDK's default pipeline validates `Origin` (DNS-rebinding protection); we add a bearer-token validator.
- **Why HTTP, not stdio:** one process → shared, capped connections across all agents.
- **Process:** launchd agent with `KeepAlive`.
- **Stack:** Swift 6, macOS 13+. MCP Swift SDK, Hummingbird (or raw SwiftNIO) as the HTTP listener, PostgresNIO `PostgresClient`, swift-argument-parser, Security.framework.

## Tools

```json
[
 {"name":"list_databases",
  "description":"List available databases as env/name with allowed modes.",
  "inputSchema":{"type":"object","properties":{}}},
 {"name":"query",
  "description":"Run ONE Postgres SQL statement. Returns {columns, rows, row_count}. Use information_schema / pg_catalog for schema discovery. mode=read (default) runs in a read-only transaction.",
  "inputSchema":{"type":"object","required":["env","db","sql"],"properties":{
    "env":{"type":"string","description":"e.g. local, dev, prod"},
    "db":{"type":"string","description":"Postgres database name, e.g. orders"},
    "sql":{"type":"string"},
    "mode":{"type":"string","enum":["read","write"],"default":"read"}}}}
]
```

No `outputSchema`, no `structuredContent`. Schema discovery, `EXPLAIN`, etc. go through `query`.

### Results

Single `text` content item containing JSON:

```json
{"columns":["id","bank_name","status"],"rows":[[1,"RBL","ACTIVE"],[150,"YES_BANK","ACTIVE"]],"row_count":2}
```

- **No row cap.** The agent controls rows with `LIMIT` in its SQL; the client owns its context budget (e.g. `MAX_MCP_OUTPUT_TOKENS`). The proxy never rewrites SQL.
- **Proxy self-protection:** `max_result_bytes` (10 MB). Exceeding it cancels the query and returns an error, never a partial result.

### Errors

`isError: true` with JSON text:

```json
{"error":"column \"nope\" does not exist","sqlstate":"42703","position":8}
{"error":"unknown db 'prod/credt-card'. Call list_databases."}
{"error":"mode 'write' not available for prod/orders (read-only)"}
{"error":"cannot reach dev-shared (connect timeout 5s), is the VPN up?"}
{"error":"result exceeded 10 MB, add LIMIT or select fewer columns"}
```

## Query lifecycle

1. Validate bearer token → agent name. Resolve `(env, db)` → server + database; resolve `mode` → role (`write` without a `write_user` → error).
2. Lease a connection (wait ≤ 5 s, else error). Connect timeout 5 s.
3. `SET statement_timeout`, `SET lock_timeout` (per server) → `BEGIN READ ONLY` (read) or `BEGIN` (write).
4. Run agent SQL via extended protocol. Stream rows; past `max_result_bytes`, **close the connection** (PostgresNIO has no CancelRequest and would otherwise drain every remaining row). Postgres aborts the query; the pool replaces the connection.
5. `COMMIT` (write) or `ROLLBACK` (read). On release: `ROLLBACK` if needed, `DISCARD ALL`.
6. On connection error in **read** mode only: retry once on a fresh connection. Never retry writes.
7. Write log row.

**One call = one unit of work.** No transactions across calls, no session state survives a call.

## Config

`~/.config/db-proxy/databases.toml` — hand-edited, no secrets. See `databases.toml` in this repo for the current draft.

```toml
[defaults]
statement_timeout = "30s"
max_result_bytes = 10_000_000
pool_size = 2

[server.dev-shared]
env = "dev"
host = "dev-db.cluster-xxxx.us-east-1.rds.amazonaws.com"
tls = "require"
read_user = "dev_ro"
write_user = "dev_rw"
databases = ["orders", "billing"]
```

- Agents address `(env, db)`; `db` is the real Postgres database name. `(env, db)` must be unique across servers.
- Per-server overrides of `statement_timeout`, `lock_timeout`. Prod: `10s` / `2s`, because it points at the Aurora **writer** endpoint (a long `SELECT` can queue behind a migration's `ALTER` and block app traffic). Upgrade path: switch prod hosts to `cluster-ro-` reader endpoints.
- Changes apply on restart: `launchctl kickstart -k gui/$UID/<label>`.

## Secrets

Keychain, service `db-proxy`:

| account | what |
|---|---|
| `<server>/<user>` | DB password, e.g. `dev-shared/dev_ro` |
| `token/<agent>` | agent bearer token, e.g. `token/claude-code` |

The binary that writes the items also reads them, so it is on the item ACL. **Every build must be signed with the same certificate** (Apple Development is fine), or the Keychain re-prompts after each rebuild.

Tokens identify honest agents for logging and keep browsers/remote hosts out. They are not strong identity against other processes running as the same user.

## CLI

```
db-proxy serve                        # run the HTTP MCP server
db-proxy install                      # write launchd plist
db-proxy check                        # per db: password present, reachable, role, (env, db) uniqueness
db-proxy password set|rm <server>/<user>
db-proxy token add|rm <agent>         # add prints the token once
```

Agent config (Claude Code):

```json
"db": { "type": "http", "url": "http://127.0.0.1:7432/mcp",
        "headers": { "Authorization": "Bearer ${DB_PROXY_TOKEN}" } }
```

## Logging

`~/Library/Application Support/db-proxy/log.sqlite`

- Logs **everything**: timestamp, agent, env, db, mode, SQL, duration, row count, error, and the full result.
- Retention: 7 days. `serve` deletes old rows on startup and hourly; no separate job.
- `PRAGMA secure_delete = ON` (deleted rows are zeroed), `PRAGMA auto_vacuum = INCREMENTAL` (set before table creation).
- Directory excluded from Time Machine via `URLResourceValues.isExcludedFromBackup` on every startup (covers `-wal`/`-shm` files). File mode `600`.
- Read with `sqlite3` for now.

## Status (2026-10-28)

Built: config loading, Keychain passwords + per-agent tokens, `password`/`token`/`check`/`serve`/`install`, per-server timeouts, 5 s lease limit with one read retry, query log with retention. `scripts/test.sh` (36 checks, isolated Keychain service `db-proxy-test`, temp log dir) passes. `install` is written but not yet run.

- **Connection errors are diagnosed.** The pool retries failed connects silently, so after a 5 s lease timeout the proxy makes one direct 2 s attempt and reports the real cause: `database "orders" does not exist`, a bad password, `cannot reach vpn-down (10.255.255.1), is the VPN up?`, or "all pooled connections busy".
- **Shutdown:** Hummingbird handles SIGTERM/SIGINT; `serve` exits once the HTTP server stops (otherwise launchd stops would hang on the pool tasks).
- **Signing:** `scripts/build.sh` signs with the Apple Development identity (identifier `dev.db-proxy`). Verified: two builds with different CDHashes both read the same Keychain items without a dialog. Unsigned builds would trigger an approval dialog after every rebuild.
- **Certificate setup gotcha:** a new Apple Development cert shows as invalid unless the Apple WWDR **G3** intermediate (apple.com/certificateauthority/AppleWWDRCAG3.cer) is installed; only the expired G1 was present.

## Spike results (2026-10-28)

`scripts/checks.sh` (18 checks) (now 21 checks) passes against a local database, and Claude Code (`claude -p --mcp-config`) answered a real question through the proxy, matching `psql`.

- **Transport:** works with Hummingbird. HTTP/1 `Host` arrives as `request.head.authority` and must be copied into the MCP request for the Origin/Host validator.
- **Multiple agents:** the SDK's built-in `initialize` handler only accepts the first client. db-proxy re-registers `Initialize` after `server.start` to answer every client.
- **Read-only:** multi-statement rejected; `COMMIT;` escape blocked; writes in read mode fail with 25006; session state reset by `DISCARD ALL`.
- **Result cap:** closing the connection aborts the server-side query (no lingering `pg_stat_activity` row); next call works.
- **Types:** timestamps decoded from raw microseconds (Foundation's formatter truncates to ms). Known gaps: `numeric` drops trailing zeros (`12.3400` → `"12.34"`); `interval` renders like psql; 1-D arrays of text/int/float8/bool/uuid become JSON arrays; arrays with NULL elements, multi-dim arrays and other types (inet, ranges, …) return `<unsupported type …; cast x::text>`; zero-row results have empty `columns` (PostgresNIO keeps them internal).
- **Keychain + signing (check 4): passes** with a signed build (see Status).
- **Toolchain:** the Command Line Tools install has a mismatched `libPackageDescription`; build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Spike: original checklist

1. Wire `StatelessHTTPServerTransport.handleRequest` into Hummingbird/NIO; `curl` a POST through to a tool handler; bearer validator rejects a bad token.
2. `SELECT 1; SELECT 2` through `PostgresConnection.query` errors (source shows it always uses `ExtendedQueryContext`; this is the regression test).
3. Cancelling a running query from PostgresNIO works (needed for `max_result_bytes`).
4. Keychain round trip from a signed build survives a rebuild without prompts.

## Not doing (yet)

- Approval prompts for writes (MCP elicitation) — needs stateful transport.
- Per-token scoping (e.g. agent X only gets `local`).
- Hot config reload, `db-proxy add`, `db-proxy log`, menu bar app.
- SSH tunnels / bastions (VPN only).
- Databases other than Postgres.

## Cutover

Once `check` passes and Claude Code works through db-proxy, remove the 22 `postgres-*` entries from `~/.claude.json`.
