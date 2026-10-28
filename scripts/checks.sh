#!/usr/bin/env bash
# Checks against a running `db-proxy serve` using the test config (see scripts/test.sh).
# Usage: DB_PROXY_TOKEN=... [DB_PROXY_TOKEN2=...] [LOG_DIR=...] scripts/checks.sh
set -uo pipefail
URL=http://127.0.0.1:${PORT:-7499}/mcp
DB=${DB:-postgres}
fail=0

rpc() {  # rpc <method> <params-json> [extra curl args...]
  local m=$1 p=$2; shift 2
  curl -s -X POST "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -H 'MCP-Protocol-Version: 2025-06-18' -H "Authorization: Bearer $DB_PROXY_TOKEN" "$@" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$m\",\"params\":$p}"
}
q() {  # q <sql> [mode] [env] [db] -> tool result {isError, body}
  local args; args=$(jq -nc --arg sql "$1" --arg mode "${2:-read}" --arg env "${3:-local}" --arg db "${4:-$DB}" '{env:$env,db:$db,sql:$sql,mode:$mode}')
  rpc tools/call "{\"name\":\"query\",\"arguments\":$args}" | jq -c '{isError: .result.isError, body: (.result.content[0].text | fromjson)}'
}
check() {  # check <name> <actual> <jq-predicate>
  if echo "$2" | jq -e "$3" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1: $2"; fail=1; fi
}
status() { curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json' "$@" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'; }

echo "== 1. transport + auth"
check "no token -> 401"          "$(status)" '. == 401'
check "wrong token -> 401"       "$(status -H 'Authorization: Bearer nope')" '. == 401'
check "foreign Origin -> 403"    "$(status -H "Authorization: Bearer $DB_PROXY_TOKEN" -H 'Origin: https://evil.example')" '. == 403'
check "initialize"               "$(rpc initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"0"}}')" '.result.serverInfo.name == "db-proxy"'
check "second initialize (another agent)" "$(rpc initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check2","version":"0"}}')" '.result.serverInfo.name == "db-proxy"'
check "tools/list = 2 tools"     "$(rpc tools/list '{}')" '.result.tools | map(.name) == ["list_databases","query"]'

echo "== 2. single statement + read-only"
check "select works"             "$(q 'select 1 as a')" '.isError == false and .body == {columns:["a"],rows:[[1]],row_count:1}'
check "multi-statement rejected" "$(q 'select 1; select 2')" '.isError == true and .body.sqlstate == "42601"'
check "COMMIT escape rejected"   "$(q 'commit; create table spike_escape(x int)')" '.isError == true'
check "escape table absent"      "$(q "select to_regclass('spike_escape') is null as gone")" '.body.rows == [[true]]'
check "write blocked in read"    "$(q 'create table spike_ro(x int)')" '.isError == true and .body.sqlstate == "25006"'
# Postgres allows flipping to read-write before a snapshot; harmless because the agent gets one statement.
check "RW flip can't carry a write" "$(q 'set transaction read write' >/dev/null; q 'create table spike_ro(x int)')" '.isError == true and .body.sqlstate == "25006"'
check "SQL error has sqlstate"   "$(q 'select nope')" '.isError == true and .body.sqlstate == "42703" and .body.position == 8'
check "session state reset"      "$(q "set search_path = nowhere" write >/dev/null; q 'show search_path')" '.body.rows[0][0] != "nowhere"'

echo "== 3. result cap (test.toml sets max_result_bytes = 1_000_000)"
check "oversized result errors" "$(q 'select g, repeat(md5(g::text), 4) from generate_series(1,200000) g')" '.isError == true and (.body.error | test("exceeded"))'
check "next query still works"   "$(q 'select 2 as b')" '.body.rows == [[2]]'
check "no lingering query"       "$(q "select count(*) from pg_stat_activity where query like '%generate_series(1,200000)%' and pid <> pg_backend_pid()")" '.body.rows == [[0]]'

