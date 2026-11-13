#!/usr/bin/env bash
# Config-driven HTTP checks and latest-results publishing. Bash 3.2+, curl, jq.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { printf '%s\n' "$*" >&2; exit 1; }
now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
for dependency in jq curl; do
  command -v "$dependency" >/dev/null || die "Required command not found: $dependency"
done

command_name=${1:-}
case "$command_name" in matrix|check|build|local) shift ;; *) die 'Usage: bash scripts/monitor.sh {matrix|check|build|local} [--config FILE] [--app ID] [--results DIR] [--output DIR]' ;; esac
config="$ROOT/apps.json"
results=results
output=dist
app_id=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die "Missing value for $1"
  case "$1" in
    --config) config=$2 ;;
    --app) app_id=$2 ;;
    --results) results=$2 ;;
    --output) output=$2 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift 2
done
config_json=$(jq -ce -f "$ROOT/scripts/validate-config.jq" "$config")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check_app() {
  local app=$1 id url expected timeout checked metrics curl_code code seconds error status
  id=$(jq -r '.id' <<< "$app")
  url=$(jq -r '.url' <<< "$app")
  expected=$(jq -r '.expected_status // 200' <<< "$app")
  timeout=$(jq -r '.timeout_seconds // 10' <<< "$app")
  checked=$(now)
  # --disable ignores ~/.curlrc; restrict initial and redirected protocols.
  # HTTP errors are observations, so deliberately do not use --fail.
  if metrics=$(curl --disable --silent --show-error --location --max-redirs 10 \
    --proto '=http,https' --proto-redir '=http,https' --globoff \
    --connect-timeout "$timeout" --max-time "$timeout" \
    --user-agent 'monitoring-pipeline/2.0' --header 'Cache-Control: no-cache' \
    --output /dev/null --write-out '%{http_code}\t%{time_total}' \
    --url "$url" 2> "$work/curl-error"); then
    curl_code=0
  else
    curl_code=$?
  fi
  IFS=$'\t' read -r code seconds <<< "$metrics"
  code=${code:-000}
  seconds=${seconds:-0}
  status=unhealthy
  error=''
  if [ "$curl_code" -ne 0 ]; then
    error="curl exit $curl_code: $(cat "$work/curl-error")"
  elif [ "$code" = "$expected" ]; then
    status=healthy
  else
    error="Expected HTTP $expected, received $code"
  fi
  mkdir -p "$results"
  jq -n --arg id "$id" --arg status "$status" --arg checked "$checked" \
    --arg code "$code" --arg seconds "$seconds" --arg error "$error" '
    {id:$id, status:$status, checked_at:$checked,
     http_status:(if $code == "000" then null else ($code|tonumber) end),
     response_ms:($seconds|tonumber|. * 1000|round),
     error:(if $error == "" then null else $error end)}' > "$work/result.json"
  mv "$work/result.json" "$results/$id.json"
  printf '%s: %s (%s ms)\n' "$id" "$status" "$(jq -r '.response_ms' "$results/$id.json")"
}

build_report() {
  local app id result run_url=''
  : > "$work/apps.jsonl"
  while IFS= read -r app; do
    id=$(jq -r '.id' <<< "$app")
    if result=$(jq -sce --arg id "$id" '
      select(length == 1) | .[0]
      | select(type == "object" and .id == $id and (.status == "healthy" or .status == "unhealthy"))
      | {status,checked_at,http_status,response_ms,error}' "$results/$id.json" 2>/dev/null); then
      :
    else
      result='{"status":"unknown","checked_at":null,"http_status":null,"response_ms":null,"error":"No valid result was produced by this runner"}'
    fi
    jq -cn --argjson app "$app" --argjson result "$result" '$app + $result' >> "$work/apps.jsonl"
  done < <(jq -c '.applications[]' <<< "$config_json")
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    run_url="https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  fi
  mkdir -p "$output"
  jq -s --arg title "$(jq -r '.title // "Application health"' <<< "$config_json")" \
    --arg generated "$(now)" --arg run_url "$run_url" \
    '{title:$title,generated_at:$generated,run_url:$run_url,applications:.}' \
    "$work/apps.jsonl" > "$work/status.json"
  cp -R "$ROOT/site/." "$output/"
  mv "$work/status.json" "$output/status.json"
  touch "$output/.nojekyll"
}

case "$command_name" in
  matrix) jq -c '{include:[.applications[] | {id}]}' <<< "$config_json" ;;
  check)
    app=$(jq -ce --arg id "$app_id" '.applications[] | select(.id == $id)' <<< "$config_json") || die '--app must match a configured application id'
    check_app "$app"
    ;;
  build) build_report ;;
  local)
    while IFS= read -r app; do check_app "$app"; done < <(jq -c '.applications[]' <<< "$config_json")
    build_report
    ;;
esac
