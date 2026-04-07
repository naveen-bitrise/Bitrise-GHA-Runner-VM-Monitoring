#!/bin/bash
# install_on_runner.sh - Install monitoring on a GitHub Actions Runner (macOS or Linux)

set -e

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin/gha-monitoring}"
DATA_DIR="${DATA_DIR:-/tmp/gha-monitoring}"
PLIST_PATH="/Library/LaunchDaemons/com.gha.monitor.plist"
SYSTEMD_UNIT="/etc/systemd/system/gha-monitor.service"

OS="$(uname)"

echo "Installing GitHub Actions VM Monitoring..."
echo ""

# Check if running as root for daemon setup
if [ "$EUID" -ne 0 ]; then
    echo "Warning: Not running as root. Will install scripts but cannot set up daemon."
    echo "Run with sudo to set up automatic startup."
    echo ""
fi

# Create installation directory
echo "Creating installation directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Copy monitoring scripts
echo "Installing monitoring scripts..."
cp "$SCRIPT_DIR/collect_metrics.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/monitor_daemon.sh"  "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/*.sh

# Create data directory
echo "Creating data directory: $DATA_DIR"
mkdir -p "$DATA_DIR"

# Install daemon startup
if [ "$EUID" -eq 0 ]; then
    if [[ "$OS" == "Darwin" ]]; then
        # ---------------------------------------------------------------- macOS — launchd
        echo "Installing launchd service..."
        cp "$SCRIPT_DIR/com.gha.monitor.plist" "$PLIST_PATH"
        sed -i '' "s|/usr/local/bin/gha-monitoring/monitor_daemon.sh|$INSTALL_DIR/monitor_daemon.sh|g" "$PLIST_PATH"
        launchctl load "$PLIST_PATH"
        echo ""
        echo "✓ Monitoring daemon installed and started (launchd)"
        echo "  View logs: tail -f $DATA_DIR/daemon.log"

    else
        # ---------------------------------------------------------------- Linux — systemd or nohup
        if command -v systemctl >/dev/null 2>&1; then
            echo "Installing systemd service..."
            cat > "$SYSTEMD_UNIT" <<UNIT
[Unit]
Description=GHA Runner VM Monitoring Daemon
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/monitor_daemon.sh
Restart=on-failure
StandardOutput=append:$DATA_DIR/daemon.log
StandardError=append:$DATA_DIR/daemon.log

[Install]
WantedBy=multi-user.target
UNIT
            systemctl daemon-reload
            systemctl enable --now gha-monitor
            echo ""
            echo "✓ Monitoring daemon installed and started (systemd)"
            echo "  Status:    systemctl status gha-monitor"
            echo "  View logs: journalctl -u gha-monitor -f"
        else
            # Fallback: add to /etc/rc.local if available
            echo "systemd not found — using nohup fallback..."
            RC_LOCAL="/etc/rc.local"
            if [[ -f "$RC_LOCAL" ]]; then
                grep -v "gha-monitoring" "$RC_LOCAL" > /tmp/rc_local_tmp || true
                echo "nohup $INSTALL_DIR/monitor_daemon.sh >> $DATA_DIR/daemon.log 2>&1 &" >> /tmp/rc_local_tmp
                cp /tmp/rc_local_tmp "$RC_LOCAL"
                chmod +x "$RC_LOCAL"
            fi
            nohup "$INSTALL_DIR/monitor_daemon.sh" >> "$DATA_DIR/daemon.log" 2>&1 &
            echo ""
            echo "✓ Monitoring daemon started (nohup, PID $!)"
            echo "  View logs: tail -f $DATA_DIR/daemon.log"
        fi
    fi
else
    echo ""
    echo "✓ Scripts installed to: $INSTALL_DIR"
    if [ -z "${SKIP_STARTUP_HINT:-}" ]; then
        echo ""
        echo "To set up automatic startup, run:"
        echo "  sudo ./install_on_runner.sh"
        echo ""
        echo "Or start manually:"
        echo "  $INSTALL_DIR/monitor_daemon.sh &"
    fi
fi

echo ""
echo "Installation complete!"
echo "Monitoring data will be saved to: $DATA_DIR"
