#!/bin/bash
# warmup_runner.sh - VM warmup script: clones monitoring repo and installs daemon
# Run this as part of the VM warmup script on each boot.
#
# Usage:
#   bash warmup_runner.sh
#
# After each job, job_summary_hook.sh posts VM metric charts to the job's
# summary page and log. No GitHub token is needed.
#
# Optional:
#   VM_NAME     - Identifier for this runner shown in the summary (defaults to hostname)
#   RUNNER_HOME - Directory containing actions-runner/ (defaults to $HOME)
#
# Works on macOS (launchd) and Linux (systemd, or nohup fallback).

set -e

MONITORING_REPO="naveen-bitrise/Bitrise-GHA-Runner-VM-Monitoring"
MONITORING_BRANCH="job-summary"
SETUP_DIR="/tmp/gha-monitoring-setup"
INSTALL_DIR="/usr/local/bin/gha-monitoring"

echo "Setting up GHA VM Monitoring from ${MONITORING_REPO}@${MONITORING_BRANCH}..."

# Clean any previous setup attempt
rm -rf "$SETUP_DIR"

# Clone the monitoring repo (read-only; public clone, no token)
git clone --depth 1 --branch "$MONITORING_BRANCH" "https://github.com/${MONITORING_REPO}.git" "$SETUP_DIR"

# Install the monitoring daemon
cd "$SETUP_DIR"
SKIP_STARTUP_HINT=1 bash install_on_runner.sh

# Settings read by the daemon and the hook
DAEMON_ENV_FILE="${INSTALL_DIR}/daemon.env"
MONITORING_COMMIT=$(git -C "$SETUP_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "Installed ${MONITORING_BRANCH}@${MONITORING_COMMIT}"
cat > "$DAEMON_ENV_FILE" <<ENVEOF
export VM_NAME="${VM_NAME:-$(hostname)}"
export MONITORING_VERSION="${MONITORING_BRANCH}@${MONITORING_COMMIT}"
ENVEOF
chmod 644 "$DAEMON_ENV_FILE"

# Install the post-job hook script
cp "$SETUP_DIR/job_summary_hook.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/job_summary_hook.sh"

# Wire the hook into the GHA runner's .env file (create if it doesn't exist yet)
HOOK_SCRIPT="${INSTALL_DIR}/job_summary_hook.sh"
RUNNER_ENV="${RUNNER_HOME:-$HOME}/actions-runner/.env"

mkdir -p "$(dirname "$RUNNER_ENV")"
grep -v "ACTIONS_RUNNER_HOOK_JOB_COMPLETED" "$RUNNER_ENV" > /tmp/runner_env_tmp 2>/dev/null || true
echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${HOOK_SCRIPT}" >> /tmp/runner_env_tmp
cp /tmp/runner_env_tmp "$RUNNER_ENV"
echo "Runner hook configured in: $RUNNER_ENV"

# Start the daemon now (runs for the lifetime of this VM).
# Skip on Linux when systemd is already managing it (install_on_runner.sh as root).
if [[ "$(uname)" == "Darwin" ]] || ! systemctl is-active --quiet gha-monitor 2>/dev/null; then
  nohup "${INSTALL_DIR}/monitor_daemon.sh" >> /tmp/gha-monitoring/daemon.log 2>&1 &
  echo "Daemon started (PID $!)"
else
  echo "Daemon already running via systemd"
fi

echo ""
echo "GHA VM Monitoring installed and running."
