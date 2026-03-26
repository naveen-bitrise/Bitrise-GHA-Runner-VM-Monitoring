# GitHub Actions Runner VM Monitoring

A comprehensive monitoring solution for GitHub Actions Mac runners that automatically collects and visualizes system metrics during build execution.

## Features

- **Automatic Job Detection**: Daemon automatically detects when GHA jobs start/stop
- **Real-time Metrics Collection**: Collects metrics every 5 seconds:
  - CPU usage (user, system, idle)
  - Memory usage (used, free, cached)
  - Load averages (1min, 5min, 15min)
  - Swap usage (used, free)
- **No Workflow Changes**: Zero modifications needed to GHA YAML files
- **Web Dashboard**: Ruby-based visualization with 4 interactive graphs

## Architecture

```
┌─────────────────────────────────────────────┐
│  GitHub Actions Mac Runner                 │
│                                             │
│  ┌─────────────────────────────────────┐   │
│  │  monitor_daemon.sh                  │   │
│  │  (Auto-detects GHA jobs)            │   │
│  └───────────┬─────────────────────────┘   │
│              │ starts/stops                 │
│              ▼                               │
│  ┌─────────────────────────────────────┐   │
│  │  collect_metrics.sh                 │   │
│  │  (Collects system metrics)          │   │
│  └───────────┬─────────────────────────┘   │
│              │ writes                       │
│              ▼                               │
│  /tmp/gha-monitoring/monitoring-*.csv       │
└─────────────────────────────────────────────┘
                    │
                    │ Manual transfer
                    ▼
┌─────────────────────────────────────────────┐
│  Visualization Server                       │
│                                             │
│  ┌─────────────────────────────────────┐   │
│  │  Ruby Web App (Sinatra)             │   │
│  │  Displays 4 interactive graphs      │   │
│  └─────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

## Installation

### 1. On the GitHub Actions Mac Runner

Install the monitoring scripts (pre-baked into runner image):

```bash
# Clone or copy the monitoring scripts
cd /usr/local/bin/gha-monitoring
cp /path/to/collect_metrics.sh .
cp /path/to/monitor_daemon.sh .
chmod +x *.sh

# Create monitoring data directory
mkdir -p /tmp/gha-monitoring

# Set up the daemon to run at system startup
# Option A: Using launchd (macOS)
sudo tee /Library/LaunchDaemons/com.gha.monitor.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gha.monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/gha-monitoring/monitor_daemon.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/gha-monitoring/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/gha-monitoring/daemon.error.log</string>
</dict>
</plist>
EOF

sudo launchctl load /Library/LaunchDaemons/com.gha.monitor.plist
```

### 2. On the Visualization Server

Install the Ruby web app:

```bash
cd webapp

# Install dependencies
bundle install

# Configure data directory (optional)
export MONITORING_DATA_DIR=/path/to/monitoring/data

# Start the web server
ruby app.rb
# Or using rackup for production
rackup -p 4567
```

## Usage

### Starting the Monitoring Daemon

The daemon should start automatically via launchd. To manage it manually:

```bash
# Start daemon
./monitor_daemon.sh &

# Check if daemon is running
ps aux | grep monitor_daemon

# Stop daemon
pkill -f monitor_daemon.sh
```

### Monitoring Output

- **CSV files** are saved to `/tmp/gha-monitoring/monitoring-YYYYMMDD_HHMMSS.csv`
- Each file contains metrics for one GHA job
- Files include timestamp and all metrics in CSV format

### Transferring Data Files

After jobs complete, manually transfer the CSV files:

```bash
# From runner to visualization server
scp /tmp/gha-monitoring/monitoring-*.csv user@viz-server:/path/to/webapp/data/
```

### Viewing the Dashboard

1. Start the web app: `ruby webapp/app.rb`
2. Open browser: `http://localhost:4567`
3. Select a monitoring file from the dropdown
4. View the 4 interactive graphs

## Dashboard Graphs

The web dashboard displays 4 graphs matching your reference design:

1. **CPU Total**: Stacked area chart showing user and system CPU usage
2. **Memory**: Stacked area chart showing used, cached, and free memory
3. **Load Average**: Line chart with 1min, 5min, and 15min load averages
4. **Swap**: Stacked area chart showing used and free swap space

## Configuration

### Monitoring Interval

Edit `collect_metrics.sh` to change the sampling interval:

```bash
INTERVAL=5  # Change to desired seconds
```

### Data Output Location

Edit `monitor_daemon.sh` to change the output directory:

```bash
OUTPUT_DIR="/tmp/gha-monitoring"  # Change to desired path
```

### Web App Port

Edit `webapp/app.rb` to change the server port:

```ruby
set :port, 4567  # Change to desired port
```

### Data Directory for Web App

Set environment variable:

```bash
export MONITORING_DATA_DIR=/custom/path
ruby app.rb
```

## Testing

### Test the Monitoring Script Manually

```bash
# Run monitoring for 30 seconds
./collect_metrics.sh /tmp/test-monitoring.csv &
MONITOR_PID=$!
sleep 30
kill $MONITOR_PID

# Check the output
cat /tmp/test-monitoring.csv
```

### Test the Daemon

```bash
# Start daemon in foreground for testing
./monitor_daemon.sh

# In another terminal, simulate a GHA job by running a process
# that matches the pattern (e.g., Runner.Worker)
```

### Test the Web App

```bash
cd webapp
bundle install
ruby app.rb

# Visit http://localhost:4567
```

## CSV File Format

The monitoring CSV files contain the following columns:

- `timestamp`: Date and time in "YYYY-MM-DD HH:MM:SS" format
- `cpu_user`: User CPU percentage
- `cpu_system`: System CPU percentage
- `cpu_idle`: Idle CPU percentage
- `cpu_nice`: Nice CPU percentage
- `memory_used_mb`: Used memory in MB
- `memory_free_mb`: Free memory in MB
- `memory_cached_mb`: Cached/reclaimable memory in MB
- `load1`: 1-minute load average
- `load5`: 5-minute load average
- `load15`: 15-minute load average
- `swap_used_mb`: Used swap in MB
- `swap_free_mb`: Free swap in MB

## Troubleshooting

### Daemon Not Detecting Jobs

Check that the daemon is looking for the correct process:

```bash
# Check what GHA runner processes are running
ps aux | grep -i runner

# Update monitor_daemon.sh if needed to match your runner's process name
```

### No Data Being Collected

```bash
# Check daemon logs
tail -f /tmp/gha-monitoring/daemon.log

# Check if scripts are executable
ls -la *.sh

# Test manually
./collect_metrics.sh /tmp/test.csv
```

### Web App Not Loading Files

```bash
# Check data directory
ls -la $MONITORING_DATA_DIR

# Check permissions
chmod 755 /path/to/data/directory
chmod 644 /path/to/data/*.csv

# Check web app logs
```

## Requirements

### Runner (macOS)
- Bash 3.2+
- Standard macOS utilities: `iostat`, `vm_stat`, `sysctl`, `pagesize`

### Web Server
- Ruby 2.7+
- Bundler
- Gems: sinatra, puma, csv, json

## License

This project is provided as-is for monitoring GitHub Actions runners.

## Future Enhancements

Potential improvements:
- Automatic upload from runner to web server
- Real-time streaming of metrics
- Historical data comparison
- Email alerts for resource thresholds
- Multi-runner support and comparison
