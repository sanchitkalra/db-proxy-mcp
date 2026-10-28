#!/usr/bin/env bash
# End-to-end tests: builds + signs, starts `serve` on a spare port with a generated config, an isolated
# Keychain service and a temp log dir, runs scripts/checks.sh, then checks log retention.
#   DB_PROXY_TEST_PASSWORD=... [DB_PROXY_TEST_USER=postgres] [DB_PROXY_TEST_DB=postgres] scripts/test.sh
# The role should not be a superuser; the checks only run read-only statements and `SET`s.
set -uo pipefail
cd "$(dirname "$0")/.."
export DB_PROXY_KEYCHAIN_SERVICE=db-proxy-test PORT=7499 DB=${DB_PROXY_TEST_DB:-postgres}
user=${DB_PROXY_TEST_USER:-postgres}
scripts/build.sh debug || exit 1
B=.build/debug/db-proxy
tmp=$(mktemp -d)
export LOG_DIR=$tmp/log
cfg=$tmp/test.toml
cat > "$cfg" <<TOML
[defaults]
max_result_bytes = 1_000_000

[server.local]
env = "local"
host = "localhost"
tls = "disable"
read_user = "$user"
write_user = "$user"
databases = ["$DB", "does_not_exist"]

[server.vpn-down]
env = "dev"
host = "10.255.255.1"   # blackhole: connects never complete
tls = "disable"
read_user = "nobody"
databases = ["nowhere"]
TOML

# Recreated every run so tests start clean (and still work for unsigned builds, which the
# Keychain treats as a different app after each rebuild).
for a in local/$user vpn-down/nobody token/check token/second-agent; do
  security delete-generic-password -s "$DB_PROXY_KEYCHAIN_SERVICE" -a "$a" >/dev/null 2>&1
done
echo "${DB_PROXY_TEST_PASSWORD:?set DB_PROXY_TEST_PASSWORD}" | $B password set "local/$user" --config "$cfg" >/dev/null
echo dummy | $B password set vpn-down/nobody --config "$cfg" >/dev/null
export DB_PROXY_TOKEN=$($B token add check) DB_PROXY_TOKEN2=$($B token add second-agent)

start() {
  $B serve --config "$cfg" --port $PORT --log-dir "$LOG_DIR" >> "$tmp/serve.out" 2>&1 &
  pid=$!
  for _ in $(seq 40); do curl -s -o /dev/null http://127.0.0.1:$PORT/mcp && break; sleep 0.25; done
}
start
trap 'kill $pid 2>/dev/null; rm -rf "$tmp"' EXIT
scripts/checks.sh; status=$?

echo "== 6. retention"
kill $pid; wait $pid 2>/dev/null
sqlite3 "$LOG_DIR/log.sqlite" "insert into log (ts, agent, env, db, mode, sql, duration_ms, is_error, response)
  values (strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-8 days'), 'old', 'local', 'x', 'read', 'select old', 0, 0, '{}')"
start
left=$(sqlite3 "$LOG_DIR/log.sqlite" "select count(*) from log where agent = 'old'")
kept=$(sqlite3 "$LOG_DIR/log.sqlite" "select count(*) from log where agent = 'check'")
if [ "$left" = 0 ] && [ "$kept" -gt 0 ]; then echo "ok   8-day-old rows pruned on start, recent kept"; else echo "FAIL retention: old=$left recent=$kept"; status=1; fi
exit $status
