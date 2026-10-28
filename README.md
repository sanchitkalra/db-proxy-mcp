# db-proxy

**One local MCP server in front of all your Postgres databases.** Instead of configuring one MCP server per database in every coding agent, you run `db-proxy` once on your Mac. Every agent (Claude Code, Cursor, Codex, …) connects to it and sends `env`, `db` and `sql`. db-proxy holds the connections, keeps passwords in the macOS Keychain, enforces read-only by default, and logs every query.

```
Claude Code ─┐
Cursor ──────┼── HTTP POST /mcp (Bearer <per-agent token>) ──▶ db-proxy serve (127.0.0.1:7432)
any agent ───┘                                                        │
                                            one small connection pool per (server, role, database)
                                                                      ▼
                                                      local · dev · prod Postgres
```

## Why

Running one `postgres-mcp`-style server per database hurts in several ways:

- **Context cost.** Each server advertises its own tool set. A typical Postgres MCP sends ~9 tools / ~38K characters of schema *per database*. db-proxy sends **2 tools, ~900 characters, total**.
- **Fragility.** N processes, N dependency trees. One bad upstream release can silently break all of them.
- **Secrets sprawl.** N plaintext connection strings in agent configs. db-proxy keeps one Keychain item per role.
- **Unsafe defaults.** Multi-statement strings (`COMMIT; DROP TABLE …`), no row/size limits, SQL errors reported as success.

## Features

- **Two tools:** `list_databases` and `query(env, db, sql, mode)`.
- **Read-only by default.** Every read runs inside `BEGIN READ ONLY`, as **exactly one statement**. Postgres itself enforces it; there is no SQL parser to get wrong.
- **Writes are explicit.** They need `mode: "write"` and a configured `write_user`. Prod can simply have no write role.
- **Compact results:** `{columns, rows, row_count}` as real JSON. Types are decoded properly: microsecond timestamps, JSON/JSONB, arrays, intervals, uuid, numeric, bytea.
- **Clear errors:** `isError: true`, with SQLSTATE, position, detail and hint. Connection failures say why: VPN down, wrong password, missing database, or a busy pool.
- **Shared, capped pools.** At most `pool_size` connections per database across all agents. Connections open lazily and are reset (`ROLLBACK` + `DISCARD ALL`) after every call.
- **Per-server limits:** `statement_timeout`, `lock_timeout`, and a 10 MB result safety cap. Over the cap, the server-side query is aborted.
- **VPN-friendly.** A 5 s limit to obtain a connection, and one automatic retry for reads if a connection drops.
- **Audit log.** Every call is stored in SQLite with agent, env, db, mode, SQL, duration, row count and the full response. Kept for 7 days, with deleted rows zeroed, the folder excluded from Time Machine, and permissions `0700`/`0600`.
- **Per-agent tokens,** so the log tells you which agent ran what.
- **launchd service:** starts at login and restarts on crash.

## Requirements

