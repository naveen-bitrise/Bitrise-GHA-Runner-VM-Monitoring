#!/bin/bash
# send_metrics_to_newrelic.sh — Post VM time-series metrics to New Relic Metrics API
# Usage: send_metrics_to_newrelic.sh <csv_path>

set -euo pipefail

DAEMON_ENV="/usr/local/bin/gha-monitoring/daemon.env"
LOG_FILE="/tmp/gha-monitoring/newrelic.log"
NR_METRICS_URL="https://metric-api.newrelic.com/metric/v1"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] send_metrics: $*" >> "$LOG_FILE" 2>&1 || true
}

ts_to_epoch_ms() {
  local ts="$1"
  local epoch
  if [[ "$(uname)" == "Darwin" ]]; then
    epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts" "+%s" 2>/dev/null) || epoch=0
  else
    epoch=$(date -d "$ts" "+%s" 2>/dev/null) || epoch=0
  fi
  echo $(( epoch * 1000 ))
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

  # Build metrics JSON array from all CSV data rows
  local metrics_json=""
  local row_count=0

  while IFS=',' read -r ts cpu_user cpu_system cpu_idle cpu_nice mem_used mem_free mem_cached load1 load5 load15 swap_used swap_free; do
    [[ "$ts" == "timestamp" ]] && continue  # skip header

    local ts_ms
    ts_ms=$(ts_to_epoch_ms "$ts")

    local row_json
    row_json=$(printf \
      '{"name":"gha.vm.cpu.user_pct","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.cpu.system_pct","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.cpu.idle_pct","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.memory.used_mb","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.memory.free_mb","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.memory.cached_mb","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.load.1m","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.load.5m","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.load.15m","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.swap.used_mb","type":"gauge","value":%s,"timestamp":%s},{"name":"gha.vm.swap.free_mb","type":"gauge","value":%s,"timestamp":%s}' \
      "$cpu_user"   "$ts_ms" \
      "$cpu_system" "$ts_ms" \
      "$cpu_idle"   "$ts_ms" \
      "$mem_used"   "$ts_ms" \
      "$mem_free"   "$ts_ms" \
      "$mem_cached" "$ts_ms" \
      "$load1"      "$ts_ms" \
      "$load5"      "$ts_ms" \
      "$load15"     "$ts_ms" \
      "$swap_used"  "$ts_ms" \
      "$swap_free"  "$ts_ms")

    if [[ -z "$metrics_json" ]]; then
      metrics_json="$row_json"
    else
      metrics_json="${metrics_json},${row_json}"
    fi
    row_count=$(( row_count + 1 ))
  done < "$csv"

  if [[ $row_count -eq 0 ]]; then
    log "WARNING: no data rows in CSV, skipping"
    return 0
  fi

  # Write payload to temp file (avoids arg-length limits for large payloads)
  local payload_file="/tmp/gha-monitoring/nr_metrics_payload.json"
  mkdir -p "$(dirname "$payload_file")"
  cat > "$payload_file" <<PAYLOAD
[{"common":{"attributes":{"runner.name":"${RUNNER_NAME:-}","runner.os":"${runner_os}","runner.arch":"${RUNNER_ARCH:-}","runner.cpu_count":${cpu_count},"github.run_id":"${GITHUB_RUN_ID:-}","github.job":"${GITHUB_JOB:-}","github.workflow":"${GITHUB_WORKFLOW:-}","github.repository":"${GITHUB_REPOSITORY:-}","github.branch":"${GITHUB_REF_NAME:-}"}},"metrics":[${metrics_json}]}]
PAYLOAD

  local resp_file="/tmp/gha-monitoring/nr_metrics_resp.txt"
  local http_code
  http_code=$(curl --silent --max-time 30 \
    -X POST \
    -H "Api-Key: ${NEW_RELIC_LICENSE_KEY}" \
    -H "Content-Type: application/json" \
    -d "@${payload_file}" \
    -w "%{http_code}" \
    -o "$resp_file" \
    "$NR_METRICS_URL") || http_code="curl_error"

  log "HTTP ${http_code} — ${row_count} rows, $(( row_count * 11 )) data points"
  if [[ "$http_code" != 2* ]]; then
    log "ERROR: $(cat "$resp_file" 2>/dev/null || true)"
  fi
}

main "$@" || true
exit 0
