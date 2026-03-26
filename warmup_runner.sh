#!/bin/bash
# warmup_runner.sh - VM warmup script: clones monitoring repo and installs daemon
# Run this as part of the VM warmup script on each boot.
#
# Usage:
#   bash warmup_runner.sh
#
# Required: set these before running
#   MONITORING_REPO  - GitHub repo containing this project, e.g. "your-org/your-repo"
#   METRICS_TOKEN_PLACEHOLDER    - GitHub token with push access to MONITORING_REPO
#
# Optional:
#   VM_NAME          - Identifier for this runner (defaults to hostname)

set -e

MONITORING_REPO="naveen-bitrise/Bitrise-GHA-Runner-VM-Monitoring"
SETUP_DIR="/tmp/gha-monitoring-setup"

echo "Setting up GHA VM Monitoring from ${MONITORING_REPO}..."

# Clean any previous setup attempt
rm -rf "$SETUP_DIR"

# Clone the monitoring repo
git clone "https://github.com/${MONITORING_REPO}.git" "$SETUP_DIR"

# Install the monitoring daemon
cd "$SETUP_DIR"
SKIP_STARTUP_HINT=1 bash install_on_runner.sh

# Persist METRICS_REPO and METRICS_TOKEN so the launchd daemon can read them
# These are written to a file sourced by monitor_daemon.sh via the plist environment
DAEMON_ENV_FILE="/usr/local/bin/gha-monitoring/daemon.env"
cat > "$DAEMON_ENV_FILE" <<EOF
export METRICS_REPO="${MONITORING_REPO}"
export METRICS_TOKEN="METRICS_TOKEN_PLACEHOLDER"
export VM_NAME="${VM_NAME:-$(hostname)}"
EOF
chmod 600 "$DAEMON_ENV_FILE"

# Install the post-job hook script
cp "$SETUP_DIR/push_metrics_hook.sh" /usr/local/bin/gha-monitoring/
chmod +x /usr/local/bin/gha-monitoring/push_metrics_hook.sh

# Wire the hook into the GHA runner's .env file
HOOK_SCRIPT="/usr/local/bin/gha-monitoring/push_metrics_hook.sh"
RUNNER_ENV=""

for candidate in /Users/*/actions-runner /opt/actions-runner /home/*/actions-runner; do
    if [ -f "${candidate}/.env" ]; then
        RUNNER_ENV="${candidate}/.env"
        break
    fi
done

if [ -n "$RUNNER_ENV" ]; then
    # Remove any existing entry and append
    grep -v "ACTIONS_RUNNER_HOOK_JOB_COMPLETED" "$RUNNER_ENV" > /tmp/runner_env_tmp || true
    echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${HOOK_SCRIPT}" >> /tmp/runner_env_tmp
    cp /tmp/runner_env_tmp "$RUNNER_ENV"
    echo "Runner hook configured in: $RUNNER_ENV"
else
    echo "Warning: Could not find GHA runner .env - add this manually:"
    echo "  ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${HOOK_SCRIPT}"
fi

# Start the daemon now (runs for the lifetime of this VM)
nohup /usr/local/bin/gha-monitoring/monitor_daemon.sh >> /tmp/gha-monitoring/daemon.log 2>&1 &
echo "Daemon started (PID $!)"

echo ""
echo "GHA VM Monitoring installed and running."
