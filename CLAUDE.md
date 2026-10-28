# CLAUDE.md

db-proxy: a Swift macOS CLI + local HTTP MCP server that fronts many Postgres databases. See README.md for usage and DESIGN.md for decisions.

## Layout

- `Sources/db-proxy/CLI.swift`: ArgumentParser commands (`serve`, `check`, `password`, `token`, `install`).
- `Serve.swift`: MCP server, tools, HTTP listener (Hummingbird), pools per (server, user, db), query log wiring.
- `Query.swift`: one call = lease → `BEGIN [READ ONLY]` → `SET LOCAL` timeouts → agent SQL → commit/rollback → `DISCARD ALL`. Lease timeout, read retry, result cap, cell → JSON decoding.
- `Config.swift`: TOML config (`TOMLDecoder`, snake_case keys), validation, connection configs, connect diagnosis.
- `Keychain.swift`: generic-password items, service `db-proxy` (override with `DB_PROXY_KEYCHAIN_SERVICE`).
- `QueryLog.swift`: SQLite (system `SQLite3`), retention, file protections.
- `scripts/build.sh`: build + codesign. `scripts/test.sh`: e2e harness. `scripts/checks.sh`: the checks.

## Commands

```sh
scripts/build.sh debug                    # always build through this: it signs (see Keychain below)
DB_PROXY_TEST_PASSWORD=... DB_PROXY_TEST_USER=<role> DB_PROXY_TEST_DB=<db> scripts/test.sh
```

Needs Xcode; `build.sh` sets `DEVELOPER_DIR` because the Command Line Tools' SwiftPM manifest library may be mismatched. Tests need a local Postgres and run on port 7499, so they don't collide with an installed service on 7432.

## Invariants (don't break these)

- **Never rewrite agent SQL.** No appended `LIMIT`, no wrapping. Size is bounded by `max_result_bytes` (abort, never truncate).
- **Agent SQL must go through `PostgresConnection.query` (extended protocol).** It is what rejects multi-statement strings. Never use `simpleQuery`. `checks.sh` "multi-statement rejected" guards this.
- **Postgres enforces read-only** (`BEGIN READ ONLY` + roles). Don't add a SQL parser as a security measure.
- **Reset every connection** before release (`ROLLBACK` if needed, `DISCARD ALL`).
- **Never retry writes.**
- **Keep the tool schema tiny** (2 tools, no `outputSchema`, no `structuredContent`). Context cost is the point of the project.
- **The SDK's `Initialize` handler is replaced after `server.start`** because the built-in one rejects every client after the first. Keep that override.
- **`serve` calls `exit(0)` after `app.runService()` returns** (SIGTERM). Otherwise the pool tasks keep the process alive and launchd stops hang.
- **No secrets or real hostnames in the repo.** `databases.toml` is gitignored; use `databases.example.toml`.

## Gotchas

- Keychain access is tied to the code signature. Unsigned rebuilds block on an approval dialog when reading existing items, which hangs headless runs. Build with `scripts/build.sh`; `test.sh` recreates its items every run.
- PostgresNIO always uses binary result format; every type needs an explicit decoder in `jsonValue`. Unknown types fall back to a printable-text heuristic, then a `cast ::text` placeholder.
- PostgresNIO has no CancelRequest; cancelling a row stream drains it. The result cap closes the connection instead.
- The pool retries failed connects silently. Lease timeouts are explained by `Config.diagnosis` (one direct connect).
- Hummingbird puts HTTP/1 `Host` in `request.head.authority`; it's copied into the MCP request for the Origin/Host validator.

## Style

Small and boring. Mark deliberate shortcuts with a `ponytail:` comment naming the limit and the upgrade path. Every behaviour change needs a line in `scripts/checks.sh`.
