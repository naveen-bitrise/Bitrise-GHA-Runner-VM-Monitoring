#!/bin/bash
# warmup_runner.sh - VM warmup script: clones monitoring repo and installs daemon
# Run this as part of the VM warmup script on each boot.
#
# Usage:
#   bash warmup_runner.sh
#
# Required: replace the placeholders below before baking into the runner image
#   SUPABASE_PROJECT_ID      - Supabase Project ID (Settings → General)
#   SUPABASE_PUBLISHABLE_KEY - Supabase publishable key (sb_publishable_...)
#                              (runner only does INSERTs — secret key not needed here)

set -e

MONITORING_REPO="naveen-bitrise/Bitrise-GHA-Runner-VM-Monitoring"
SETUP_DIR="/tmp/gha-monitoring-setup"

SUPABASE_PROJECT_ID="SUPABASE_PROJECT_ID_PLACEHOLDER"
SUPABASE_PUBLISHABLE_KEY="SUPABASE_PUBLISHABLE_KEY_PLACEHOLDER"

echo "Setting up GHA VM Monitoring from ${MONITORING_REPO}..."

# Clean any previous setup attempt
rm -rf "$SETUP_DIR"

# Clone the monitoring repo
git clone --branch supabase --depth 1 "https://github.com/${MONITORING_REPO}.git" "$SETUP_DIR"

# Install the monitoring daemon (scripts/ contains all shell scripts)
SKIP_STARTUP_HINT=1 bash "$SETUP_DIR/scripts/install_on_runner.sh"

# Persist Supabase credentials so the hook scripts can read them
DAEMON_ENV_FILE="/usr/local/bin/gha-monitoring/daemon.env"
cat > "$DAEMON_ENV_FILE" <<EOF
export SUPABASE_PROJECT_ID="${SUPABASE_PROJECT_ID}"
export SUPABASE_PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY}"
export SUPABASE_URL="https://${SUPABASE_PROJECT_ID}.supabase.co"
EOF
chmod 600 "$DAEMON_ENV_FILE"

# Install the Supabase hook scripts
cp "$SETUP_DIR/scripts/supabase_hook.sh"                  /usr/local/bin/gha-monitoring/
cp "$SETUP_DIR/scripts/send_metrics_to_supabase.sh"       /usr/local/bin/gha-monitoring/
cp "$SETUP_DIR/scripts/send_build_info_to_supabase.sh"    /usr/local/bin/gha-monitoring/
chmod +x /usr/local/bin/gha-monitoring/supabase_hook.sh
chmod +x /usr/local/bin/gha-monitoring/send_metrics_to_supabase.sh
chmod +x /usr/local/bin/gha-monitoring/send_build_info_to_supabase.sh

# Wire the hook into the GHA runner's .env file (create if it doesn't exist yet)
HOOK_SCRIPT="/usr/local/bin/gha-monitoring/supabase_hook.sh"
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
