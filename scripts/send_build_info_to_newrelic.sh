#!/bin/bash
# send_build_info_to_newrelic.sh — Post GHABuildInfo event to New Relic Events API
# Usage: send_build_info_to_newrelic.sh <csv_path>

set -euo pipefail

DAEMON_ENV="/usr/local/bin/gha-monitoring/daemon.env"
LOG_FILE="/tmp/gha-monitoring/newrelic.log"

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

main() {
  local csv="${1:-}"

  if [[ -z "$csv" || ! -f "$csv" ]]; then
    log "WARNING: CSV not found: ${csv:-<not provided>}, skipping"
    return 0
  fi

  # Load credentials
  [[ -f "$DAEMON_ENV" ]] && source "$DAEMON_ENV"

  if [[ -z "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
    log "ERROR: NEW_RELIC_LICENSE_KEY not set in $DAEMON_ENV"
    return 0
  fi
  if [[ -z "${NEW_RELIC_ACCOUNT_ID:-}" ]]; then
    log "ERROR: NEW_RELIC_ACCOUNT_ID not set in $DAEMON_ENV"
    return 0
  fi

  local nr_events_url="https://insights-collector.newrelic.com/v1/accounts/${NEW_RELIC_ACCOUNT_ID}/events"

  # Detect OS and CPU count
  if [[ "$(uname)" == "Darwin" ]]; then
    local runner_os="macOS"
    local cpu_count
    cpu_count=$(sysctl -n hw.logicalcpu 2>/dev/null) || cpu_count=0
  else
    local runner_os="Linux"
    local cpu_count
    cpu_count=$(nproc 2>/dev/null) || cpu_count=0
  fi

  # Parse commit author from GITHUB_EVENT_PATH (falls back to GITHUB_ACTOR)
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

  # Compute build_duration_seconds from first and last CSV timestamps
  local first_ts last_ts build_duration
  first_ts=$(awk -F',' 'NR==2{print $1; exit}' "$csv")
  last_ts=$(awk -F',' 'NR>1{last=$1} END{print last}' "$csv")

  build_duration=0
  if [[ -n "$first_ts" && -n "$last_ts" && "$first_ts" != "$last_ts" ]]; then
    local first_epoch last_epoch
    first_epoch=$(ts_to_epoch "$first_ts")
    last_epoch=$(ts_to_epoch "$last_ts")
    build_duration=$(( last_epoch - first_epoch )) || build_duration=0
    [[ $build_duration -lt 0 ]] && build_duration=0
  fi

  # Current time as epoch ms for the event timestamp
  local now_ms
  now_ms=$(( $(date '+%s') * 1000 ))

  # Write event payload to temp file
  local payload_file="/tmp/gha-monitoring/nr_build_info_payload.json"
  mkdir -p "$(dirname "$payload_file")"
  cat > "$payload_file" <<PAYLOAD
[{"eventType":"GHABuildInfo","run_id":"${GITHUB_RUN_ID:-}","run_number":"${GITHUB_RUN_NUMBER:-}","run_attempt":"${GITHUB_RUN_ATTEMPT:-}","job_name":"${GITHUB_JOB:-}","workflow_name":"${GITHUB_WORKFLOW:-}","repository":"${GITHUB_REPOSITORY:-}","branch":"${GITHUB_REF_NAME:-}","sha":"${GITHUB_SHA:-}","event_name":"${GITHUB_EVENT_NAME:-}","actor":"${GITHUB_ACTOR:-}","commit_author":"${commit_author}","runner_name":"${RUNNER_NAME:-}","runner_os":"${runner_os}","runner_arch":"${RUNNER_ARCH:-}","cpu_count":${cpu_count},"build_duration_seconds":${build_duration},"timestamp":${now_ms}}]
PAYLOAD

  local resp_file="/tmp/gha-monitoring/nr_build_info_resp.txt"
  local http_code
  http_code=$(curl --silent --max-time 10 \
    -X POST \
    -H "Api-Key: ${NEW_RELIC_LICENSE_KEY}" \
    -H "Content-Type: application/json" \
    -d "@${payload_file}" \
    -w "%{http_code}" \
    -o "$resp_file" \
    "$nr_events_url") || http_code="curl_error"

  log "HTTP ${http_code} — build_duration=${build_duration}s, actor=${GITHUB_ACTOR:-}, commit_author=${commit_author}"
  if [[ "$http_code" != 2* ]]; then
    log "ERROR: $(cat "$resp_file" 2>/dev/null || true)"
  fi
}

main "$@" || true
exit 0
