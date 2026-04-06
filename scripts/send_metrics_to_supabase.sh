#!/bin/bash
# send_metrics_to_supabase.sh — Batch-POST VM time-series metrics to Supabase metrics table
# Usage: send_metrics_to_supabase.sh <csv_path>

set -euo pipefail

DAEMON_ENV="${DAEMON_ENV:-/usr/local/bin/gha-monitoring/daemon.env}"
LOG_FILE="/tmp/gha-monitoring/supabase.log"
BATCH_SIZE=500

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] send_metrics: $*" >> "$LOG_FILE" 2>&1 || true
}

ts_to_iso() {
  # Convert "YYYY-MM-DD HH:MM:SS" → "YYYY-MM-DDTHH:MM:SS+00:00"
  echo "${1/ /T}+00:00"
}

flush_batch() {
  local batch_json="$1"
  local batch_rows="$2"
  local url="${SUPABASE_URL}/rest/v1/metrics"

  local resp_file="/tmp/gha-monitoring/supabase_metrics_resp.txt"
  local http_code
  http_code=$(curl --silent --max-time 30 \
    -X POST "$url" \
    -H "apikey: ${SUPABASE_PUBLISHABLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_PUBLISHABLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "[${batch_json}]" \
    -w "%{http_code}" \
    -o "$resp_file") || http_code="curl_error"

  log "HTTP ${http_code} — ${batch_rows} rows posted"
  if [[ "$http_code" != 2* ]]; then
    log "ERROR response: $(cat "$resp_file" 2>/dev/null || true)"
  fi
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

  local run_id="${GITHUB_RUN_ID:-}"
  local vm_name="${RUNNER_NAME:-}"

  local batch_json=""
  local batch_rows=0
  local total_rows=0

  mkdir -p /tmp/gha-monitoring

  while IFS=',' read -r ts cpu_user cpu_system cpu_idle cpu_nice mem_used mem_free mem_cached load1 load5 load15 swap_used swap_free; do
    [[ "$ts" == "timestamp" ]] && continue  # skip header

    local sampled_at
    sampled_at=$(ts_to_iso "$ts")

    local row
    row=$(printf \
      '{"run_id":"%s","vm_name":"%s","sampled_at":"%s","cpu_user":%s,"cpu_system":%s,"cpu_idle":%s,"cpu_nice":%s,"memory_used_mb":%s,"memory_free_mb":%s,"memory_cached_mb":%s,"load1":%s,"load5":%s,"load15":%s,"swap_used_mb":%s,"swap_free_mb":%s}' \
      "$run_id" "$vm_name" "$sampled_at" \
      "$cpu_user" "$cpu_system" "$cpu_idle" "$cpu_nice" \
      "$mem_used" "$mem_free" "$mem_cached" \
      "$load1" "$load5" "$load15" \
      "$swap_used" "$swap_free")

    if [[ -z "$batch_json" ]]; then
      batch_json="$row"
    else
      batch_json="${batch_json},${row}"
    fi
    batch_rows=$(( batch_rows + 1 ))
    total_rows=$(( total_rows + 1 ))

    if [[ "$batch_rows" -eq "$BATCH_SIZE" ]]; then
      flush_batch "$batch_json" "$batch_rows"
      batch_json=""
      batch_rows=0
    fi
  done < "$csv"

  # Flush remaining rows
  if [[ "$batch_rows" -gt 0 ]]; then
    flush_batch "$batch_json" "$batch_rows"
  fi

  if [[ "$total_rows" -eq 0 ]]; then
    log "WARNING: no data rows in CSV, skipping"
  else
    log "Done — ${total_rows} total rows"
  fi
}

main "$@" || true
exit 0
