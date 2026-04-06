#!/bin/bash
# supabase_hook.sh — ACTIONS_RUNNER_HOOK_JOB_COMPLETED hook
# Finds the latest metrics CSV and posts it to Supabase (metrics + builds tables)

set -euo pipefail

INSTALL_DIR="/usr/local/bin/gha-monitoring"
LOG_FILE="/tmp/gha-monitoring/supabase.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] supabase_hook: $*" >> "$LOG_FILE" 2>&1 || true
}

main() {
  log "Hook triggered (run_id=${GITHUB_RUN_ID:-}, job=${GITHUB_JOB:-})"

  # Find latest CSV
  local csv
  csv=$(ls -t /tmp/gha-monitoring/monitoring-*.csv 2>/dev/null | head -1) || csv=""

  if [[ -z "$csv" ]]; then
    log "WARNING: no CSV found in /tmp/gha-monitoring/, skipping"
    return 0
  fi

  log "Using CSV: $csv"

  # Send VM time-series metrics → Supabase metrics table
  bash "${INSTALL_DIR}/send_metrics_to_supabase.sh" "$csv" || true

  # Send build info → Supabase builds table
  bash "${INSTALL_DIR}/send_build_info_to_supabase.sh" "$csv" || true

  log "Done"
}

main "$@" || true
exit 0
