#!/bin/bash
# start.sh - Start the monitoring dashboard web server

# Default data directory is the repo's metrics/ folder (one level up from webapp/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export MONITORING_DATA_DIR="${MONITORING_DATA_DIR:-${SCRIPT_DIR}/../metrics}"

echo "Starting GitHub Actions VM Monitoring Dashboard..."
echo "Data directory: $MONITORING_DATA_DIR"
echo "Server will be available at: http://localhost:4567"
echo ""

# Check if bundle is installed
if ! command -v bundle &> /dev/null; then
    echo "Error: bundler not found. Please install it:"
    echo "  gem install bundler"
    exit 1
fi

# Install dependencies if needed
if [ ! -d "vendor" ] && [ ! -f ".bundle/config" ]; then
    echo "Installing dependencies..."
    bundle install
    echo ""
fi

# Start the server
bundle exec ruby app.rb
