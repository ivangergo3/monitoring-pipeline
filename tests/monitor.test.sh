#!/usr/bin/env bash
# Exercise the real Bash CLI and curl against a local HTTP fixture.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
server_pid=''
cleanup() { if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$work"; }
trap cleanup EXIT
node "$ROOT/tests/http-fixture.mjs" "$work/port" &
server_pid=$!
for _ in {1..50}; do [ ! -s "$work/port" ] || break; sleep 0.1; done
[ -s "$work/port" ] || { echo 'HTTP fixture failed to start' >&2; exit 1; }
base="http://127.0.0.1:$(cat "$work/port")"
count=0
pass() { count=$((count + 1)); printf 'ok %s - %s\n' "$count" "$1"; }
monitor() { bash "$ROOT/scripts/monitor.sh" "$@" --config "$work/apps.json" --results "$work/results" --output "$work/dist"; }
config() {
  local overrides=${2:-}
  if [ -z "$overrides" ]; then overrides='{}'; fi
  jq -n --arg url "$base/$1" --argjson overrides "$overrides" \
    '{applications:[({id:"test",name:"Test app",url:$url} + $overrides)]}' > "$work/apps.json"
}
assert_result() { jq -e "$1" "$work/results/test.json" >/dev/null; }

config ok
monitor matrix | jq -e '.include == [{id:"test"}]' >/dev/null
pass 'dynamic matrix'
monitor check --app test
assert_result '.status == "healthy" and .http_status == 200 and .error == null and .response_ms >= 0'
pass 'healthy response'
config fail
monitor check --app test
assert_result '.status == "unhealthy" and .http_status == 503 and (.error | contains("received 503"))'
pass 'HTTP failure is a publishable observation'
config fail '{"expected_status":503}'
monitor check --app test
assert_result '.status == "healthy"'
pass 'custom expected status'
config redirect
monitor check --app test
assert_result '.status == "healthy" and .http_status == 200'
pass 'follow redirects'
for path in slow slow-body; do
  config "$path" '{"timeout_seconds":0.05}'
  monitor check --app test
  assert_result '.status == "unhealthy" and (.error | contains("curl exit 28"))'
  pass "timeout: $path"
done
config ok '{"url":"http://127.0.0.1:1","timeout_seconds":0.1}'
monitor check --app test
assert_result '.status == "unhealthy" and .http_status == null and (.error | length > 0)'
pass 'connection error'

config ok
for kind in missing corrupt mismatch multiple; do
  case "$kind" in
    missing) rm "$work/results/test.json" ;;
    corrupt) printf 'broken' > "$work/results/test.json" ;;
    mismatch) printf '{"id":"other","status":"healthy"}' > "$work/results/test.json" ;;
    multiple) printf '{"id":"test","status":"healthy"}\n{"id":"test","status":"unhealthy"}' > "$work/results/test.json" ;;
  esac
  monitor build
  jq -e '.applications[0].status == "unknown"' "$work/dist/status.json" >/dev/null
  pass "$kind result becomes unknown"
done

config ok '{"name":"<script>alert(1)</script>"}'
monitor local
cmp "$ROOT/site/index.html" "$work/dist/index.html"
cmp "$ROOT/site/dashboard.mjs" "$work/dist/dashboard.mjs"
jq -e '.applications[0].name == "<script>alert(1)</script>"' "$work/dist/status.json" >/dev/null
config ok '{"name":"Changed app"}'
GITHUB_REPOSITORY=example/repo GITHUB_RUN_ID=123 monitor build
jq -e '.applications[0].name == "Changed app" and .run_url == "https://github.com/example/repo/actions/runs/123"' "$work/dist/status.json" >/dev/null
cmp "$ROOT/site/index.html" "$work/dist/index.html"
pass 'only JSON changes; static shell and special text are preserved'

config ok
cp "$work/apps.json" "$work/good.json"
for mutation in '.applications=[]' '.applications += .applications' \
  '.applications[0].id="../escape"' '.applications[0].name=" "' \
  '.applications[0].url="javascript:alert(1)"' '.applications[0].url="https://user:pass@example.com"' \
  '.applications[0].expected_status=true' '.applications[0].expected_status=200.5' \
  '.applications[0].timeout_seconds=0' '.applications[0].timeout_seconds=61'; do
  jq "$mutation" "$work/good.json" > "$work/apps.json"
  if monitor matrix >/dev/null 2>&1; then echo "Invalid config accepted: $mutation" >&2; exit 1; fi
done
pass 'reject invalid configs'
cp "$work/good.json" "$work/apps.json"
if monitor check --app missing >/dev/null 2>&1; then echo 'Unknown app accepted' >&2; exit 1; fi
pass 'reject unknown app'
printf '%s Bash tests passed\n' "$count"