- macOS 14 or later
- Xcode 16 or later (Swift 6). See [Troubleshooting](#troubleshooting) if `swift build` fails with the Command Line Tools.
- An **Apple Development** signing certificate (free with an Apple ID) so Keychain access survives rebuilds. See [Signing](#signing).

## Setup

### 1. Build

```sh
git clone https://github.com/sanchitkalra/db-proxy-mcp.git db-proxy && cd db-proxy
scripts/build.sh            # swift build -c release + codesign
```

The binary is at `.build/release/db-proxy`. Copy or symlink it somewhere on your `PATH` if you like. `install` (step 5) records whichever path you run it from.

### 2. Configure databases

```sh
mkdir -p ~/.config/db-proxy
cp databases.example.toml ~/.config/db-proxy/databases.toml
$EDITOR ~/.config/db-proxy/databases.toml
```

The config is grouped by server, meaning one Postgres host plus its roles:

```toml
[server.dev]
env = "dev"
host = "dev-db.cluster-xxxx.us-east-1.rds.amazonaws.com"
tls = "require"
read_user = "app_ro"
write_user = "app_rw"      # omit for read-only servers (e.g. prod)
databases = ["orders", "billing"]
```

Agents address a database as `(env, db)`, e.g. `query(env: "prod", db: "orders", ...)`. The same `(env, db)` may not appear under two servers.

### 3. Store passwords in the Keychain

There is one password per `<server>/<user>`, not per database:

```sh
db-proxy password set dev/app_ro      # prompts without echo; also accepts stdin
db-proxy password set dev/app_rw
db-proxy password set prod/app_ro
```

### 4. Check everything

```sh
db-proxy check                        # every (database, role): password present, connects, runs SELECT 1
```

`check` exits non-zero if anything fails and says why:

```
ok   dev/orders read as app_ro: ok
FAIL local/billing read as app: {"error":"cannot connect to local: database \"billing\" does not exist"}
FAIL prod/orders read as app_ro: {"error":"cannot reach prod (prod-db…), is the VPN up?"}
```

### 5. Run it in the background

```sh
db-proxy install
```

This writes `~/Library/LaunchAgents/dev.db-proxy.plist` with `RunAtLoad` and `KeepAlive`, and starts it. Logs go to `~/Library/Logs/db-proxy.log`. **After changing the config or tokens, restart it:**

```sh
launchctl kickstart -k gui/$(id -u)/dev.db-proxy
```

### 6. Connect your agents

```sh
db-proxy agent add claude     # Claude Code (via `claude mcp add`, user scope)
db-proxy agent add cursor     # ~/.cursor/mcp.json
db-proxy agent add codex      # ~/.codex/config.toml
db-proxy agent list
```

Each agent gets its own token (`token/<agent>` in the Keychain), so the query log shows which agent ran what. The MCP server is registered as **`db-proxy`**, and its tools appear as e.g. `mcp__db-proxy__query`. Agent config files are written with mode `0600`, and the original is kept once as `<file>.bak-before-db-proxy`. Adding or removing a token restarts the installed service automatically.

**Any other MCP client** that supports Streamable HTTP: create a token with `db-proxy token add <name>`, restart the service, and use URL `http://127.0.0.1:7432/mcp` with header `Authorization: Bearer <token>`.

## CLI reference

| Command | What it does |
|---|---|
| `db-proxy serve [--config] [--port 7432] [--log-dir]` | Run the HTTP MCP server on 127.0.0.1 |
| `db-proxy check [--config]` | Validate config, Keychain entries and connectivity of every database/role |
| `db-proxy agent add <claude\|cursor\|codex> [--port]` | Create/reuse the agent's token and register db-proxy in its MCP config |
| `db-proxy agent rm <agent>` | Unregister from the agent and revoke its token |
| `db-proxy agent list` | Show agents, tokens and registrations |
| `db-proxy password set <server>/<user>` | Store a password (terminal prompt without echo, or one line on stdin) |
| `db-proxy password rm <server>/<user>` | Remove a password |
| `db-proxy token add <name>` | Create a 256-bit token for a custom client and print it once |
| `db-proxy token rm <agent>` | Revoke an agent's token (takes effect on restart) |
| `db-proxy install [--config]` | Install and start the launchd agent |

The config path defaults to `~/.config/db-proxy/databases.toml`.

## Config reference

```toml
[defaults]                       # all optional
statement_timeout = "30s"        # per query; "500ms", "30s", "2min"
lock_timeout = "2s"              # unset = Postgres default (wait forever)
max_result_bytes = 10_000_000    # result size over which the query is aborted
pool_size = 2                    # max connections per (server, user, database)

[server.<name>]                  # <name> is also the Keychain prefix: "<name>/<user>"
env = "dev"                      # what agents pass as `env`
host = "..."
port = 5432                      # optional
tls = "require"                  # "require" (default) or "disable"
read_user = "app_ro"             # used for mode=read
write_user = "app_rw"            # optional; without it mode=write is rejected
databases = ["orders"]           # what agents pass as `db`
statement_timeout = "10s"        # optional per-server overrides
lock_timeout = "2s"
```

## How it works

### Security model

**Postgres roles are the security boundary; the proxy is a guardrail.** Give prod a read-only role and writes are impossible, whatever the proxy does. On top of that:

1. **Read mode** runs `BEGIN READ ONLY; SET LOCAL statement_timeout …; <agent SQL>; ROLLBACK`.
2. **Agent SQL is sent with the extended query protocol**, whose Parse step accepts exactly one statement. `select 1; select 2` fails with SQLSTATE `42601`, so `COMMIT; DROP TABLE x` cannot escape the read-only transaction. (A lone `SET TRANSACTION READ WRITE` is accepted by Postgres, but it is the only statement, so nothing can use it before the `ROLLBACK`.)
3. **Write mode** uses the server's `write_user` inside a normal transaction, and commits.
4. **After every call**, the connection is rolled back and `DISCARD ALL` resets session state (search_path, temp tables, prepared statements, `SET ROLE`) before another agent can reuse it.
5. **The HTTP listener** binds to `127.0.0.1` only, validates `Origin`/`Host` (DNS-rebinding protection), and requires a bearer token. Tokens keep out browsers and other machines and label agents in the log. They are *not* strong identity against other processes running as your user.

### One call

1. Authenticate the bearer token and resolve it to an agent name.
2. Resolve `(env, db)` to a server and database, and `mode` to a role.
3. Lease a pooled connection. If none is available within 5 s, make one direct 2 s connection attempt to diagnose why (unreachable, auth, missing database, pool busy).
4. Run the statement and stream rows into JSON. Past `max_result_bytes`, close the connection, which makes Postgres abort the query, and return an error. Results are never truncated silently.
5. Commit or roll back, reset the connection, and release it. If a **read** hit a broken connection, retry once on a fresh one. Writes never retry.
6. Write the log row.

### Results

```json
{"columns":["id","status","created_at"],"rows":[[1,"ACTIVE","2024-03-03T00:14:40.286815"]],"row_count":1}
```

There is no row limit. The agent controls rows with `LIMIT`, and the client controls its own context budget. The proxy never rewrites SQL.

| Postgres type | JSON |
|---|---|
| bool, int2/4/8, float4/8 | boolean / number |
| numeric | string (keeps precision) |
| text, varchar, enum, citext | string |
| uuid | lowercase string |
| timestamp / timestamptz / date | `2024-03-03T00:14:40.286815` / `…Z` / `2024-03-03` (microsecond precision) |
| json, jsonb | the JSON value itself |
| interval | psql style, e.g. `"1 year 2 mons 3 days 04:05:06.5"` |
| 1-D arrays of text/int/float8/bool/uuid | JSON array |
| bytea | `"\\xdeadbeef"` |
| anything else | `"<unsupported type oid N; cast col::text>"` |

### Errors

```json
{"error":"column \"nope\" does not exist","sqlstate":"42703","position":8}
{"error":"mode 'write' not available for prod/orders (read-only)"}
{"error":"cannot reach dev (dev-db…), is the VPN up?"}
{"error":"result exceeded 10 MB, add LIMIT or select fewer columns"}
```

### Secrets

Keychain service `db-proxy`, generic-password items:

| Account | Contents |
|---|---|
| `<server>/<user>` | database password |
| `token/<agent>` | agent bearer token |

### Query log

`~/Library/Application Support/db-proxy/log.sqlite` has a `log` table with columns ts (UTC), agent, env, db, mode, sql, duration_ms, row_count, is_error and response. **It contains full query results, including prod data.** That's why it is restricted: dir `0700`, file `0600`, excluded from Time Machine (including the `-wal`/`-shm` files), `secure_delete` on, and rows older than 7 days deleted at startup and hourly.

```sh
sqlite3 -header -column ~/Library/Application\ Support/db-proxy/log.sqlite \
  "select ts, agent, env, db, mode, duration_ms, row_count, substr(sql,1,60) from log order by id desc limit 20"
```

## Signing

The Keychain lets an app read the items it created **without a dialog only if it's the same app**, identified by its code signature. An unsigned or ad-hoc-signed rebuild counts as a different app, and every read blocks on an "allow access?" dialog. `scripts/build.sh` signs with your Apple Development identity and the fixed identifier `dev.db-proxy`, so rebuilds keep access.

Create the certificate: **Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates → + → Apple Development**. Then confirm:

```sh
security find-identity -v -p codesigning     # should list "Apple Development: …"
```

## Troubleshooting

- **`0 valid identities found` although the certificate exists:** the Apple WWDR **G3** intermediate is missing (often only the expired G1 is installed). Install it from Apple:
  ```sh
  curl -fLO https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
  security add-certificates -k ~/Library/Keychains/login.keychain-db AppleWWDRCAG3.cer
  ```
- **`swift build` fails with `Undefined symbols … PackageDescription.Package.__allocating_init`:** the Command Line Tools install is mismatched. Use Xcode's toolchain: `scripts/build.sh` sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or run `sudo xcode-select -s /Applications/Xcode.app`.
- **A Keychain dialog appears after a rebuild:** the binary isn't signed with the same identity as before. Rebuild with `scripts/build.sh`.
- **`no connection to <server> within 5s`:** run `db-proxy check` for the exact cause.

## Development

```sh
scripts/build.sh debug
DB_PROXY_TEST_PASSWORD=... DB_PROXY_TEST_USER=postgres DB_PROXY_TEST_DB=postgres scripts/test.sh
```

`scripts/test.sh` starts a throwaway server on port 7499 with a generated config, a separate Keychain service (`db-proxy-test`) and a temp log dir, then runs `scripts/checks.sh` (36 end-to-end checks covering auth, read-only enforcement, multi-statement rejection, the result cap, connection diagnosis, type decoding, log protections and retention) against your local Postgres. Use a non-superuser role; the checks only run read-only statements and `SET`s.

Design notes and decisions: [`DESIGN.md`](DESIGN.md).

## Limitations

- macOS only (Keychain, launchd).
- Postgres only.
- `tls = "require"` encrypts but doesn't verify the server certificate (like libpq `sslmode=require`).
- No transactions across calls; one call is one unit of work.
- A result with zero rows returns empty `columns`, and `numeric` drops trailing zeros (`12.3400` → `"12.34"`).
- Config and token changes need a restart.
