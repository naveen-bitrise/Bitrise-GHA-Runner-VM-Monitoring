#!/bin/bash
# install_on_runner.sh - Install monitoring on macOS GitHub Actions Runner

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/usr/local/bin/gha-monitoring"
DATA_DIR="/tmp/gha-monitoring"
PLIST_PATH="/Library/LaunchDaemons/com.gha.monitor.plist"

echo "Installing GitHub Actions VM Monitoring..."
echo ""

# Check if running as root for launchd setup
if [ "$EUID" -ne 0 ]; then
    echo "Warning: Not running as root. Will install scripts but cannot set up launchd daemon."
    echo "Run with sudo to set up automatic startup."
    echo ""
fi

# Create installation directory
echo "Creating installation directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Copy monitoring scripts
echo "Installing monitoring scripts..."
cp "$SCRIPT_DIR/collect_metrics.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/monitor_daemon.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/*.sh

# Create data directory
echo "Creating data directory: $DATA_DIR"
mkdir -p "$DATA_DIR"

# Install launchd service if running as root
if [ "$EUID" -eq 0 ]; then
    echo "Installing launchd service..."
    cp "$SCRIPT_DIR/com.gha.monitor.plist" "$PLIST_PATH"

    # Update the plist with the correct path
    sed -i '' "s|/usr/local/bin/gha-monitoring/monitor_daemon.sh|$INSTALL_DIR/monitor_daemon.sh|g" "$PLIST_PATH"

    # Load the service
    launchctl load "$PLIST_PATH"

    echo ""
    echo "✓ Monitoring daemon installed and started"
    echo "  View logs: tail -f $DATA_DIR/daemon.log"
else
    echo ""
    echo "✓ Scripts installed to: $INSTALL_DIR"
    if [ -z "$SKIP_STARTUP_HINT" ]; then
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
