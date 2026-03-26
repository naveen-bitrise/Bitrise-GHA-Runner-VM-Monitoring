#!/bin/bash
# push_metrics_hook.sh - GHA runner hook: pushes metrics CSV after each job completes
# Configured via ACTIONS_RUNNER_HOOK_JOB_COMPLETED in the runner's .env

DAEMON_ENV="/usr/local/bin/gha-monitoring/daemon.env"
OUTPUT_DIR="/tmp/gha-monitoring"
REPO_CLONE_DIR="/tmp/metrics-repo"

# Load credentials written by warmup_runner.sh
[ -f "$DAEMON_ENV" ] && source "$DAEMON_ENV"

if [ -z "$METRICS_REPO" ] || [ -z "$METRICS_TOKEN" ]; then
    echo "push_metrics_hook: METRICS_REPO or METRICS_TOKEN not set, skipping"
    exit 0
fi

# Find the most recently written CSV
LATEST_CSV=$(ls -t "$OUTPUT_DIR"/monitoring-*.csv 2>/dev/null | head -1)

if [ -z "$LATEST_CSV" ]; then
    echo "push_metrics_hook: no metrics file found, skipping"
    exit 0
fi

echo "push_metrics_hook: pushing $(basename $LATEST_CSV) for VM: ${VM_NAME}"

# Clone or pull the repo
if [ -d "$REPO_CLONE_DIR/.git" ]; then
    git -C "$REPO_CLONE_DIR" pull --quiet
else
    rm -rf "$REPO_CLONE_DIR"
    git clone --quiet "https://x-access-token:${METRICS_TOKEN}@github.com/${METRICS_REPO}.git" "$REPO_CLONE_DIR"
fi

mkdir -p "${REPO_CLONE_DIR}/metrics/${VM_NAME}"
cp "$LATEST_CSV" "${REPO_CLONE_DIR}/metrics/${VM_NAME}/"

cd "$REPO_CLONE_DIR"
git config user.email "gha-monitor@$(hostname)"
git config user.name "GHA Monitor Hook"
git add "metrics/${VM_NAME}/$(basename $LATEST_CSV)"
git commit --quiet -m "metrics(${VM_NAME}): $(basename $LATEST_CSV)"
git push --quiet

echo "push_metrics_hook: done - metrics/${VM_NAME}/$(basename $LATEST_CSV)"
