#!/bin/bash
# monitor_daemon.sh - Auto-detects GitHub Actions jobs and starts monitoring

DAEMON_DIR="$(dirname "$0")"

# Load credentials written by warmup_runner.sh
[ -f "${DAEMON_DIR}/daemon.env" ] && source "${DAEMON_DIR}/daemon.env"

MONITOR_SCRIPT="${DAEMON_DIR}/collect_metrics.sh"
OUTPUT_DIR="/tmp/gha-monitoring"
CHECK_INTERVAL=5
MONITOR_PID=""
CURRENT_JOB_ID=""

mkdir -p "$OUTPUT_DIR"

echo "GitHub Actions Monitor Daemon started"
echo "Monitoring for GHA runner processes..."
echo "Data will be saved to: $OUTPUT_DIR"
echo ""

# Function to check if GHA runner is active
check_runner_active() {
    # Look for GitHub Actions runner processes
    # The runner typically has process names like:
    # - Runner.Listener
    # - Runner.Worker
    # - runsvc.sh (on some systems)
    pgrep -f "Runner.Worker" > /dev/null 2>&1
    return $?
}

# Function to get job identifier (timestamp-based for now)
get_job_id() {
    # Try to get workflow info from environment if available
    # Otherwise use timestamp
    if [ -n "$GITHUB_RUN_ID" ]; then
        echo "${GITHUB_RUN_ID}_${GITHUB_RUN_NUMBER}_$(date +%s)"
    else
        date +"%Y%m%d_%H%M%S"
    fi
}

# Function to start monitoring
start_monitoring() {
    if [ -z "$MONITOR_PID" ] || ! ps -p "$MONITOR_PID" > /dev/null 2>&1; then
        CURRENT_JOB_ID=$(get_job_id)
        OUTPUT_FILE="$OUTPUT_DIR/monitoring-${CURRENT_JOB_ID}.csv"

        echo "[$(date)] Job detected - Starting monitoring"
        echo "[$(date)] Output file: $OUTPUT_FILE"

        "$MONITOR_SCRIPT" "$OUTPUT_FILE" &
        MONITOR_PID=$!
        echo "[$(date)] Monitor PID: $MONITOR_PID"
    fi
}

# Function to stop monitoring
stop_monitoring() {
    if [ -n "$MONITOR_PID" ] && ps -p "$MONITOR_PID" > /dev/null 2>&1; then
        echo "[$(date)] Job completed - Stopping monitoring"
        kill $MONITOR_PID 2>/dev/null
        wait $MONITOR_PID 2>/dev/null
        MONITOR_PID=""
        CURRENT_JOB_ID=""
        echo "[$(date)] Monitoring stopped"
        echo ""
    fi
}

# Trap signals for graceful shutdown
trap 'echo "Daemon shutting down..."; stop_monitoring; exit 0' SIGTERM SIGINT

# Main monitoring loop
RUNNER_WAS_ACTIVE=false

while true; do
    if check_runner_active; then
        if [ "$RUNNER_WAS_ACTIVE" = false ]; then
            # Runner just became active
            start_monitoring
            RUNNER_WAS_ACTIVE=true
        fi
    else
        if [ "$RUNNER_WAS_ACTIVE" = true ]; then
            # Runner just stopped
            stop_monitoring
            RUNNER_WAS_ACTIVE=false
        fi
    fi

    sleep $CHECK_INTERVAL
done
