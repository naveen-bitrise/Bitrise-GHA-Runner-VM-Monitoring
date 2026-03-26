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
LAST_OUTPUT_FILE=""

# GitHub repo to push metrics into (set these during VM warmup)
# METRICS_REPO: e.g. "your-org/your-repo"
# METRICS_TOKEN: GitHub personal access token or deploy key with push access
VM_NAME="${VM_NAME:-$(hostname)}"
REPO_CLONE_DIR="/tmp/metrics-repo"

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
        LAST_OUTPUT_FILE="$OUTPUT_FILE"
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

        push_metrics "$LAST_OUTPUT_FILE"
    fi
}

# Function to push the CSV to the metrics repo under metrics/<vm_name>/
push_metrics() {
    local csv_file="$1"

    if [ -z "$csv_file" ] || [ ! -f "$csv_file" ]; then
        echo "[$(date)] push_metrics: no CSV file to push, skipping"
        return
    fi

    if [ -z "$METRICS_REPO" ] || [ -z "$METRICS_TOKEN" ]; then
        echo "[$(date)] push_metrics: METRICS_REPO or METRICS_TOKEN not set, skipping push"
        return
    fi

    echo "[$(date)] Pushing metrics to ${METRICS_REPO} under metrics/${VM_NAME}/"

    # Clone or update the repo
    if [ -d "$REPO_CLONE_DIR/.git" ]; then
        git -C "$REPO_CLONE_DIR" pull --quiet
    else
        rm -rf "$REPO_CLONE_DIR"
        git clone --quiet "https://x-access-token:${METRICS_TOKEN}@github.com/${METRICS_REPO}.git" "$REPO_CLONE_DIR"
    fi

    # Copy the CSV into the vm-named subfolder
    mkdir -p "${REPO_CLONE_DIR}/metrics/${VM_NAME}"
    cp "$csv_file" "${REPO_CLONE_DIR}/metrics/${VM_NAME}/"

    # Commit and push
    cd "$REPO_CLONE_DIR"
    git config user.email "gha-monitor@$(hostname)"
    git config user.name "GHA Monitor Daemon"
    git add "metrics/${VM_NAME}/$(basename $csv_file)"
    git commit --quiet -m "metrics(${VM_NAME}): $(basename $csv_file)"
    git push --quiet

    echo "[$(date)] Metrics pushed: metrics/${VM_NAME}/$(basename $csv_file)"
    cd - > /dev/null
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