echo "== 4. config routing + connection errors"
check "list_databases"           "$(rpc tools/call '{"name":"list_databases","arguments":{}}' | jq '.result.content[0].text | fromjson')" "(.databases | map(\"\\(.env)/\\(.db)\") | index(\"local/$DB\") and index(\"dev/nowhere\")) and (.databases[] | select(.db==\"nowhere\") | .modes == [\"read\"])"
check "unknown db"               "$(q 'select 1' read local nope)" '.isError == true and (.body.error | test("unknown db"))'
check "write on read-only server" "$(q 'select 1' write dev nowhere)" '.isError == true and (.body.error | test("not available"))'
check "missing database explained" "$(q 'select 1' read local does_not_exist)" '.isError == true and (.body.error | test("does not exist"))'
t0=$(date +%s); r=$(q 'select 1' read dev nowhere); t1=$(date +%s)
check "VPN down explained in <10s" "$r" ".isError == true and (.body.error | test(\"VPN\")) and $((t1 - t0)) < 10"
q "select count(pg_terminate_backend(pid)) from pg_stat_activity where usename = current_user and datname = current_database() and pid <> pg_backend_pid() and application_name = ''" >/dev/null
check "survives killed connections" "$(for i in 1 2 3 4; do q 'select 1 as a'; done | jq -s 'map(.body.rows)')" '. == [[[1]],[[1]],[[1]],[[1]]]'
if [ -n "${DB_PROXY_TOKEN2:-}" ]; then
  check "second agent token works" "$(DB_PROXY_TOKEN=$DB_PROXY_TOKEN2 q 'select 1 as a')" '.body.rows == [[1]]'
fi

if [ -n "${LOG_DIR:-}" ]; then
  echo "== 5. query log"
  L="$LOG_DIR/log.sqlite"
  check "log has both agents"    "$(sqlite3 -json "$L" 'select distinct agent from log order by 1')" 'map(.agent) == ["check","second-agent"]'
  check "log stores results"     "$(sqlite3 -json "$L" "select response from log where sql = 'select 1 as a' limit 1")" '.[0].response | fromjson | .rows == [[1]]'
  check "log stores errors"      "$(sqlite3 -json "$L" "select is_error, row_count from log where db = 'nope' limit 1")" '.[0] == {is_error:1, row_count:null}'
  check "log file is 0600"       "\"$(stat -f %Lp "$L")\"" '. == "600"'
  check "log dir is 0700"        "\"$(stat -f %Lp "$LOG_DIR")\"" '. == "700"'
  check "dir excluded from Time Machine" "\"$(tmutil isexcluded "$LOG_DIR")\"" 'test("Excluded")'
  check "auto_vacuum incremental" "$(sqlite3 "$L" 'pragma auto_vacuum')" '. == 2'
fi

echo "== types"
check "interval matches psql"    "$(q "select x as v, x::text as t from unnest(array[interval '1 day 2 hours', interval '0', interval '-1 day', interval '1 year 2 mons 3 days 04:05:06.5', interval '14 mons -2 hours', interval '-00:00:01.25', interval '45 days 03:12:09']) x")" '.isError == false and (.body.rows | all(.[0] == .[1]))'
check "arrays"                   "$(q "select array[1,2] a, array['x','y'] b, '{}'::int[] c, array[true] d, array[1.5::float8] e")" '.body.rows == [[[1,2],["x","y"],[],[true],[1.5]]]'
check "array with NULL -> note"  "$(q "select array[1,null] a")" '.body.rows[0][0] | test("cast a::text")'
check "timestamp keeps micros"  "$(q "select '2024-03-03 00:14:40.286815'::timestamp a, '1999-12-31 23:59:59.5+00'::timestamptz b, '2024-01-01'::timestamp c")" '.body.rows == [["2024-03-03T00:14:40.286815","1999-12-31T23:59:59.5Z","2024-01-01T00:00:00"]]'
q "select true as b, 42::int8 as i, 1.5::float8 as f, 12.3400::numeric as n, 'x'::text as t,
          gen_random_uuid() is not null as u, '2024-03-03 00:14:40.286815'::timestamp as ts,
          '2024-03-03'::date as d, '{\"a\":[1,2]}'::jsonb as j, '\\xdead'::bytea as by,
          interval '1 day' as iv, array[1,2] as arr, null::text as nul" | jq -c .body

exit $fail
