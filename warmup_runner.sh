#!/bin/bash
# warmup_runner.sh - VM warmup script: clones monitoring repo and installs daemon
# Run this as part of the VM warmup script on each boot.
#
# Usage:
#   bash warmup_runner.sh
#
# Required: replace the placeholders below before baking into the runner image
#   NR_LICENSE_KEY  - New Relic Ingest - License key
#   NR_ACCOUNT_ID   - New Relic numeric account ID

set -e

MONITORING_REPO="naveen-bitrise/Bitrise-GHA-Runner-VM-Monitoring"
SETUP_DIR="/tmp/gha-monitoring-setup"

NR_LICENSE_KEY="NEW_RELIC_LICENSE_KEY_PLACEHOLDER"
NR_ACCOUNT_ID="NEW_RELIC_ACCOUNT_ID_PLACEHOLDER"

echo "Setting up GHA VM Monitoring from ${MONITORING_REPO}..."

# Clean any previous setup attempt
rm -rf "$SETUP_DIR"

# Clone the monitoring repo
git clone "https://github.com/${MONITORING_REPO}.git" "$SETUP_DIR"

# Install the monitoring daemon
cd "$SETUP_DIR"
SKIP_STARTUP_HINT=1 bash install_on_runner.sh

# Persist New Relic credentials so the hook scripts can read them
DAEMON_ENV_FILE="/usr/local/bin/gha-monitoring/daemon.env"
cat > "$DAEMON_ENV_FILE" <<EOF
export NEW_RELIC_LICENSE_KEY="${NR_LICENSE_KEY}"
export NEW_RELIC_ACCOUNT_ID="${NR_ACCOUNT_ID}"
EOF
chmod 600 "$DAEMON_ENV_FILE"

# Install the New Relic hook scripts
cp "$SETUP_DIR/newrelic_hook.sh"              /usr/local/bin/gha-monitoring/
cp "$SETUP_DIR/send_metrics_to_newrelic.sh"   /usr/local/bin/gha-monitoring/
cp "$SETUP_DIR/send_build_info_to_newrelic.sh" /usr/local/bin/gha-monitoring/
chmod +x /usr/local/bin/gha-monitoring/newrelic_hook.sh
chmod +x /usr/local/bin/gha-monitoring/send_metrics_to_newrelic.sh
chmod +x /usr/local/bin/gha-monitoring/send_build_info_to_newrelic.sh

# Wire the hook into the GHA runner's .env file (create if it doesn't exist yet)
HOOK_SCRIPT="/usr/local/bin/gha-monitoring/newrelic_hook.sh"
RUNNER_ENV="/Users/vagrant/actions-runner/.env"

mkdir -p "$(dirname $RUNNER_ENV)"
grep -v "ACTIONS_RUNNER_HOOK_JOB_COMPLETED" "$RUNNER_ENV" > /tmp/runner_env_tmp 2>/dev/null || true
echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${HOOK_SCRIPT}" >> /tmp/runner_env_tmp
cp /tmp/runner_env_tmp "$RUNNER_ENV"
echo "Runner hook configured in: $RUNNER_ENV"

# Start the daemon now (runs for the lifetime of this VM)
nohup /usr/local/bin/gha-monitoring/monitor_daemon.sh >> /tmp/gha-monitoring/daemon.log 2>&1 &
echo "Daemon started (PID $!)"

echo ""
echo "GHA VM Monitoring installed and running."
