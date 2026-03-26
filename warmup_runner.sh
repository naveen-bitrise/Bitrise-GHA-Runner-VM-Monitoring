#!/bin/bash
# warmup_runner.sh - VM warmup script: clones monitoring repo and installs daemon
# Run this during VM image build (with sudo) to pre-bake monitoring into the runner.
#
# Usage:
#   sudo bash warmup_runner.sh
#
# Required: set these before running
#   MONITORING_REPO  - GitHub repo containing this project, e.g. "your-org/your-repo"
#   METRICS_TOKEN    - GitHub token with push access to MONITORING_REPO
#
# Optional:
#   VM_NAME          - Identifier for this runner (defaults to hostname)

set -e

MONITORING_REPO="${MONITORING_REPO:-YOUR_ORG/YOUR_REPO}"
SETUP_DIR="/tmp/gha-monitoring-setup"

echo "Setting up GHA VM Monitoring from ${MONITORING_REPO}..."

# Clean any previous setup attempt
rm -rf "$SETUP_DIR"

# Clone the monitoring repo
git clone "https://github.com/${MONITORING_REPO}.git" "$SETUP_DIR"

# Install the monitoring daemon
cd "$SETUP_DIR"
bash install_on_runner.sh

# Persist METRICS_REPO and METRICS_TOKEN so the launchd daemon can read them
# These are written to a file sourced by monitor_daemon.sh via the plist environment
DAEMON_ENV_FILE="/usr/local/bin/gha-monitoring/daemon.env"
cat > "$DAEMON_ENV_FILE" <<EOF
export METRICS_REPO="${MONITORING_REPO}"
export METRICS_TOKEN="${METRICS_TOKEN}"
export VM_NAME="${VM_NAME:-$(hostname)}"
EOF
chmod 600 "$DAEMON_ENV_FILE"

echo ""
echo "GHA VM Monitoring installed successfully."
echo "The daemon will start automatically on next boot (launchd)."
