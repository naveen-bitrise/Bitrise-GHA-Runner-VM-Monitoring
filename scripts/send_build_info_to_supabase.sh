#!/bin/bash
# send_build_info_to_supabase.sh — Upsert one row to Supabase builds table
# Usage: send_build_info_to_supabase.sh <csv_path>

set -euo pipefail

DAEMON_ENV="${DAEMON_ENV:-/usr/local/bin/gha-monitoring/daemon.env}"
LOG_FILE="/tmp/gha-monitoring/supabase.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] send_build_info: $*" >> "$LOG_FILE" 2>&1 || true
}

ts_to_epoch() {
  local ts="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    date -j -f "%Y-%m-%d %H:%M:%S" "$ts" "+%s" 2>/dev/null || echo 0
  else
    date -d "$ts" "+%s" 2>/dev/null || echo 0
  fi
}

ts_to_iso() {
  echo "${1/ /T}+00:00"
}

main() {
  local csv="${1:-}"

  if [[ -z "$csv" || ! -f "$csv" ]]; then
    log "WARNING: CSV not found: ${csv:-<not provided>}, skipping"
    return 0
  fi

  local line_count
  line_count=$(wc -l < "$csv")
  if [[ "$line_count" -le 1 ]]; then
    log "WARNING: CSV has no data rows, skipping"
    return 0
  fi

  # Load credentials
  [[ -f "$DAEMON_ENV" ]] && source "$DAEMON_ENV"

  SUPABASE_URL="${SUPABASE_URL:-https://${SUPABASE_PROJECT_ID:-}.supabase.co}"

  if [[ -z "${SUPABASE_PROJECT_ID:-}" && -z "${SUPABASE_URL:-}" ]]; then
    log "ERROR: SUPABASE_PROJECT_ID not set in $DAEMON_ENV"
    return 0
  fi
  if [[ -z "${SUPABASE_PUBLISHABLE_KEY:-}" ]]; then
    log "ERROR: SUPABASE_PUBLISHABLE_KEY not set in $DAEMON_ENV"
    return 0
  fi

  # Detect OS and CPU count
  local runner_os cpu_count
  if [[ "$(uname)" == "Darwin" ]]; then
    runner_os="macOS"
    cpu_count=$(sysctl -n hw.logicalcpu 2>/dev/null) || cpu_count=0
  else
    runner_os="Linux"
    cpu_count=$(nproc 2>/dev/null) || cpu_count=0
  fi

  # Parse commit author from GITHUB_EVENT_PATH; fall back to GITHUB_ACTOR
  local commit_author=""
  if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
    commit_author=$(python3 -c "
import json
try:
  d = json.load(open('${GITHUB_EVENT_PATH}'))
  print(d.get('head_commit', {}).get('author', {}).get('username') or
        d.get('head_commit', {}).get('author', {}).get('name') or '')
except: print('')
" 2>/dev/null) || commit_author=""
  fi
  commit_author="${commit_author:-${GITHUB_ACTOR:-}}"

  # Compute started_at, completed_at, build_duration_seconds from CSV
  local first_ts last_ts
  first_ts=$(awk -F',' 'NR==2{print $1; exit}' "$csv")
  last_ts=$(awk -F',' 'NR>1{last=$1} END{print last}' "$csv")

  local started_at completed_at build_duration
  started_at=$(ts_to_iso "$first_ts")
  completed_at="$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')"

  build_duration=0
  if [[ -n "$first_ts" && -n "$last_ts" && "$first_ts" != "$last_ts" ]]; then
    local first_epoch last_epoch
    first_epoch=$(ts_to_epoch "$first_ts")
    last_epoch=$(ts_to_epoch "$last_ts")
    build_duration=$(( last_epoch - first_epoch )) || build_duration=0
    [[ $build_duration -lt 0 ]] && build_duration=0
  fi

  # Write payload to temp file
  local payload_file="/tmp/gha-monitoring/supabase_build_info_payload.json"
  mkdir -p "$(dirname "$payload_file")"
  cat > "$payload_file" <<PAYLOAD
{"run_id":"${GITHUB_RUN_ID:-}","run_number":"${GITHUB_RUN_NUMBER:-}","run_attempt":"${GITHUB_RUN_ATTEMPT:-}","vm_name":"${RUNNER_NAME:-}","workflow_name":"${GITHUB_WORKFLOW:-}","repository":"${GITHUB_REPOSITORY:-}","branch":"${GITHUB_REF_NAME:-}","sha":"${GITHUB_SHA:-}","event_name":"${GITHUB_EVENT_NAME:-}","actor":"${GITHUB_ACTOR:-}","commit_author":"${commit_author}","runner_os":"${runner_os}","runner_arch":"${RUNNER_ARCH:-}","cpu_count":${cpu_count},"build_duration_seconds":${build_duration},"started_at":"${started_at}","completed_at":"${completed_at}"}
PAYLOAD

  local resp_file="/tmp/gha-monitoring/supabase_build_info_resp.txt"
  local http_code
  http_code=$(curl --silent --max-time 10 \
    -X POST "${SUPABASE_URL}/rest/v1/builds" \
    -H "apikey: ${SUPABASE_PUBLISHABLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_PUBLISHABLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "@${payload_file}" \
    -w "%{http_code}" \
    -o "$resp_file") || http_code="curl_error"

  log "HTTP ${http_code} — run_id=${GITHUB_RUN_ID:-}, duration=${build_duration}s"
  if [[ "$http_code" != 2* ]]; then
    log "ERROR response: $(cat "$resp_file" 2>/dev/null || true)"
  fi
}

main "$@" || true
exit 0
